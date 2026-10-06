import Foundation
import Testing
@testable import HubCore

/// Regressions for the problems found during Notch Phase 6 (6 Oct 2026).
@Suite struct Phase6RegressionTests {
    let tmpDir: URL
    let paths: HubPaths
    let config: AppConfig
    let project: URL

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        paths = HubPaths(root: tmpDir)
        project = tmpDir.appendingPathComponent("notch")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let claude = Harness(id: "claude", name: "Claude", executable: "claude", trusted: true, usageSource: .claudeStatusline, hookStyle: .claude,
                             mainArgs: ["{exe}", "--model", "{model}", "{prompt}"], workerArgs: [])
        let codex = Harness(id: "codex", name: "Codex", executable: "codex", trusted: true, usageSource: .codexSessions, hookStyle: .codex,
                            mainArgs: ["{exe}", "-m", "{model}", "{prompt}"], workerArgs: [])
        let opencode = Harness(id: "opencode", name: "OpenCode", executable: "opencode", trusted: false, usageSource: .none, hookStyle: .none,
                               mainArgs: [], workerArgs: [])
        var bunny = ModelEntry(id: "space-bunny-free", harness: "opencode", name: "Space Bunny", intelligence: 81, isMain: false, isWorker: true, free: true)
        bunny.zdr = true; bunny.zdrSource = "user-declared (test)"; bunny.zdrDate = "2026-10-06"
        config = AppConfig(harnesses: [claude, codex, opencode], models: [
            ModelEntry(id: "claude-opus-5-5", harness: "claude", name: "Claude Opus", intelligence: 98, isMain: true, isWorker: false),
            ModelEntry(id: "gpt-6.1-sol", harness: "codex", name: "Codex Sol", intelligence: 97, isMain: true, isWorker: true),
            bunny,
        ], mainOrder: ["claude-opus-5-5", "gpt-6.1-sol"])
    }

    func handoffFile() throws -> String {
        let f = project.appendingPathComponent("handoff.md")
        try "goal / next steps".write(to: f, atomically: true, encoding: .utf8)
        return f.path
    }

    // MARK: 1. exhausted sessions free their slot; handoff is one-for-one

    @Test func handoffFromExhaustedSessionSucceedsWithReceiverAndSecondExhaustedSession() throws {
        let usage: [String: UsageReading] = ["codex": UsageReading(left: 0.0, source: "test"), "claude": UsageReading(left: 0.9, source: "test")]
        let opened = Box<Int>(0)
        let relay = Relay(paths: paths, config: config, ctlPath: "ctl", openScript: { _ in opened.value += 1; return true }, usageProvider: { usage })
        let t0 = Date()
        // The real 6 Oct state: two exhausted Codex sessions, then the user opens Claude to receive the handoff.
        _ = relay.hook("codex", event: "UserPromptSubmit", payload: ["session_id": "cx-a", "cwd": project.path, "model": "gpt-6.1-sol"], env: [:], now: t0)
        _ = relay.hook("codex", event: "UserPromptSubmit", payload: ["session_id": "cx-b", "cwd": project.path, "model": "gpt-6.1-sol"], env: [:], now: t0)
        _ = relay.hook("claude", event: "UserPromptSubmit", payload: ["session_id": "cl-r", "cwd": project.path, "model": "claude-opus-5-5"], env: [:], now: t0.addingTimeInterval(60))
        #expect(relay.sessions(now: t0.addingTimeInterval(60)).count == 3)
        // The receiver is not told to wrap up.
        #expect(relay.pending("claude", "cl-r").allSatisfy { $0.kind != .wrapUp })

        let record = try relay.handoff(from: "codex", session: "cx-a", project: project.path, file: handoffFile(), to: nil,
                                       launch: true, automatic: false, now: t0.addingTimeInterval(90))
        #expect(record.toModel == "claude/claude-opus-5-5")
        #expect(record.toSession == "cl-r")
        #expect(opened.value == 0) // adopted, not a second Claude terminal
        #expect(relay.pending("claude", "cl-r").contains { $0.kind == .task && $0.text.contains("handoff file") })
    }

    @Test func exhaustedSessionDoesNotHoldGlobalSlot() {
        var c = config
        c.limits.maxMainSessions = 2
        let now = Date()
        let s = Snapshot(config: c, usage: ["codex": UsageReading(left: 0.0, source: "t"), "claude": UsageReading(left: 0.9, source: "t")],
                         sessions: [MainSession(harness: "codex", sessionId: "x", model: "codex/gpt-6.1-sol", cwd: "/p", started: now, lastSeen: now, lastEvent: "Stop", status: .idle),
                                    MainSession(harness: "claude", sessionId: "y", model: "claude/claude-opus-5-5", cwd: "/q", started: now, lastSeen: now, lastEvent: "Stop", status: .idle)],
                         jobs: [], now: now)
        #expect(PolicyEngine.occupying(s).map(\.sessionId) == ["y"])
        #expect(PolicyEngine.canStartMain(s, "claude-opus-5-5").ok)
    }

    @Test func longIdleSessionDoesNotHoldGlobalSlot() {
        var c = config
        c.limits.maxMainSessions = 2
        let now = Date()
        let usage = ["claude": UsageReading(left: 0.9, source: "t")]
        func session(_ id: String, _ status: SessionStatus, idle: TimeInterval) -> MainSession {
            MainSession(harness: "claude", sessionId: id, model: "claude/claude-opus-5-5", cwd: "/p", started: now.addingTimeInterval(-3600),
                        lastSeen: now.addingTimeInterval(-idle), lastEvent: "Stop", status: status)
        }
        let s = Snapshot(config: c, usage: usage, sessions: [session("stale", .idle, idle: PolicyEngine.idleSlotGrace + 1),
                                                             session("fresh", .idle, idle: 10), session("busy", .working, idle: 600)],
                         jobs: [], now: now)
        #expect(PolicyEngine.occupying(s).map(\.sessionId) == ["fresh", "busy"])
    }

    // MARK: 2. failed handoff → handoff_blocked once, no wrap_up resends

    @Test func failedHandoffRecordsBlockedStateAndSendsOneFollowUp() throws {
        var c = config
        c.limits.maxMainSessions = 1
        let usage: [String: UsageReading] = ["codex": UsageReading(left: 0.0, source: "test"), "claude": UsageReading(left: 0.9, source: "test")]
        let relay = Relay(paths: paths, config: c, ctlPath: "ctl", openScript: { _ in true }, usageProvider: { usage })
        let t0 = Date()
        let other = tmpDir.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        _ = relay.hook("claude", event: "UserPromptSubmit", payload: ["session_id": "cl-busy", "cwd": other.path, "model": "claude-opus-5-5"], env: [:], now: t0)
        _ = relay.hook("codex", event: "UserPromptSubmit", payload: ["session_id": "cx", "cwd": project.path, "model": "gpt-6.1-sol"], env: [:], now: t0.addingTimeInterval(1))
        #expect(relay.pending("codex", "cx").filter { $0.kind == .wrapUp }.count == 1)

        for i in 0..<3 {
            #expect(throws: HubError.self) {
                _ = try relay.handoff(from: "codex", session: "cx", project: project.path, file: try handoffFile(), to: nil,
                                      launch: true, automatic: false, now: t0.addingTimeInterval(Double(10 + i)))
            }
        }
        let session = try #require(relay.sessions(now: t0.addingTimeInterval(20)).first { $0.sessionId == "cx" })
        #expect(session.handoffBlocked?.contains("Global limit of 1") == true)
        let pending = relay.pending("codex", "cx")
        #expect(pending.filter { $0.kind == .wrapUp }.isEmpty)
        let followUps = pending.filter { $0.text.hasPrefix("handoff_blocked:") }
        #expect(followUps.count == 1)
        #expect(followUps.first?.text.contains("Fix:") == true)
        #expect(followUps.first?.text.contains("claude/claude-opus-5-5@other") == true)

        // Later hooks deliver the follow-up once and never re-send or re-block on wrap_up.
        _ = relay.hook("codex", event: "UserPromptSubmit", payload: ["session_id": "cx"], env: [:], now: t0.addingTimeInterval(30))
        let stop = relay.hook("codex", event: "Stop", payload: ["session_id": "cx"], env: [:], now: t0.addingTimeInterval(31))
        #expect((stop?["reason"] as? String)?.contains("[agent-hub wrap_up]") != true)
        _ = relay.hook("codex", event: "Stop", payload: ["session_id": "cx"], env: [:], now: t0.addingTimeInterval(32))
        let inbox = FileStore.read([InboxMessage].self, from: paths.inbox.appendingPathComponent("\(FileStore.key("codex", "cx")).json")) ?? []
        #expect(inbox.filter { $0.kind == .wrapUp }.count == 1)
        #expect(inbox.filter { $0.text.hasPrefix("handoff_blocked:") }.count == 1)
    }

    @Test func blockedAutoHandoffIsNotRetriedEveryTick() {
        let now = Date()
        var s = MainSession(harness: "codex", sessionId: "x", model: "codex/gpt-6.1-sol", cwd: "/p", started: now, lastSeen: now, lastEvent: "Stop", status: .idle)
        s.warned = now.addingTimeInterval(-3600)
        s.blockedAt = now.addingTimeInterval(-30)
        s.handoffBlocked = "Global limit"
        let snap = Snapshot(config: config, usage: ["codex": UsageReading(left: 0.0, source: "t")], sessions: [s], jobs: [], now: now)
        let auto = PolicyEngine.rebalance(snap, alreadyWarned: [s.id]).filter { if case .autoHandoff = $0 { return true }; return false }
        #expect(auto.isEmpty)
        var later = snap
        later.now = now.addingTimeInterval(config.limits.graceSeconds)
        #expect(PolicyEngine.rebalance(later, alreadyWarned: [s.id]).contains { if case .autoHandoff = $0 { return true }; return false })
    }

    // MARK: 3. sudden quota failure leaves an automatic handoff file

    @Test func suddenQuotaFailureWritesAutomaticHandoffFile() throws {
        let usage = Box<[String: UsageReading]>(["codex": UsageReading(left: 0.6, source: "test"), "claude": UsageReading(left: 0.9, source: "test")])
        let relay = Relay(paths: paths, config: config, ctlPath: "ctl", openScript: { _ in true }, usageProvider: { usage.value })
        let t0 = Date().addingTimeInterval(-5)
        _ = relay.hook("codex", event: "UserPromptSubmit", payload: ["session_id": "cx", "cwd": project.path, "model": "gpt-6.1-sol",
                                                                     "prompt": "Implement the notch drag gesture"], env: [:], now: t0)
        try "struct Notch {}".write(to: project.appendingPathComponent("Notch.swift"), atomically: true, encoding: .utf8)
        var done = Job(project: project.path, objective: "build", allowedFiles: ["Notch.swift"], checkArgv: ["swift", "build"], size: .tiny, kind: .implement, privacy: .project, created: t0)
        done.id = "j-gate"; done.state = .failed
        done.gate = GateResult(acceptance: CheckResult(argv: ["swift", "build"], exitCode: 1, timedOut: false, output: "error: missing )"), changedFiles: [], outsideAllowed: [])
        try FileStore.write(done, to: paths.jobs.appendingPathComponent("j-gate.json"))

        // Quota drops to zero without warning; the next hook sends wrap_up, then the session dies (SessionEnd) without handing off.
        usage.value["codex"] = UsageReading(left: 0.0, source: "test")
        _ = relay.hook("codex", event: "PostToolUse", payload: ["session_id": "cx"], env: [:], now: t0.addingTimeInterval(2))
        let file = paths.handoffs.appendingPathComponent("auto-\(FileStore.key("codex", "cx")).md")
        #expect(FileManager.default.fileExists(atPath: file.path))
        try FileManager.default.removeItem(at: file)
        _ = relay.hook("codex", event: "SessionEnd", payload: ["session_id": "cx"], env: [:], now: t0.addingTimeInterval(3))

        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("Implement the notch drag gesture"))
        #expect(text.contains("- Notch.swift"))
        #expect(text.contains("`swift build` exit 1") && text.contains("failed"))
        let stored = FileStore.read(MainSession.self, from: paths.sessions.appendingPathComponent("\(FileStore.key("codex", "cx")).json"))
        #expect(stored?.autoHandoffFile == file.path)
    }

    @Test func sessionEndWithoutWarningWritesNoAutoHandoff() {
        let relay = Relay(paths: paths, config: config, ctlPath: "ctl", openScript: { _ in true }, usageProvider: { ["codex": UsageReading(left: 0.9, source: "t")] })
        _ = relay.hook("codex", event: "UserPromptSubmit", payload: ["session_id": "ok", "cwd": project.path, "model": "gpt-6.1-sol"], env: [:], now: Date())
        _ = relay.hook("codex", event: "SessionEnd", payload: ["session_id": "ok"], env: [:], now: Date())
        #expect(!FileManager.default.fileExists(atPath: paths.handoffs.appendingPathComponent("auto-\(FileStore.key("codex", "ok")).md").path))
    }

    // MARK: 10. quota reset notifies the active main session

    @Test func workerQuotaResetNotifiesActiveMainOnce() throws {
        let usage = Box<[String: UsageReading]>(["codex": UsageReading(left: 0.0, source: "test"), "claude": UsageReading(left: 0.9, source: "test")])
        let relay = Relay(paths: paths, config: config, ctlPath: "ctl", openScript: { _ in true }, usageProvider: { usage.value })
        let t = Date()
        var seen: [String] = []
        func hook(_ i: Int) {
            let out = relay.hook("claude", event: "PostToolUse", payload: ["session_id": "cl", "cwd": project.path, "model": "claude-opus-5-5"], env: [:], now: t.addingTimeInterval(Double(i)))
            if let out, let data = try? JSONSerialization.data(withJSONObject: out), let text = String(data: data, encoding: .utf8) { seen.append(text) }
            seen += relay.pending("claude", "cl").map(\.text)
            relay.markDone("claude", "cl", kind: .message, now: t.addingTimeInterval(Double(i)))
        }
        _ = relay.hook("claude", event: "SessionStart", payload: ["session_id": "cl", "cwd": project.path, "model": "claude-opus-5-5"], env: [:], now: t)
        hook(1)   // codex exhausted: remembered, nothing sent
        #expect(!seen.joined().contains("Codex available"))
        usage.value["codex"] = UsageReading(left: 0.9, source: "test")
        hook(2)   // codex reset
        hook(3)   // still healthy: no repeat
        let inbox = FileStore.read([InboxMessage].self, from: paths.inbox.appendingPathComponent("\(FileStore.key("claude", "cl")).json")) ?? []
        #expect(inbox.filter { $0.kind == .message && $0.text.hasPrefix("Codex available") }.count == 1)
        #expect(seen.joined().contains("[agent-hub message] Codex available") || seen.contains { $0.hasPrefix("Codex available") })
        let events = (try? String(contentsOf: paths.logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        #expect(events.contains("policy.reset"))
    }

    // MARK: 11. successor sessions start on the model the handoff asked for

    func launchedHandoff(_ id: String, created: Date) throws {
        let r = HandoffRecord(id: id, fromHarness: "codex", fromSession: "cx", toModel: "claude/claude-opus-5-5", project: project.path,
                              file: try handoffFile(), script: "s.command", launched: true, automatic: true, created: created)
        try FileStore.write(r, to: paths.handoffs.appendingPathComponent("\(id).json"))
    }

    @Test func successorOnWrongModelIsShown() throws {
        let relay = Relay(paths: paths, config: config, ctlPath: "ctl", openScript: { _ in true }, usageProvider: { ["claude": UsageReading(left: 0.9, source: "t")] })
        let t = Date()
        try launchedHandoff("h-wrong", created: t.addingTimeInterval(-10))
        _ = relay.hook("claude", event: "SessionStart", payload: ["session_id": "succ", "cwd": project.path, "model": "claude-sonnet-5-5"], env: [:], now: t)
        let events = (try? String(contentsOf: paths.logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        #expect(events.contains("session.model_mismatch") && events.contains("claude-sonnet-5-5"))
        let record = FileStore.read(HandoffRecord.self, from: paths.handoffs.appendingPathComponent("h-wrong.json"))
        #expect(record?.successorSession == "succ" && record?.successorModel == "claude-sonnet-5-5")
    }

    @Test func successorOnExpectedModelIsQuietAndMismatchReachesEligibleSession() throws {
        let relay = Relay(paths: paths, config: config, ctlPath: "ctl", openScript: { _ in true }, usageProvider: { ["claude": UsageReading(left: 0.9, source: "t"), "codex": UsageReading(left: 0.9, source: "t")] })
        let t = Date()
        try launchedHandoff("h-ok", created: t.addingTimeInterval(-10))
        _ = relay.hook("claude", event: "SessionStart", payload: ["session_id": "good", "cwd": project.path, "model": "claude-opus-5-5[1m]"], env: [:], now: t)
        var events = (try? String(contentsOf: paths.logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        #expect(!events.contains("session.model_mismatch"))
        #expect(FileStore.read(HandoffRecord.self, from: paths.handoffs.appendingPathComponent("h-ok.json"))?.successorSession == "good")

        // A handoff to Codex that starts on another main model: the session records the mismatch and is told.
        let r = HandoffRecord(id: "h-cx", fromHarness: "claude", fromSession: "good", toModel: "codex/gpt-6.1-sol", project: project.path,
                              file: try handoffFile(), script: "s.command", launched: true, automatic: false, created: t)
        try FileStore.write(r, to: paths.handoffs.appendingPathComponent("h-cx.json"))
        var c = config
        c.models.append(ModelEntry(id: "gpt-6-luna", harness: "codex", name: "Codex Luna", intelligence: 80, isMain: true, isWorker: true))
        let relay2 = Relay(paths: paths, config: c, ctlPath: "ctl", openScript: { _ in true }, usageProvider: { ["claude": UsageReading(left: 0.9, source: "t"), "codex": UsageReading(left: 0.9, source: "t")] })
        _ = relay2.hook("codex", event: "SessionStart", payload: ["session_id": "cx2", "cwd": project.path, "model": "gpt-6-luna"], env: [:], now: t.addingTimeInterval(1))
        events = (try? String(contentsOf: paths.logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""
        #expect(events.contains("session.model_mismatch"))
        let stored = FileStore.read(MainSession.self, from: paths.sessions.appendingPathComponent("\(FileStore.key("codex", "cx2")).json"))
        #expect(stored?.modelMismatch == "expected gpt-6.1-sol, got gpt-6-luna")
        #expect(relay2.pending("codex", "cx2").contains { $0.text.contains("expected gpt-6.1-sol") })
    }

    // MARK: 6. distinct session states

    @Test func sessionStatesAreDistinctAndLoggedOnTransition() throws {
        let usage = Box<[String: UsageReading]>(["codex": UsageReading(left: 0.9, source: "test")])
        let relay = Relay(paths: paths, config: config, ctlPath: "ctl", openScript: { _ in true }, usageProvider: { usage.value })
        let t = Date()
        func state() -> SessionState {
            let s = FileStore.read(MainSession.self, from: paths.sessions.appendingPathComponent("\(FileStore.key("codex", "st")).json"))!
            return PolicyEngine.state(Snapshot(config: config, usage: usage.value, sessions: [s], jobs: [], now: t), s)
        }
        _ = relay.hook("codex", event: "SessionStart", payload: ["session_id": "st", "cwd": project.path, "model": "gpt-6.1-sol"], env: [:], now: t)
        #expect(state() == .idle)
        _ = relay.hook("codex", event: "UserPromptSubmit", payload: ["session_id": "st"], env: [:], now: t)
        #expect(state() == .running)
        _ = relay.hook("codex", event: "PermissionRequest", payload: ["session_id": "st", "tool_name": "Bash"], env: [:], now: t)
        #expect(state() == .waiting)
        _ = relay.hook("codex", event: "PostToolUse", payload: ["session_id": "st"], env: [:], now: t)
        #expect(state() == .running)
        _ = relay.hook("codex", event: "Stop", payload: ["session_id": "st"], env: [:], now: t)
        #expect(state() == .idle)
        usage.value["codex"] = UsageReading(left: 0.0, source: "test")
        _ = relay.hook("codex", event: "UserPromptSubmit", payload: ["session_id": "st"], env: [:], now: t)
        #expect(state() == .exhausted)

        let log = try String(contentsOf: paths.logs.appendingPathComponent("events.jsonl"), encoding: .utf8)
        let states = log.split(separator: "\n").filter { $0.contains("session.state") }.compactMap { line -> String? in
            for st in ["idle", "running", "waiting", "exhausted"] where line.contains("\"state\":\"\(st)\"") { return st }
            return nil
        }
        #expect(states == ["idle", "running", "waiting", "running", "idle", "exhausted"])
    }

    // MARK: 3. wrap-up reserve

    @Test func wrapUpReserveFiresAtEightyEightPercentUsedEvenWithLowWrapUpBelow() {
        var c = config
        // The user's slider values on 6 Oct: wrap-up at 1.35% left.
        c.limits.exhaustedAtOrBelow = 0; c.limits.wrapUpBelow = 0.01345; c.limits.singleSessionBelow = 0.0205; c.limits.sameHarnessMinLeft = 0.0294
        let s = { (left: Double) in Snapshot(config: c, usage: ["codex": UsageReading(left: left, source: "t")], sessions: [], jobs: [], now: Date()) }
        #expect(PolicyEngine.band(s(0.13), "codex") == .healthy)
        #expect(PolicyEngine.band(s(0.11), "codex") == .wrapUp)
        c.limits.wrapUpReserve = 0
        #expect(PolicyEngine.band(Snapshot(config: c, usage: ["codex": UsageReading(left: 0.11, source: "t")], sessions: [], jobs: [], now: Date()), "codex") == .healthy)
    }

    // MARK: 4. router checks quota and cooldowns; queues with a reason

    func hardJob() -> Job {
        var j = Job(project: project.path, objective: "x", allowedFiles: ["a.swift"], checkArgv: ["true"], size: .routine, kind: .implement,
                    privacy: .project, mainModel: "claude-opus-5-5", created: Date())
        j.offload = false
        return j
    }

    @Test func exhaustedCodexQueuesWithReasonAndResetTime() {
        let now = Date()
        let reset = now.addingTimeInterval(4500)
        let usage = ["codex": UsageReading(left: 0.0, windows: [UsageWindow(name: "5h", usedPercent: 100, resetsAt: reset)], source: "codexSessions")]
        let s = Snapshot(config: config, usage: usage, sessions: [], jobs: [], now: now)
        #expect(PolicyEngine.plan(s, hardJob()) == nil)
        let why = PolicyEngine.whyQueued(s, hardJob())
        #expect(why.reason.contains("codex/gpt-6.1-sol: exhausted"))
        #expect(why.reason.contains("opencode/space-bunny-free: untrusted"))
        #expect(why.resetsAt == reset)
    }

    @Test func exhaustedCodexFallsBackToAllowedZDRWorker() {
        var c = config
        c.zdrProjectWorkers = true
        let s = Snapshot(config: c, usage: ["codex": UsageReading(left: 0.0, source: "t")], sessions: [], jobs: [], now: Date())
        #expect(PolicyEngine.plan(s, hardJob())?.worker.qualifiedID == "opencode/space-bunny-free")
        // A ZDR flag without a recorded source does not count.
        c.models[2].zdrSource = nil
        #expect(PolicyEngine.plan(Snapshot(config: c, usage: s.usage, sessions: [], jobs: [], now: s.now), hardJob()) == nil)
    }

    @Test func cooledModelIsNotRouted() {
        let now = Date()
        let s = Snapshot(config: config, usage: [:], sessions: [], jobs: [], now: now,
                         cooldowns: ["model:codex/gpt-6.1-sol": now.addingTimeInterval(600)])
        #expect(PolicyEngine.plan(s, hardJob()) == nil)
        #expect(PolicyEngine.whyQueued(s, hardJob()).reason.contains("codex/gpt-6.1-sol: cooling down"))
    }
}
