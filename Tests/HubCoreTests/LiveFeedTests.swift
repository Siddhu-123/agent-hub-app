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
    @Test func recentRingIsCappedAndSkipsDuplicateActivity() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let feed = LiveFeed(paths: HubPaths(root: root)), start = Date()
        for i in 0..<15 {
            _ = feed.handle(platform: "claude", event: "PreToolUse", payload: ["session_id": "s", "tool_name": "Bash", "tool_input": ["command": "cmd\(i)"]], env: [:], pid: nil, now: start.addingTimeInterval(Double(i)))
        }
        _ = feed.handle(platform: "claude", event: "PreToolUse", payload: ["session_id": "s", "tool_name": "Bash", "tool_input": ["command": "cmd14"]], env: [:], pid: nil, now: start.addingTimeInterval(20))
        let recent = try #require(feed.sessions().first?.recent)
        #expect(recent.count == 12)
        #expect(recent.first?.text == "Running cmd3")
        #expect(recent.last?.text == "Running cmd14")
    }

    @Test func tracksTaskAgentsAndRoutesSubagentActivity() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let feed = LiveFeed(paths: HubPaths(root: root)), now = Date()
        let start: [String: Any] = ["session_id": "s", "tool_name": "Agent", "tool_use_id": "tool-1", "tool_input": ["subagent_type": "researcher", "description": "Find the relevant sources"]]
        _ = feed.handle(platform: "claude", event: "PreToolUse", payload: start, env: [:], pid: nil, now: now)
        var session = try #require(feed.sessions().first)
        var agent = try #require(session.agents?.first)
        #expect(agent.id == "tool-1")
        #expect(agent.type == "researcher")
        #expect(agent.description == "Find the relevant sources")
        #expect(agent.status == "running")
        #expect(agent.activity == "Starting")
        let parentActivity = session.activity, parentRecent = session.recent
        _ = feed.handle(platform: "claude", event: "PreToolUse", payload: ["session_id": "s", "agent_id": "sub-1", "agent_type": "researcher", "tool_name": "Read", "tool_input": ["file_path": "/work/a.swift"]], env: [:], pid: nil, now: now.addingTimeInterval(1))
        session = try #require(feed.sessions().first); agent = try #require(session.agents?.first)
        #expect(agent.activity == "Reading a.swift")
        #expect(agent.recent?.last?.text == "Reading a.swift")
        #expect(session.activity == parentActivity)
        #expect(session.recent == parentRecent)
        #expect(session.steps == 2)
        _ = feed.handle(platform: "claude", event: "PostToolUse", payload: ["session_id": "s", "tool_name": "Agent", "tool_use_id": "tool-1"], env: [:], pid: nil, now: now.addingTimeInterval(2))
        agent = try #require(feed.sessions().first?.agents?.first)
        #expect(agent.status == "done")
        #expect(agent.finishedAt == now.addingTimeInterval(2).timeIntervalSince1970)
    }

    @Test func prunesOldDoneAgents() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let feed = LiveFeed(paths: HubPaths(root: root)), now = Date()
        _ = feed.handle(platform: "codex", event: "PreToolUse", payload: ["thread_id": "s", "tool_name": "Task", "tool_use_id": "old", "tool_input": ["prompt": "old task"]], env: [:], pid: nil, now: now)
        _ = feed.handle(platform: "codex", event: "PostToolUse", payload: ["thread_id": "s", "tool_name": "Task", "tool_use_id": "old"], env: [:], pid: nil, now: now)
        _ = feed.handle(platform: "codex", event: "PreToolUse", payload: ["thread_id": "s", "tool_name": "Bash", "tool_input": ["command": "next"]], env: [:], pid: nil, now: now.addingTimeInterval(601))
        #expect(feed.sessions().first?.agents?.isEmpty == true)
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
        // A dedicated thread: the GCD pool can be saturated by other suites' blocking waits.
        Thread {
            defer { group.leave() }
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                if let request = feed.requests().first, request.canAnswer { feed.respond(requestId: request.id, decision: decision); return }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }.start()
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
    @Test func codexSessionModelRefreshesFromLaterHookEvent() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = HubPaths(root: root), feed = LiveFeed(paths: paths), now = Date()

        _ = feed.handle(platform: "codex", event: "SessionStart", payload: [
            "session_id": "model-change",
            "cwd": "/work/project",
            "model": "gpt-5-codex"
        ], env: [:], pid: getpid(), now: now)
        #expect(feed.sessions(now: now).first?.model == "gpt-5-codex")

        _ = feed.handle(platform: "codex", event: "PostToolUse", payload: [
            "session_id": "model-change",
            "cwd": "/work/project",
            "model": "gpt-6.1-sol",
            "tool_name": "Bash",
            "tool_input": ["command": "true"]
        ], env: [:], pid: getpid(), now: now.addingTimeInterval(1))

        #expect(feed.sessions(now: now.addingTimeInterval(1)).first?.model == "gpt-6.1-sol")
        let sessionFile = paths.live.appendingPathComponent("sessions/codex-model-change.json")
        let persisted = try json(sessionFile)
        #expect(persisted["model"] as? String == "gpt-6.1-sol")
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

    @Test func testLiveFeedShowsNonMainModelsAndExcludesInternalPaths() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = HubPaths(root: root)

        let feed = LiveFeed(paths: paths)
        let now = Date()

        // 1. Non-main model (e.g. claude-sonnet-4-6 which is not in config) still appears in LiveFeed
        _ = feed.handle(platform: "claude", event: "UserPromptSubmit", payload: [
            "session_id": "sid_live_sonnet",
            "cwd": "/work/project",
            "model": "claude-sonnet-4-6"
        ], env: [:], pid: getpid(), now: now)

        let sessions = feed.sessions(now: now)
        #expect(sessions.contains { $0.sessionId == "sid_live_sonnet" && $0.model == "claude-sonnet-4-6" })

        // 2. A session with cwd under ~/.codex or ~/.claude is excluded from LiveFeed and not recorded
        let outBg = feed.handle(platform: "codex", event: "UserPromptSubmit", payload: [
            "session_id": "sid_live_bg",
            "cwd": "~/.codex/memories",
            "model": "gpt-6.1-sol"
        ], env: [:], pid: getpid(), now: now)
        #expect(outBg == nil)

        let fileBg = paths.live.appendingPathComponent("sessions/codex-sid_live_bg.json")
        #expect(!FileManager.default.fileExists(atPath: fileBg.path))
        #expect(!feed.sessions(now: now).contains { $0.sessionId == "sid_live_bg" })

        // 3. Persisted session file with internal cwd is deleted on sessions()
        let internalSession = LiveSession(
            platform: "codex",
            platformName: "Codex",
            sessionId: "sid_disk_bg",
            title: "Internal",
            status: "idle",
            activity: "",
            app: "",
            pid: nil,
            steps: 0,
            startedAt: now.timeIntervalSince1970,
            updatedAt: now.timeIntervalSince1970,
            cwd: "~/.codex/cache"
        )
        let diskBgFile = paths.live.appendingPathComponent("sessions/codex-sid_disk_bg.json")
        try FileManager.default.createDirectory(at: paths.live.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try JSONEncoder().encode(internalSession).write(to: diskBgFile)
        #expect(FileManager.default.fileExists(atPath: diskBgFile.path))

        let sessionsAfter = feed.sessions(now: now)
        #expect(!sessionsAfter.contains { $0.sessionId == "sid_disk_bg" })
        #expect(!FileManager.default.fileExists(atPath: diskBgFile.path))
    }
}
