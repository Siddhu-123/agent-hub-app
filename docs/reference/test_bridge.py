#!/usr/bin/env python3
"""Black-box tests for notch-agent-bridge: run it as the hooks would, inspect ~/.notch-agents files."""
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

BRIDGE = Path(__file__).with_name("notch-agent-bridge.py")


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def run_bridge(self, platform, event, payload, env=None):
        e = {**os.environ, "NOTCH_AGENTS_DIR": str(self.root), "__CFBundleIdentifier": "com.apple.Terminal", **(env or {})}
        r = subprocess.run([sys.executable, str(BRIDGE), platform, event], input=json.dumps(payload),
                           capture_output=True, text=True, env=e, timeout=30)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse((self.root / "bridge-errors.log").exists(), (self.root / "bridge-errors.log").read_text() if (self.root / "bridge-errors.log").exists() else "")
        return json.loads(r.stdout) if r.stdout.strip() else None

    def sessions(self):
        return [json.loads(p.read_text()) for p in (self.root / "sessions").glob("*.json")]

    def requests(self):
        return [json.loads(p.read_text()) for p in (self.root / "requests").glob("*.json")]

    def notch_alive(self, hold=True, seconds=10):
        (self.root / "notch.json").write_text(json.dumps({"alive_at": time.time() + 60, "hold_permissions": hold, "hold_seconds": seconds}))

    def answer_when_requested(self, decision):
        def worker():
            for _ in range(100):
                for r in self.requests():
                    if r.get("canAnswer"):
                        (self.root / "responses" / f"{r['id']}.json").write_text(json.dumps({"decision": decision}))
                        return
                time.sleep(0.05)
        t = threading.Thread(target=worker)
        t.start()
        return t

    def test_claude_session_lifecycle(self):
        self.run_bridge("claude", "UserPromptSubmit", {"session_id": "s1", "cwd": "/x/notch", "prompt": "Add bubbles\nsecond line"})
        self.run_bridge("claude", "PreToolUse", {"session_id": "s1", "cwd": "/x/notch", "tool_name": "Bash", "tool_input": {"command": "xcodebuild build"}})
        [s] = self.sessions()
        self.assertEqual((s["status"], s["title"], s["project"], s["app"]), ("working", "Add bubbles", "notch", "com.apple.Terminal"))
        self.assertEqual(s["activity"], "Running xcodebuild build")
        self.run_bridge("claude", "Stop", {"session_id": "s1", "last_assistant_message": "All done."})
        [s] = self.sessions()
        self.assertEqual((s["status"], s["activity"]), ("done", "All done."))
        self.run_bridge("claude", "SessionEnd", {"session_id": "s1"})
        self.assertEqual(self.sessions(), [])

    def test_permission_without_notch_falls_through(self):
        out = self.run_bridge("claude", "PermissionRequest", {"session_id": "s1", "tool_name": "Bash", "tool_input": {"command": "rm -rf build"}})
        self.assertIsNone(out)
        [r] = self.requests()
        self.assertFalse(r["canAnswer"])
        self.assertIn("rm -rf build", r["detail"])
        # the agent ran the tool after the user answered in the app: bubble goes away
        self.run_bridge("claude", "PostToolUse", {"session_id": "s1", "tool_name": "Bash"})
        self.assertEqual(self.requests(), [])

    def test_permission_held_and_allowed_always(self):
        self.notch_alive()
        t = self.answer_when_requested("always")
        sugg = [{"type": "addRules", "rules": [{"toolName": "Bash"}], "behavior": "allow", "destination": "localSettings"}]
        out = self.run_bridge("claude", "PermissionRequest", {"session_id": "s1", "tool_name": "Bash", "tool_input": {"command": "ls"}, "permission_suggestions": sugg})
        t.join()
        self.assertEqual(out["hookSpecificOutput"]["decision"], {"behavior": "allow", "updatedPermissions": sugg})
        self.assertEqual(self.requests(), [])

    def test_permission_held_and_denied_codex(self):
        self.notch_alive()
        t = self.answer_when_requested("deny")
        out = self.run_bridge("codex", "PermissionRequest", {"session_id": "c1", "tool_name": "exec_command", "tool_input": {"cmd": "curl x"}})
        t.join()
        self.assertEqual(out["hookSpecificOutput"]["decision"]["behavior"], "deny")

    def test_open_in_app_releases_hold(self):
        self.notch_alive()
        t = self.answer_when_requested("app")
        start = time.time()
        out = self.run_bridge("claude", "PermissionRequest", {"session_id": "s1", "tool_name": "Bash", "tool_input": {"command": "ls"}})
        t.join()
        self.assertIsNone(out)
        self.assertLess(time.time() - start, 5)
        [r] = self.requests()
        self.assertFalse(r["canAnswer"])

    def test_hold_times_out(self):
        self.notch_alive(seconds=5)
        start = time.time()
        self.assertIsNone(self.run_bridge("claude", "PermissionRequest", {"session_id": "s1", "tool_name": "Bash", "tool_input": {"command": "ls"}}))
        self.assertGreaterEqual(time.time() - start, 4.5)

    def test_notification_idle_and_permission(self):
        self.run_bridge("claude", "Notification", {"session_id": "s1", "notification_type": "idle_prompt", "message": "Claude is waiting for your input"})
        self.run_bridge("claude", "Notification", {"session_id": "s1", "notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash"})
        # One bubble per session: the permission prompt replaces the idle note.
        self.assertEqual([r["kind"] for r in self.requests()], ["permission"])
        self.run_bridge("claude", "UserPromptSubmit", {"session_id": "s1", "prompt": "go"})
        self.assertEqual(self.requests(), [])

    def test_antigravity_contract_outputs_json(self):
        self.assertEqual(self.run_bridge("antigravity", "PreInvocation", {"conversationId": "c1", "workspacePaths": ["/p/app"], "transcriptPath": "/h/.gemini/antigravity-cli/t.jsonl"}), {})
        self.assertEqual(self.run_bridge("antigravity", "PostToolUse", {"conversationId": "c1", "toolCall": {"name": "run_command", "args": {"CommandLine": "npm test"}}}), {})
        [s] = self.sessions()
        self.assertEqual((s["platformName"], s["activity"], s["project"]), ("Antigravity CLI", "Running npm test", "app"))
        self.assertEqual(self.run_bridge("antigravity", "Stop", {"conversationId": "c1", "terminationReason": "model_stop"}), {})
        self.assertEqual(self.sessions()[0]["status"], "done")

    def test_opencode_permission_is_non_blocking(self):
        self.notch_alive()
        out = self.run_bridge("opencode", "permission", {"sessionID": "o1", "directory": "/p/x", "id": "perm1", "permission": "bash", "detail": "ls"})
        [r] = self.requests()
        self.assertEqual((out["requestId"], r["externalId"], r["canAnswer"]), (r["id"], "perm1", True))
        self.run_bridge("opencode", "permission-replied", {"sessionID": "o1", "id": "perm1"})
        self.assertEqual(self.requests(), [])

    ASK = {"questions": [{"question": "Where are the API keys?", "header": "API keys",
                          "options": [{"label": "Paste them to me now"}, {"label": "Check another location"}]}]}

    def test_ask_user_question_makes_one_bubble_and_never_holds(self):
        self.notch_alive()
        base = {"session_id": "s1", "tool_name": "AskUserQuestion", "tool_input": self.ASK}
        self.run_bridge("claude", "PreToolUse", base)
        start = time.time()
        self.assertIsNone(self.run_bridge("claude", "PermissionRequest", base))
        self.assertLess(time.time() - start, 3)
        self.run_bridge("claude", "Notification", {"session_id": "s1", "notification_type": "permission_prompt",
                                                   "message": "Claude needs your permission to use AskUserQuestion"})
        [r] = self.requests()
        self.assertEqual((r["kind"], r["title"], r["header"], r["choices"], r["canAnswer"]),
                         ("question", "Where are the API keys?", "API keys", ["Paste them to me now", "Check another location"], False))

    def test_permission_detail_is_never_raw_json(self):
        self.run_bridge("claude", "PermissionRequest", {"session_id": "s1", "tool_name": "mcp__x__send", "tool_input": {"to": "team", "body": "hi", "n": {"a": 1}}})
        [r] = self.requests()
        self.assertEqual(r["detail"], "to: team · body: hi")
        self.assertNotIn("{", r["detail"])

    def test_opencode_keeps_multiple_permissions(self):
        self.notch_alive()
        for i in (1, 2):
            self.run_bridge("opencode", "permission", {"sessionID": "o1", "id": f"p{i}", "permission": "bash", "detail": "ls"})
        self.assertEqual(len(self.requests()), 2)

    def test_garbage_input_never_fails(self):
        e = {**os.environ, "NOTCH_AGENTS_DIR": str(self.root)}
        r = subprocess.run([sys.executable, str(BRIDGE), "claude", "PreToolUse"], input="{not json", capture_output=True, text=True, env=e)
        self.assertEqual((r.returncode, r.stdout), (0, ""))


if __name__ == "__main__":
    unittest.main()
