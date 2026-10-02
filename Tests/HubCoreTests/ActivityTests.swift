import Foundation
import Testing
@testable import HubCore

@Suite(.serialized)
struct ActivityTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    func temporaryPaths() -> HubPaths {
        HubPaths(root: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("activity-\(UUID().uuidString)"))
    }

    @Test func roundTripAndBadLines() throws {
        let paths = temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let event = ActivityEvent(ts: now, kind: "job.started", job: "j", harness: "h", model: "m", detail: ["route": "direct"])
        Activity.record(event, paths: paths)
        let file = paths.logs.appendingPathComponent("events.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("broken JSON\n{\"kind\":\"bad\"}\n".utf8))
        try handle.close()
        Activity.log("job.finished", job: "j", ["long": String(repeating: "é", count: 400), "project": "/tmp/private/project"], paths: paths, now: now.addingTimeInterval(2))
        let events = Activity.read(paths: paths)
        #expect(events.count == 2)
        #expect(events.first == event)
        #expect(events.last?.detail["long"]?.count == 300)
        #expect(events.last?.detail["project"] == "project")
        #expect(Activity.read(paths: paths, since: now.addingTimeInterval(1)).count == 1)
        #expect(Activity.read(paths: paths, limit: 1) == [events[1]])
        #expect(Activity.read(paths: paths, limit: 0).isEmpty)
    }

    @Test func rotation() throws {
        let paths = temporaryPaths()
        let old = Activity.rotationThreshold
        Activity.rotationThreshold = 1
        defer {
            Activity.rotationThreshold = old
            try? FileManager.default.removeItem(at: paths.root)
        }
        for n in 0..<8 { Activity.log("test", ["n": String(n)], paths: paths) }
        let files = try FileManager.default.contentsOfDirectory(at: paths.logs, includingPropertiesForKeys: nil)
        #expect(files.filter { $0.lastPathComponent.hasPrefix("events-") }.count == 5)
        #expect(Activity.read(paths: paths).map { $0.detail["n"] } == ["7"])
        for file in files where file.lastPathComponent.hasPrefix("events-") {
            #expect((try Data(contentsOf: file)).last == 10)
        }
    }

    @Test func counts() {
        func event(_ kind: String, _ detail: [String: String] = [:], model: String? = nil) -> ActivityEvent {
            ActivityEvent(ts: now, kind: kind, model: model, detail: detail)
        }
        let stats = Activity.stats([
            event("job.started", model: "m"), event("job.started", model: "m"), event("job.started", model: "m"),
            event("job.finished", ["state": "verified", "seconds": "2"], model: "m"),
            event("job.finished", ["state": "failed", "seconds": "4"], model: "m"),
            event("job.finished", ["state": "queued", "seconds": "6"], model: "m"),
            event("masked.mask", ["result": "ok"]), event("masked.mask", ["result": "fail"]),
            event("masked.decode", ["result": "ok"]), event("masked.decode", ["result": "fail"]),
            event("masked.fallback", ["reason": String(repeating: "a", count: 80)]),
            event("policy.handoff"), event("policy.wrapup"), event("cooldown")
        ])
        #expect(stats.models["m"]?.started == 3)
        #expect(stats.models["m"]?.verified == 1)
        #expect(stats.models["m"]?.failed == 1)
        #expect(stats.models["m"]?.queuedBack == 1)
        #expect(stats.models["m"]?.avgSeconds == 4)
        #expect(stats.masked.attempted == 2)
        #expect(stats.masked.passed == 1)
        #expect(stats.masked.fallbacks == 1)
        #expect(stats.masked.fallbackReasons[String(repeating: "a", count: 60)] == 1)
        #expect(stats.handoffs == 1 && stats.wrapUps == 1 && stats.cooldowns == 1)
    }

    @Test func maskedRunLogsOnlyMetadata() throws {
        let paths = temporaryPaths()
        let project = paths.root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try "original".write(to: project.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try "exit 0\n".write(to: project.appendingPathComponent("test.sh"), atomically: true, encoding: .utf8)
        for argv in [["git", "init", "-q"], ["git", "add", "-A"], ["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"]] {
            #expect(Proc.run(argv, cwd: project.path).passed)
        }
        let config = MaskedTests().snapshot().config
        let runner = Runner(paths: paths, config: config)
        var job = Job(project: project.path, objective: "PRIVATE_OBJECTIVE_SENTINEL", allowedFiles: ["main.swift"], checkArgv: ["sh", "test.sh"], size: .hard, kind: .implement, privacy: .project, created: now)
        job.broker = "m1"
        Activity.queued(job, paths: paths)
        runner.exec = { argv, cwd, _, stdin, _, _ in
            let dir = URL(fileURLWithPath: cwd!)
            if argv.contains("m1") && (stdin ?? "").contains("MASK step") {
                try? "generic brief".write(to: dir.appendingPathComponent("brief.md"), atomically: true, encoding: .utf8)
                try? "{\"placeholders\":{\"P1\":\"orig\"},\"files\":{\"main.swift\":\"main.swift\"}}".write(to: dir.appendingPathComponent("map.json"), atomically: true, encoding: .utf8)
                try? "[\"sh\",\"check.sh\"]".write(to: dir.appendingPathComponent("check.json"), atomically: true, encoding: .utf8)
                try? "masked code".write(to: dir.appendingPathComponent("files/main.swift"), atomically: true, encoding: .utf8)
            } else if argv.contains("m1") && (stdin ?? "").contains("DECODE step") {
                try? "decoded code".write(to: dir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
            } else if argv.contains("m2") {
                try? "edited code".write(to: dir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
            }
            return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "PRIVATE_WORKER_OUTPUT_SENTINEL")
        }
        let final = runner.start(job, worker: config.model("m2")!, now: now)
        #expect(final.state == .verified)
        let events = Activity.read(paths: paths)
        for kind in ["job.queued", "job.started", "job.finished", "masked.mask", "masked.scan", "masked.heavy", "masked.decode"] {
            #expect(events.contains { $0.kind == kind })
        }
        #expect(events.first { $0.kind == "job.started" }?.detail["route"] == "masked")
        let text = try String(contentsOf: paths.logs.appendingPathComponent("events.jsonl"), encoding: .utf8)
        #expect(!text.contains(job.objective))
        #expect(!text.contains("PRIVATE_WORKER_OUTPUT_SENTINEL"))
        #expect(!text.contains(project.path))
    }

    @Test func maskedFallbackLogsOnlyReasonCategory() throws {
        let paths = temporaryPaths()
        let project = paths.root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try "original".write(to: project.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try "exit 0\n".write(to: project.appendingPathComponent("test.sh"), atomically: true, encoding: .utf8)
        for argv in [["git", "init", "-q"], ["git", "add", "-A"], ["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"]] {
            #expect(Proc.run(argv, cwd: project.path).passed)
        }
        let config = MaskedTests().snapshot().config
        let runner = Runner(paths: paths, config: config)
        var job = Job(project: project.path, objective: "objective", allowedFiles: ["main.swift"], checkArgv: ["sh", "test.sh"], size: .hard, kind: .implement, privacy: .project, created: now)
        job.broker = "m1"
        runner.exec = { argv, cwd, _, stdin, _, _ in
            let dir = URL(fileURLWithPath: cwd!)
            if argv.contains("m1") && (stdin ?? "").contains("MASK step") {
                try? "generic brief".write(to: dir.appendingPathComponent("brief.md"), atomically: true, encoding: .utf8)
                try? "{\"placeholders\":{\"P1\":\"orig\"},\"files\":{\"main.swift\":\"main.swift\"}}".write(to: dir.appendingPathComponent("map.json"), atomically: true, encoding: .utf8)
                try? "[\"sh\",\"check.sh\"]".write(to: dir.appendingPathComponent("check.json"), atomically: true, encoding: .utf8)
                try? "masked code".write(to: dir.appendingPathComponent("files/main.swift"), atomically: true, encoding: .utf8)
            } else if argv.contains("m2") {
                try? "edited code".write(to: dir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
            }
            let failing = argv.contains("check.sh")
            return CheckResult(argv: argv, exitCode: failing ? 1 : 0, timedOut: false, output: "PRIVATE_CHECK_OUTPUT_SENTINEL")
        }
        let final = runner.start(job, worker: config.model("m2")!, now: now)
        #expect(final.state == .queued)
        let fallback = Activity.read(paths: paths).first { $0.kind == "masked.fallback" }
        #expect(fallback?.detail["reason"] == "masked check failed")
        let text = try String(contentsOf: paths.logs.appendingPathComponent("events.jsonl"), encoding: .utf8)
        #expect(!text.contains("PRIVATE_CHECK_OUTPUT_SENTINEL"))
    }
}
