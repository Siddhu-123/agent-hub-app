#!/usr/bin/env python3
"""notch-agent-bridge: turns AI-agent hook events into files the Notch app watches.

    notch-agent-bridge <platform> <event>        (hook JSON on stdin)

Platforms: claude, codex (Claude-style hooks), antigravity (camelCase hooks),
opencode (called by the Notch OpenCode plugin). Everything lives in ~/.notch-agents:

    sessions/<platform>-<session>.json   one live agent session
    requests/<id>.json                   a pending permission / question / attention bubble
    responses/<id>.json                  Notch's answer to a request (allow|always|deny|app)
    platforms/<platform>.json            last time each platform reported (for Settings)
    notch.json                           Notch heartbeat + hold settings (written by the app)

The bridge never fails a hook: any error exits 0 with no output, so the agent
falls back to its own permission UI.
"""
import json
import os
import re
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(os.environ.get("NOTCH_AGENTS_DIR", Path.home() / ".notch-agents"))
SESSIONS, REQUESTS, RESPONSES, PLATFORMS = (ROOT / d for d in ("sessions", "requests", "responses", "platforms"))
ALIVE_WINDOW = 6.0  # seconds since Notch's last heartbeat before it counts as gone

PLATFORM_NAMES = {"claude": "Claude Code", "codex": "Codex", "antigravity": "Antigravity", "opencode": "OpenCode"}
DEFAULT_APPS = {"claude": "com.anthropic.claudefordesktop", "codex": "com.openai.codex",
                "antigravity": "com.google.antigravity", "opencode": "com.apple.Terminal"}
TERM_APPS = {"Apple_Terminal": "com.apple.Terminal", "iTerm.app": "com.googlecode.iterm2",
             "WarpTerminal": "dev.warp.Warp-Stable", "ghostty": "com.mitchellh.ghostty",
             "WezTerm": "com.github.wez.wezterm", "vscode": "com.microsoft.VSCode"}


# ---------- files ----------

def ensure_dirs():
    for d in (ROOT, SESSIONS, REQUESTS, RESPONSES, PLATFORMS):
        d.mkdir(mode=0o700, parents=True, exist_ok=True)


def write_json(path, value):
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(value, ensure_ascii=False))
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def read_json(path, default=None):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def safe_id(text):
    return re.sub(r"[^A-Za-z0-9._-]", "_", str(text))[:120] or "unknown"


def notch_state():
    """Heartbeat written by Notch. Holding a request only makes sense while Notch is alive."""
    state = read_json(ROOT / "notch.json", {}) or {}
    alive = time.time() - float(state.get("alive_at", 0)) < ALIVE_WINDOW
    return alive, state


# ---------- context ----------

def host_app(platform):
    bundle = os.environ.get("__CFBundleIdentifier", "")
    if bundle and bundle not in ("com.apple.python3", "org.python.python"):
        return bundle
    term = os.environ.get("TERM_PROGRAM", "")
    if term in TERM_APPS:
        return TERM_APPS[term]
    return DEFAULT_APPS.get(platform, "")


def agent_pid():
    """The long-lived agent process: skip the intermediate `sh -c` the hook ran in."""
    pid = os.getppid()
    for _ in range(2):
        try:
            out = subprocess.run(["ps", "-o", "ppid=,comm=", "-p", str(pid)], capture_output=True, text=True, timeout=1).stdout.split(None, 1)
        except (OSError, subprocess.TimeoutExpired):
            return pid
        if len(out) < 2 or os.path.basename(out[1].strip()) not in ("sh", "bash", "zsh", "dash", "-sh", "-zsh", "-bash"):
            return pid
        pid = int(out[0])
    return pid


