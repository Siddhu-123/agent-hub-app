import Foundation
import Testing
@testable import HubCore

struct LiveFeedTests {
    func temporary() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    func json(_ file: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }
    @Test func lifecycleAndKeys() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = HubPaths(root: root), feed = LiveFeed(paths: paths)
        let env = ["TERM_PROGRAM": "Apple_Terminal"]
        _ = feed.handle(platform: "claude", event: "SessionStart", payload: ["session_id": "a/b", "cwd": "/work/project"], env: env, pid: getpid())
        let f = paths.live.appendingPathComponent("sessions/claude-a_b.json")
        let start = try json(f)
        #expect(start["pid"] as? Int == Int(getpid()))
        #expect(start["startedAt"] is Double)
        #expect(start["turnStartedAt"] is NSNull)
        #expect(start["platformName"] as? String == "Claude Code")
        _ = feed.handle(platform: "claude", event: "UserPromptSubmit", payload: ["session_id": "a/b", "prompt": "Add bubbles\nsecond line"], env: env, pid: getpid())
        _ = feed.handle(platform: "claude", event: "PreToolUse", payload: ["session_id": "a/b", "tool_name": "Bash", "tool_input": ["command": "swift build"]], env: env, pid: getpid())
        let session = try #require(feed.sessions().first)
        #expect(session.title == "Add bubbles")
        #expect(session.activity == "Running swift build")
        #expect(session.project == "project")
        #expect(session.app == "com.apple.Terminal")
        #expect(session.steps == 1)
        _ = feed.handle(platform: "claude", event: "Stop", payload: ["session_id": "a/b", "last_assistant_message": "All done."], env: env, pid: getpid())
        #expect(feed.sessions().first?.status == "done")
        _ = feed.handle(platform: "claude", event: "SessionEnd", payload: ["session_id": "a/b"], env: env, pid: getpid())
        #expect(feed.sessions().isEmpty)
        let events = Activity.read(paths: paths)
        #expect(events.filter { $0.kind == "live.session" }.count == 2)
        #expect(events.filter { $0.kind == "live.session" }.allSatisfy { $0.detail["project"] == "project" })
        #expect((try FileManager.default.attributesOfItem(atPath: f.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((try FileManager.default.attributesOfItem(atPath: paths.live.appendingPathComponent("platforms/claude.json").path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
    @Test func notificationsAndQuestion() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let feed = LiveFeed(paths: HubPaths(root: root))
        for (kind, expected) in [("idle_prompt", "attention"), ("permission_prompt", "permission"), ("elicitation_dialog", "question")] {
            _ = feed.handle(platform: "claude", event: "Notification", payload: ["session_id": "s", "notification_type": kind, "message": "Hello"], env: [:], pid: getpid())
            #expect(feed.requests().map(\.kind) == [expected])
        }
        let args: [String: Any] = ["questions": [["question": "Which option?", "header": "Choice", "options": [["label": "One"], ["label": "Two"]]]]]
        let payload: [String: Any] = ["session_id": "s", "tool_name": "AskUserQuestion", "tool_input": args]
        _ = feed.handle(platform: "claude", event: "PreToolUse", payload: payload, env: [:], pid: getpid())
        #expect(feed.handle(platform: "claude", event: "PermissionRequest", payload: payload, env: [:], pid: getpid()) == nil)
        _ = feed.handle(platform: "claude", event: "Notification", payload: ["session_id": "s", "notification_type": "permission_prompt"], env: [:], pid: getpid())
        let r = try #require(feed.requests().first)
        #expect(feed.requests().count == 1)
        #expect(r.title == "Which option?")
        #expect(r.header == "Choice")
        #expect(r.choices == ["One", "Two"])
        #expect(!r.canAnswer)
    }
    @Test func passiveUnlessBothAlive() throws {
        for alive in ["hub", "notch", "neither"] {
            let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
            let paths = HubPaths(root: root), feed = LiveFeed(paths: paths)
            if alive == "hub" { feed.writeHeartbeat(jobs: [], usage: [:], bands: [:], hooks: [:]) }
            if alive == "notch" {
                try FileManager.default.createDirectory(at: paths.live, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: ["alive_at": Date().timeIntervalSince1970, "hold_permissions": true]).write(to: paths.live.appendingPathComponent("notch.json"))
            }
            #expect(feed.handle(platform: "claude", event: "PermissionRequest", payload: ["tool_name": "Bash", "tool_input": ["command": "ls"]], env: [:], pid: getpid()) == nil)
            let r = try #require(feed.requests().first)
            #expect(!r.canAnswer && r.options.isEmpty && r.holdUntil == nil)
            #expect(Activity.read(paths: paths, limit: 10).last { $0.kind == "live.permission" }?.detail["outcome"] == "passive")
            _ = feed.handle(platform: "claude", event: "PostToolUse", payload: [:], env: [:], pid: getpid())
            #expect(feed.requests().isEmpty)
        }
    }
    @Test(arguments: ["allow", "always", "deny", "app"]) func heldAnswers(decision: String) throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = HubPaths(root: root), feed = LiveFeed(paths: paths, pollInterval: 0.01)
        feed.writeHeartbeat(jobs: [], usage: [:], bands: [:], hooks: [:])
        try JSONSerialization.data(withJSONObject: ["alive_at": Date().timeIntervalSince1970 + 60, "hold_permissions": true, "hold_seconds": 10]).write(to: paths.live.appendingPathComponent("notch.json"))
        let group = DispatchGroup(); group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            for _ in 0..<300 {
                if let request = feed.requests().first, request.canAnswer { feed.respond(requestId: request.id, decision: decision); return }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        let output = feed.handle(platform: "codex", event: "PermissionRequest", payload: ["tool_name": "exec_command", "tool_input": ["cmd": "ls"], "permission_suggestions": [["type": "addRules"]]], env: [:], pid: getpid())
        group.wait()
        if decision == "app" {
            #expect(output == nil)
            #expect(feed.requests().first?.canAnswer == false)
        } else {
            let hook = try #require(output?["hookSpecificOutput"] as? [String: Any])
            let body = try #require(hook["decision"] as? [String: Any])
            #expect(body["behavior"] as? String == (decision == "deny" ? "deny" : "allow"))
            #expect((body["updatedPermissions"] != nil) == (decision == "always"))
            #expect(feed.requests().isEmpty)
        }
    }
    @Test func workersAndOtherPlatforms() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = HubPaths(root: root), feed = LiveFeed(paths: paths)
        #expect(feed.handle(platform: "claude", event: "SessionStart", payload: [:], env: [HubPaths.workerEnv: "1"], pid: nil) == nil)
        #expect(!FileManager.default.fileExists(atPath: paths.live.path))
        let base: [String: Any] = ["conversationId": "c", "workspacePaths": ["/p/app"], "transcriptPath": "/x/antigravity-cli/t"]
        #expect(feed.handle(platform: "antigravity", event: "PreInvocation", payload: base, env: [:], pid: getpid())?.isEmpty == true)
        _ = feed.handle(platform: "antigravity", event: "PostToolUse", payload: ["conversationId": "c", "toolCall": ["name": "run_command", "args": ["CommandLine": "npm test"]]], env: [:], pid: getpid())
        #expect(feed.sessions().first?.platformName == "Antigravity CLI")
        #expect(feed.sessions().first?.activity == "Running npm test")
        _ = feed.handle(platform: "antigravity", event: "Stop", payload: ["conversationId": "c", "error": "Failed"], env: [:], pid: getpid())
        #expect(feed.sessions().first?.status == "error")
        for event in ["busy", "tool", "title", "error", "idle", "question"] {
            _ = feed.handle(platform: "opencode", event: event, payload: ["sessionID": "o", "title": "Title", "detail": "Choose"], env: [:], pid: getpid())
        }
        for id in ["p1", "p2"] {
            let out = feed.handle(platform: "opencode", event: "permission", payload: ["sessionID": "o", "id": id, "permission": "bash"], env: [:], pid: getpid())
            #expect(out?["requestId"] is String)
        }
        #expect(feed.requests().filter { $0.kind == "permission" }.count == 2)
        _ = feed.handle(platform: "opencode", event: "permission-replied", payload: ["sessionID": "o", "id": "p1"], env: [:], pid: getpid())
        #expect(feed.requests().filter { $0.kind == "permission" }.map(\.externalId) == ["p2"])
    }
    @Test func summariesAndHost() {
        #expect(LiveFeed.describeTool("Bash", ["command": ["swift", "test"]]) == "Running swift test")
        #expect(LiveFeed.describeTool("Edit", ["file_path": "/a/b.swift"]) == "Editing b.swift")
        #expect(LiveFeed.describeTool("Read", [:]) == "Reading files")
        #expect(LiveFeed.describeTool("grep", ["pattern": "foo"]) == "Searching foo")
        #expect(LiveFeed.describeTool("mcp__x__send", [:]) == "Using x · send")
        #expect(LiveFeed.describeTool("browser_click", [:]) == "Using the browser")
        #expect(LiveFeed.describeTool("update_plan", [:]) == "Updating plan")
        #expect(LiveFeed.hostApp(env: ["__CFBundleIdentifier": "org.python.python", "TERM_PROGRAM": "ghostty"], platform: "claude") == "com.mitchellh.ghostty")
        #expect(!LiveFeed.requestSummary("claude", "mcp__x__send", ["to": "team", "body": "hi", "n": ["a": 1]]).1.contains("{"))
    }
    @Test func heartbeatLaunchAndPruning() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = HubPaths(root: root), feed = LiveFeed(paths: paths), now = Date()
        #expect(feed.shouldLaunchHub(now: now))
        #expect(!feed.shouldLaunchHub(now: now.addingTimeInterval(14)))
        #expect(feed.shouldLaunchHub(now: now.addingTimeInterval(15)))
        var job = Job(project: "/secret/work/project", objective: String(repeating: "a", count: 200), allowedFiles: [], checkArgv: [], size: .tiny, kind: .implement, privacy: .project, created: now)
        job.harness = "codex"; job.model = "m"
        feed.writeHeartbeat(jobs: [job], usage: ["codex": UsageReading(left: nil, source: "test")], bands: ["codex": "single"], hooks: [:], now: now)
        let h = try json(paths.live.appendingPathComponent("hub.json"))
        let jobs = try #require(h["jobs"] as? [[String: Any]])
        #expect(jobs[0]["project"] as? String == "project")
        #expect((jobs[0]["objective"] as? String)?.count == 160)
        #expect(!String(decoding: try Data(contentsOf: paths.live.appendingPathComponent("hub.json")), as: UTF8.self).contains("secret"))
        #expect(feed.hubAlive(now: now))
        #expect(!feed.shouldLaunchHub(now: now))
        feed.markStopped(); #expect(!feed.hubAlive())
        _ = feed.handle(platform: "claude", event: "SessionStart", payload: [:], env: [:], pid: Int32.max)
        #expect(feed.sessions().isEmpty)
    }
}
