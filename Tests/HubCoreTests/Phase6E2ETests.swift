import Foundation
import Testing
@testable import HubCore

/// Acceptance scenario for Phase 6: Codex main exhausts → wrap_up → handoff to Claude → Claude delegates a routine
/// and a hard job → Codex resets, the Claude main is told, and a Codex job runs beside the others.
@Suite("Phase 6 E2E")
struct Phase6E2ETests {
    @Test func codexExhaustsHandsOffAndComesBack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hub-e2e-\(UUID().uuidString)")
        let paths = HubPaths(root: root)
        let project = root.appendingPathComponent("notch")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "struct A {}".write(to: project.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        try "struct B {}".write(to: project.appendingPathComponent("b.swift"), atomically: true, encoding: .utf8)
        try "struct C {}".write(to: project.appendingPathComponent("c.swift"), atomically: true, encoding: .utf8)
        try "exit 0\n".write(to: project.appendingPathComponent("test.sh"), atomically: true, encoding: .utf8)
        for argv in [["git", "init", "-q"], ["git", "add", "-A"], ["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"]] {
            _ = Proc.run(argv, cwd: project.path)
        }
        let config = ConfigStore.defaults()
        let usage = Box<[String: UsageReading]>(["codex": UsageReading(left: 0.9, source: "test"), "claude": UsageReading(left: 0.9, source: "test"),
                                                 "antigravity": UsageReading(left: 0.9, source: "test")])
        let relay = Relay(paths: paths, config: config, ctlPath: "agenthubctl", openScript: { _ in true }, usageProvider: { usage.value })
        let t0 = Date()
        func events() -> String { (try? String(contentsOf: paths.logs.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? "" }
        func snap(_ jobs: [Job] = [], at t: Date) -> Snapshot {
            Snapshot(config: config, usage: usage.value, sessions: relay.sessions(now: t), jobs: jobs, now: t)
        }
        func requireReceipt(_ j: Job) throws -> [String: Any] {
            let r = try Receipt.of(j, config: config)
            for key in ["state", "model", "zdr", "masked", "gate", "note"] { #expect(r[key] != nil, "receipt missing \(key)") }
            return r
        }

        // 1. Codex main works, then its quota runs out: one wrap_up, an automatic handoff file, state exhausted.
        _ = relay.hook("codex", event: "SessionStart", payload: ["session_id": "cx", "cwd": project.path, "model": "gpt-6.1-sol"], env: [:], now: t0)
        _ = relay.hook("codex", event: "UserPromptSubmit", payload: ["session_id": "cx", "prompt": "Notch Phase 6 drag gesture"], env: [:], now: t0.addingTimeInterval(1))
        usage.value["codex"] = UsageReading(left: 0.0, source: "test")
        _ = relay.hook("codex", event: "PostToolUse", payload: ["session_id": "cx"], env: [:], now: t0.addingTimeInterval(2))
        _ = relay.hook("codex", event: "PostToolUse", payload: ["session_id": "cx"], env: [:], now: t0.addingTimeInterval(3))
        let inboxFile = paths.inbox.appendingPathComponent("\(FileStore.key("codex", "cx")).json")
        let wraps = (FileStore.read([InboxMessage].self, from: inboxFile) ?? []).filter { $0.kind == .wrapUp }
        #expect(wraps.count == 1, "wrap_up is sent once, never resent")
        #expect(wraps.first?.text.contains("Claude Opus 5.5") == true)
        #expect(FileManager.default.fileExists(atPath: paths.handoffs.appendingPathComponent("auto-\(FileStore.key("codex", "cx")).md").path))
        let cx = relay.sessions(now: t0.addingTimeInterval(3)).first { $0.sessionId == "cx" }!
        #expect(PolicyEngine.state(snap(at: t0.addingTimeInterval(3)), cx) == .exhausted)

        // 2. Handoff to Claude: the record launches claude-opus-5-5, and the successor starts on that model.
        let file = project.appendingPathComponent("handoff.md")
        try "goal / done / next".write(to: file, atomically: true, encoding: .utf8)
        let record = try relay.handoff(from: "codex", session: "cx", project: project.path, file: file.path, to: nil, launch: true, automatic: false, now: t0.addingTimeInterval(4))
        #expect(record.toModel == "claude/claude-opus-5-5")
        let t1 = t0.addingTimeInterval(5)
        _ = relay.hook("claude", event: "SessionStart", payload: ["session_id": "cl", "cwd": project.path, "model": "claude-opus-5-5"], env: [:], now: t1)
        #expect(!events().contains("session.model_mismatch"))
        #expect(relay.sessions(now: t1).map(\.sessionId) == ["cl"], "the exhausted session freed its slot")

        // 3. Claude delegates a routine and a hard job. Codex is exhausted, so neither may land on it.
        func fakeExec(writes name: String) -> Runner.Exec {
            { argv, cwd, _, stdin, _, _, _ in
                let dir = URL(fileURLWithPath: cwd ?? project.path)
                let prompt = stdin ?? argv.last ?? ""
                if prompt.contains("MASK step") {
                    try? "generic brief".write(to: dir.appendingPathComponent("brief.md"), atomically: true, encoding: .utf8)
                    try? "{\"placeholders\":{\"P1\":\"orig\"},\"files\":{\"\(name)\":\"\(name)\"}}".write(to: dir.appendingPathComponent("map.json"), atomically: true, encoding: .utf8)
                    try? "[\"sh\",\"check.sh\"]".write(to: dir.appendingPathComponent("check.json"), atomically: true, encoding: .utf8)
                    try? "masked".write(to: dir.appendingPathComponent("files/\(name)"), atomically: true, encoding: .utf8)
                } else if prompt.contains("DECODE step") {
                    try? "decoded".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
                } else if argv.first != "sh" {
                    try? "edited \(argv.joined().count)".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
                }
                return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "ok")
            }
        }
        var routine = Job(project: project.path, objective: "rename A", allowedFiles: ["a.swift"], checkArgv: ["sh", "test.sh"], size: .routine, kind: .implement, privacy: .project, created: t1)
        routine.id = "j-routine"
        let routinePlan = try #require(PolicyEngine.plan(snap(at: t1), routine))
        #expect(routinePlan.worker.harness != "codex")
        routine.broker = routinePlan.broker?.qualifiedID
        let r1 = Runner(paths: paths, config: config)
        r1.exec = fakeExec(writes: "a.swift")
        let routineDone = r1.start(routine, worker: routinePlan.worker, now: t1)
        let routineReceipt = try requireReceipt(routineDone)
        #expect(routineDone.state == .verified, "\(routineReceipt)")

        var hard = Job(project: project.path, objective: "rework B", allowedFiles: ["b.swift"], checkArgv: ["sh", "test.sh"], size: .hard, kind: .implement, privacy: .project, created: t1)
        hard.id = "j-hard"
        hard.offload = true
        let hardPlan = try #require(PolicyEngine.plan(snap(at: t1), hard))
        #expect(hardPlan.worker.harness != "codex")
        hard.broker = hardPlan.broker?.qualifiedID
        let r2 = Runner(paths: paths, config: config)
        r2.exec = fakeExec(writes: "b.swift")
        let hardDone = r2.start(hard, worker: hardPlan.worker, now: t1)
        let hardReceipt = try requireReceipt(hardDone)
        #expect(hardDone.state == .verified, "\(hardReceipt)")
        #expect(hardPlan.broker != nil && config.harness(hardPlan.worker.harness)?.trusted == false, "hard project job goes to a free worker through the broker")
        #expect(hardReceipt["masked"] as? Bool == true)
        #expect((hardReceipt["maskedClasses"] as? [String])?.isEmpty == false)
        #expect(routineReceipt["masked"] as? Bool == false)

        // 4. Codex resets: the Claude main is told once, and a Codex job can run beside a running one.
        usage.value["codex"] = UsageReading(left: 0.9, source: "test")
        let t2 = t1.addingTimeInterval(60)
        _ = relay.hook("claude", event: "PostToolUse", payload: ["session_id": "cl"], env: [:], now: t2)
        _ = relay.hook("claude", event: "PostToolUse", payload: ["session_id": "cl"], env: [:], now: t2.addingTimeInterval(1))
        let clInbox = FileStore.read([InboxMessage].self, from: paths.inbox.appendingPathComponent("\(FileStore.key("claude", "cl")).json")) ?? []
        #expect(clInbox.filter { $0.text.hasPrefix("Codex available") }.count == 1)

        var busy = hard; busy.id = "j-busy"; busy.state = .running; busy.harness = hardPlan.worker.harness; busy.model = hardPlan.worker.qualifiedID
        var parallel = Job(project: project.path, objective: "tidy C", allowedFiles: ["c.swift"], checkArgv: ["sh", "test.sh"], size: .routine, kind: .implement, privacy: .project, created: t2)
        parallel.id = "j-codex"
        parallel.requestedWorker = "codex/gpt-6-luna"
        let parallelPlan = try #require(PolicyEngine.plan(snap([busy], at: t2), parallel))
        #expect(parallelPlan.worker.harness == "codex")
        let r3 = Runner(paths: paths, config: config)
        r3.exec = fakeExec(writes: "c.swift")
        let parallelDone = r3.start(parallel, worker: parallelPlan.worker, now: t2)
        let parallelReceipt = try requireReceipt(parallelDone)
        #expect(parallelDone.state == .verified, "\(parallelReceipt)")
        #expect(parallelReceipt["model"] as? String == "codex/gpt-6-luna")

        // 5. The monitor feed shows every step.
        let log = events()
        for marker in ["policy.wrapup", "\"exhausted\"", "policy.handoff", "policy.reset", "session.state"] {
            #expect(log.contains(marker), "events.jsonl missing \(marker)")
        }
    }
}