def clip(text, limit=160):
    text = " ".join(str(text or "").split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def short_path(path):
    path = str(path or "")
    return os.path.basename(path.rstrip("/")) or path


def describe_tool(tool, args):
    """Human line for what a tool call is doing, e.g. 'Running xcodebuild -scheme notch'."""
    args = args if isinstance(args, dict) else {}
    t = (tool or "").lower()
    cmd = args.get("command") or args.get("cmd") or args.get("CommandLine") or args.get("commandLine")
    if isinstance(cmd, list):
        cmd = " ".join(map(str, cmd))
    path = args.get("file_path") or args.get("filePath") or args.get("path") or args.get("TargetFile") or args.get("AbsolutePath")
    if cmd and t in ("bash", "shell", "exec_command", "local_shell", "run_command", "unified_exec", "") or (cmd and "command" in t):
        return f"Running {clip(cmd, 90)}"
    if t in ("edit", "multiedit", "write", "apply_patch", "write_to_file", "replace_file_content", "multi_replace_file_content", "patch"):
        return f"Editing {short_path(path)}" if path else "Editing files"
    if t in ("read", "view_file", "view_file_outline", "notebookread"):
        return f"Reading {short_path(path)}" if path else "Reading files"
    if t in ("grep", "glob", "grep_search", "find_by_name", "list_dir", "codebase_search", "list", "search"):
        q = args.get("pattern") or args.get("Query") or args.get("query") or ""
        return f"Searching {clip(q, 60)}" if q else "Searching the codebase"
    if t in ("webfetch", "websearch", "read_url_content", "search_web", "web_search"):
        return f"Browsing {clip(args.get('url') or args.get('query') or args.get('Url') or '', 60)}".strip()
    if t in ("task", "agent", "spawn_agent"):
        return f"Delegating: {clip(args.get('description') or args.get('prompt') or 'subagent', 70)}"
    if t in ("todowrite", "update_plan", "task_boundary"):
        return "Updating plan"
    if t.startswith("mcp__"):
        return f"Using {t.split('__')[1]} · {t.split('__')[-1]}"
    if t.startswith("browser_"):
        return "Using the browser"
    return f"Using {tool}" if tool else "Working"


def request_summary(platform, tool, args):
    args = args if isinstance(args, dict) else {}
    detail = args.get("command") or args.get("cmd") or args.get("CommandLine") or args.get("file_path") or args.get("filePath") or args.get("url") or args.get("pattern") or ""
    if isinstance(detail, list):
        detail = " ".join(map(str, detail))
    if not detail and args:
        detail = readable_args(args)
    title = f"{PLATFORM_NAMES.get(platform, platform)} wants to {verb_for(tool)}"
    return title, clip(detail, 400)


def readable_args(args):
    """'key: value' lines for the first few scalar fields; never a raw JSON dump."""
    lines = []
    for key, value in args.items():
        if isinstance(value, (str, int, float, bool)) and str(value).strip():
            lines.append(f"{key.replace('_', ' ')}: {value}")
        if len(lines) == 3:
            break
    return " · ".join(lines)


def question_from_args(args):
    """(question, header, choices) from an AskUserQuestion-style payload."""
    args = args if isinstance(args, dict) else {}
    qs = args.get("questions") or []
    first = qs[0] if qs and isinstance(qs[0], dict) else {}
    question = first.get("question") or first.get("header") or "Has a question for you"
    choices = []
    for o in first.get("options") or []:
        label = o.get("label") if isinstance(o, dict) else o
        if label:
            choices.append(clip(label, 40))
    extra = len(qs) - 1
    header = clip(first.get("header") or "", 40)
    if extra > 0:
        header = f"{header} · +{extra} more" if header else f"+{extra} more question{'s' if extra > 1 else ''}"
    return clip(question, 300), header, choices[:6]


def verb_for(tool):
    t = (tool or "").lower()
    if t in ("bash", "shell", "exec_command", "local_shell", "run_command", "unified_exec"):
        return "run a command"
    if t in ("edit", "multiedit", "write", "apply_patch", "write_to_file", "patch"):
        return "edit a file"
    if t in ("webfetch", "websearch", "read_url_content"):
        return "use the web"
    if t.startswith("mcp__"):
        return f"use {t.split('__')[1]}"
    return f"use {tool}" if tool else "continue"


# ---------- sessions & requests ----------

def session_path(platform, session_id):
    return SESSIONS / f"{platform}-{safe_id(session_id)}.json"


def update_session(platform, session_id, **fields):
    path = session_path(platform, session_id)
    s = read_json(path, {}) or {}
    now = time.time()
    if not s:
        s = {"platform": platform, "platformName": PLATFORM_NAMES.get(platform, platform), "sessionId": str(session_id),
             "startedAt": now, "title": "", "status": "idle", "activity": "", "app": host_app(platform),
             "pid": agent_pid(), "steps": 0}
    for k, v in fields.items():
        if v is not None and v != "":
            s[k] = v
    if fields.get("status") == "working" and s.get("turnStartedAt") is None:
        s["turnStartedAt"] = now
    if fields.get("status") in ("idle", "done", "error"):
        s["turnStartedAt"] = None
    s["updatedAt"] = now
    write_json(path, s)
    return s


def end_session(platform, session_id):
    try:
        session_path(platform, session_id).unlink()
    except OSError:
        pass
    clear_requests(platform, session_id, only_passive=False)


def new_request(platform, session_id, kind, title, detail, *, can_answer=False, hold_until=None, tool="", options=None, cwd="",
                choices=None, header=""):
    # Claude Code, Codex and Antigravity block on one prompt at a time, so a new bubble replaces
    # whatever that session showed before. OpenCode can queue several permissions.
    if platform != "opencode":
        clear_requests(platform, session_id, only_passive=False)
    rid = f"{platform}-{uuid.uuid4().hex[:12]}"
    req = {"id": rid, "platform": platform, "platformName": PLATFORM_NAMES.get(platform, platform), "sessionId": str(session_id),
           "kind": kind, "title": title, "detail": detail, "tool": tool or "", "canAnswer": can_answer,
           "options": options or (["allow", "deny"] if can_answer else []), "holdUntil": hold_until,
           "createdAt": time.time(), "app": host_app(platform), "cwd": cwd or "",
           "choices": choices or [], "header": header or ""}
    write_json(REQUESTS / f"{rid}.json", req)
    return req


def clear_requests(platform, session_id, *, only_passive=True, kinds=None):
    """Drop bubbles that the agent has moved past (the user answered in the app)."""
    for f in REQUESTS.glob(f"{platform}-*.json"):
        r = read_json(f)
        if not r or r.get("sessionId") != str(session_id):
            continue
        if only_passive and r.get("canAnswer"):
            continue
        if kinds and r.get("kind") not in kinds:
            continue
        f.unlink(missing_ok=True)


def has_live_request(platform, session_id, kinds=("permission",)):
    for f in REQUESTS.glob(f"{platform}-*.json"):
        r = read_json(f)
        if r and r.get("sessionId") == str(session_id) and r.get("kind") in kinds:
            return True
    return False


def wait_for_answer(req, hold_seconds):
    """Block (bounded) until Notch answers. Returns allow|always|deny|app|None."""
    resp = RESPONSES / f"{req['id']}.json"
    deadline = time.time() + hold_seconds
    while time.time() < deadline:
        answer = read_json(resp)
        if answer:
            resp.unlink(missing_ok=True)
            return answer.get("decision")
        if not notch_state()[0]:
            return None
        if not (REQUESTS / f"{req['id']}.json").exists():
            return None
        time.sleep(0.15)
    return None


def release_to_app(req):
    """Hold ended without a decision: keep the bubble as a passive pointer to the app's own prompt."""
    path = REQUESTS / f"{req['id']}.json"
    if path.exists():
        req.update({"canAnswer": False, "options": [], "holdUntil": None, "kind": "permission"})
        write_json(path, req)


# ---------- Claude Code & Codex (same hook contract) ----------

def handle_claude_style(platform, event, data):
    sid = data.get("session_id") or data.get("thread_id") or "default"
    cwd = data.get("cwd") or ""
    project = short_path(cwd)
    model = data.get("model") or ""
    tool, args = data.get("tool_name") or "", data.get("tool_input") or {}

    if event == "SessionStart":
        update_session(platform, sid, status="idle", activity="Session started", cwd=cwd, project=project, model=model)
    elif event == "UserPromptSubmit":
        s = read_json(session_path(platform, sid), {}) or {}
        title = s.get("title") or clip((data.get("prompt") or "").splitlines()[0] if data.get("prompt") else "", 80)
        clear_requests(platform, sid)
        update_session(platform, sid, status="working", activity="Thinking…", title=title, cwd=cwd, project=project, model=model,
                       lastPrompt=clip(data.get("prompt"), 200))
    elif event == "PreToolUse":
        s = update_session(platform, sid, status="working", activity=describe_tool(tool, args), cwd=cwd, project=project, model=model)
        s["steps"] = int(s.get("steps", 0)) + 1
        write_json(session_path(platform, sid), s)
        if tool == "AskUserQuestion":
            ask_question(platform, sid, args, cwd)
    elif event == "PostToolUse":
        clear_requests(platform, sid)
        update_session(platform, sid, status="working", cwd=cwd, project=project)
    elif event == "Notification":
        kind = data.get("notification_type") or ""
        msg = clip(data.get("message") or "", 300)
        if has_live_request(platform, sid, kinds=("question",)):
            pass  # the question bubble already covers this prompt
        elif kind == "permission_prompt" or "permission" in msg.lower():
            if not has_live_request(platform, sid):
                new_request(platform, sid, "permission", f"{PLATFORM_NAMES[platform]} needs permission", msg, cwd=cwd)
            update_session(platform, sid, status="waiting", activity="Waiting for permission")
        elif kind == "elicitation_dialog":
            new_request(platform, sid, "question", f"{PLATFORM_NAMES[platform]} is asking", msg, cwd=cwd)
            update_session(platform, sid, status="waiting", activity="Waiting for your answer")
        elif kind == "idle_prompt":
            clear_requests(platform, sid, kinds=("attention",))
            new_request(platform, sid, "attention", f"{PLATFORM_NAMES[platform]} is waiting for you", msg or "Ready for your next message", cwd=cwd)
            update_session(platform, sid, status="idle", activity="Waiting for your input")
    elif event == "Stop":
        clear_requests(platform, sid)
        msg = clip(data.get("last_assistant_message") or "", 160)
        update_session(platform, sid, status="done", activity=msg or "Finished", finishedAt=time.time())
    elif event == "SessionEnd":
        end_session(platform, sid)
    elif event == "PermissionRequest":
        return permission_request(platform, sid, tool, args, data.get("permission_suggestions"), cwd)
    return None


def ask_question(platform, sid, args, cwd):
    question, header, choices = question_from_args(args)
    new_request(platform, sid, "question", question, header, cwd=cwd, choices=choices, header=header)
    update_session(platform, sid, status="waiting", activity="Waiting for your answer")


def permission_request(platform, sid, tool, args, suggestions, cwd):
    if tool == "AskUserQuestion":
        # Claude asks permission to show its own question. That is the same prompt the question
        # bubble already shows, so never make a second bubble or hold the hook for it.
        if not has_live_request(platform, sid, kinds=("question",)):
            ask_question(platform, sid, args, cwd)
        return None
    alive, state = notch_state()
    hold = bool(state.get("hold_permissions", True)) and alive
    hold_seconds = max(5.0, min(float(state.get("hold_seconds", 45)), 540.0))
    title, detail = request_summary(platform, tool, args)
    clear_requests(platform, sid, kinds=("permission",))
    options = ["allow", "always", "deny"] if suggestions else ["allow", "deny"]
    req = new_request(platform, sid, "permission", title, detail, can_answer=hold, tool=tool,
                      hold_until=time.time() + hold_seconds if hold else None, options=options if hold else [], cwd=cwd)
    update_session(platform, sid, status="waiting", activity=f"Waiting: {verb_for(tool)}")
    if not hold:
        return None
    decision = wait_for_answer(req, hold_seconds)
    if decision in ("allow", "always", "deny"):
        (REQUESTS / f"{req['id']}.json").unlink(missing_ok=True)
        update_session(platform, sid, status="working", activity=describe_tool(tool, args) if decision != "deny" else "Permission denied in Notch")
        if decision == "deny":
            body = {"behavior": "deny", "message": "Denied from Notch."}
        else:
            body = {"behavior": "allow"}
            if decision == "always" and suggestions:
                body["updatedPermissions"] = suggestions
        return {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": body}}
    release_to_app(req)
    return None


# ---------- Antigravity (camelCase hooks.json contract) ----------

def handle_antigravity(event, data):
    sid = data.get("conversationId") or "default"
    paths = data.get("workspacePaths") or []
    cwd = paths[0] if paths else ""
    surface = "antigravity"
    tp = str(data.get("transcriptPath") or "")
    # Only name the surface when the transcript path says which one; later events may omit it.
    name = "Antigravity CLI" if "antigravity-cli" in tp else "Antigravity IDE" if "antigravity-ide" in tp else None
    if event == "PreInvocation":
        update_session(surface, sid, status="working", activity="Thinking…", cwd=cwd, project=short_path(cwd),
                       model=data.get("modelName") or "", platformName=name)
    elif event == "PostToolUse":
        call = data.get("toolCall") or {}
        activity = describe_tool(call.get("name"), call.get("args")) if call else f"Step {data.get('stepIdx', '')}".strip()
        s = update_session(surface, sid, status="working", activity=activity, cwd=cwd, project=short_path(cwd), platformName=name)
        s["steps"] = int(s.get("steps", 0)) + 1
        write_json(session_path(surface, sid), s)
    elif event == "Stop":
        reason = data.get("terminationReason") or ""
        err = data.get("error") or ""
        update_session(surface, sid, status="error" if err or reason == "error" else "done",
                       activity=clip(err, 120) or "Finished", finishedAt=time.time(), platformName=name)
    return {}


# ---------- OpenCode (driven by the Notch plugin) ----------

def handle_opencode(event, data):
    sid = data.get("sessionID") or "default"
    cwd = data.get("directory") or ""
    if event == "busy":
        update_session("opencode", sid, status="working", activity=data.get("activity") or "Thinking…", cwd=cwd,
                       project=short_path(cwd), title=clip(data.get("title"), 80))
    elif event == "tool":
        s = update_session("opencode", sid, status="working", activity=describe_tool(data.get("tool"), data.get("args")), cwd=cwd, project=short_path(cwd))
        s["steps"] = int(s.get("steps", 0)) + 1
        write_json(session_path("opencode", sid), s)
    elif event == "title":
        update_session("opencode", sid, title=clip(data.get("title"), 80))
    elif event == "idle":
        clear_requests("opencode", sid, only_passive=False)
        update_session("opencode", sid, status="done", activity="Finished", finishedAt=time.time())
    elif event == "error":
        update_session("opencode", sid, status="error", activity=clip(data.get("message"), 120) or "Error")
    elif event == "permission":
        # Non-blocking: the plugin polls responses/<id>.json and replies through OpenCode's API,
        # so OpenCode's own prompt stays usable at the same time.
        alive, state = notch_state()
        title = f"OpenCode wants to {data.get('permission') or 'continue'}"
        req = new_request("opencode", sid, "permission", clip(title, 90), clip(data.get("detail"), 400), can_answer=alive,
                          options=["allow", "always", "deny"] if alive else [], tool=data.get("permission") or "", cwd=cwd)
        req["externalId"] = data.get("id")
        write_json(REQUESTS / f"{req['id']}.json", req)
        update_session("opencode", sid, status="waiting", activity="Waiting for permission", cwd=cwd, project=short_path(cwd))
        return {"requestId": req["id"]}
    elif event == "permission-replied":
        for f in REQUESTS.glob("opencode-*.json"):
            r = read_json(f)
            if r and r.get("externalId") == data.get("id"):
                f.unlink(missing_ok=True)
        update_session("opencode", sid, status="working", activity="Continuing")
    elif event == "question":
        choices = [clip(c, 40) for c in (data.get("choices") or []) if isinstance(c, str) and c][:6]
        new_request("opencode", sid, "question", clip(data.get("detail"), 300) or "OpenCode is asking", clip(data.get("header"), 40),
                    cwd=cwd, choices=choices, header=clip(data.get("header"), 40))
        update_session("opencode", sid, status="waiting", activity="Waiting for your answer")
    return None


def main(argv):
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 0
    platform, event = argv[1].lower(), argv[2]
    try:
        raw = sys.stdin.read() if not sys.stdin.isatty() else ""
        data = json.loads(raw) if raw.strip() else {}
    except ValueError:
        data = {}
    try:
        ensure_dirs()
        write_json(PLATFORMS / f"{platform}.json", {"platform": platform, "lastEventAt": time.time(), "lastEvent": event})
        if platform in ("claude", "codex"):
            out = handle_claude_style(platform, event, data)
        elif platform == "antigravity":
            out = handle_antigravity(event, data)
        elif platform == "opencode":
            out = handle_opencode(event, data)
        else:
            out = None
    except Exception as ex:  # never break the agent because of Notch
        try:
            (ROOT / "bridge-errors.log").open("a").write(f"{time.strftime('%FT%T')} {platform} {event}: {ex!r}\n")
        except OSError:
            pass
        out = {} if platform == "antigravity" else None
    if out is not None:
        sys.stdout.write(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
