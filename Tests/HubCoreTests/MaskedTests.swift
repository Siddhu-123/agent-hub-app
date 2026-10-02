import Foundation
import Testing
@testable import HubCore

struct MaskedTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    
    func snapshot() -> Snapshot {
        var lim = Limits()
        lim.maxJobs = 4
        lim.maskedOffloadSizes = ["hard"]
        lim.brokerMinIntelligence = 55
        lim.brokerMaxIntelligence = 79
        let harness = Harness(id: "h1", name: "h1", executable: "echo", trusted: true, usageSource: .none, hookStyle: .none, mainArgs: [], workerArgs: ["{exe}", "{model}"], promptViaStdin: true)
        let untrusted = Harness(id: "h2", name: "h2", executable: "echo", trusted: false, usageSource: .none, hookStyle: .none, mainArgs: [], workerArgs: ["{exe}", "{model}"], promptViaStdin: true)
        let m1 = ModelEntry(id: "m1", harness: "h1", name: "m1", intelligence: 60, isMain: false, isWorker: true, free: false) // broker
        let m2 = ModelEntry(id: "m2", harness: "h2", name: "m2", intelligence: 80, isMain: false, isWorker: true, free: true) // free worker
        let m3 = ModelEntry(id: "m3", harness: "h1", name: "m3", intelligence: 90, isMain: false, isWorker: true, free: false) // regular worker
        let config = AppConfig(harnesses: [harness, untrusted], models: [m1, m2, m3], mainOrder: [], limits: lim)
        return Snapshot(config: config, usage: [:], sessions: [], jobs: [], now: now)
    }

    @Test func testPlanPicksMaskedWorkerAndBroker() {
        let s = snapshot()
        let job = Job(project: "/tmp/p", objective: "obj", allowedFiles: [], checkArgv: [], size: .hard, kind: .implement, privacy: .project, created: now)
        let plan = PolicyEngine.plan(s, job)
        #expect(plan != nil)
        #expect(plan?.worker.id == "m2")
        #expect(plan?.broker?.id == "m1")
    }
    
    @Test func testPlanDoesNotPickMaskedForTiny() {
        let s = snapshot()
        let job = Job(project: "/tmp/p", objective: "obj", allowedFiles: [], checkArgv: [], size: .tiny, kind: .implement, privacy: .project, created: now)
        let plan = PolicyEngine.plan(s, job)
        #expect(plan?.worker.id == "m1")
        #expect(plan?.broker == nil)
    }
    
    @Test func testPlanDoesNotPickMaskedWhenOffloadFalse() {
        let s = snapshot()
        var job = Job(project: "/tmp/p", objective: "obj", allowedFiles: [], checkArgv: [], size: .hard, kind: .implement, privacy: .project, created: now)
        job.offload = false
        let plan = PolicyEngine.plan(s, job)
        #expect(plan?.worker.id == "m3")
        #expect(plan?.broker == nil)
    }

    @Test func testPlanNilBrokerWhenNoTier3Model() {
        var s = snapshot()
        s.config.models[0].intelligence = 90 // no model left in the tier-3 range
        let job = Job(project: "/tmp/p", objective: "obj", allowedFiles: [], checkArgv: [], size: .hard, kind: .implement, privacy: .project, created: now)
        let plan = PolicyEngine.plan(s, job)
        // Without a broker the job stays on a trusted worker.
        #expect(plan?.worker.harness == "h1")
        #expect(plan?.broker == nil)
    }
    
    @Test func testScanFlagsTokenPathEmail() {
        let maskDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: maskDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: maskDir) }
        
        let file = maskDir.appendingPathComponent("test.txt")
        try? "clean text".write(to: file, atomically: true, encoding: .utf8)
        #expect(Masked.scan(dir: maskDir, tokens: ["secrettoken"]).isEmpty)
        
        try? "has /Users/ dir".write(to: file, atomically: true, encoding: .utf8)
        #expect(!Masked.scan(dir: maskDir, tokens: ["secrettoken"]).isEmpty)
        
        try? "test@example.com".write(to: file, atomically: true, encoding: .utf8)
        #expect(!Masked.scan(dir: maskDir, tokens: ["secrettoken"]).isEmpty)
        
        try? "has secrettoken here".write(to: file, atomically: true, encoding: .utf8)
        #expect(!Masked.scan(dir: maskDir, tokens: ["secrettoken"]).isEmpty)
    }
    
    @Test func testRunnerFakeExec() throws {
        let s = snapshot()
        let paths = HubPaths(root: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hub-\(UUID().uuidString)"))
        try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        
        let runner = Runner(paths: paths, config: s.config)
        
        var job = Job(project: paths.root.path, objective: "obj", allowedFiles: ["main.swift"], checkArgv: ["sh", "test.sh"], size: .hard, kind: .implement, privacy: .project, created: now)
        job.broker = "m1"
        try? "original code".write(to: paths.root.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try "exit 0\n".write(to: paths.root.appendingPathComponent("test.sh"), atomically: true, encoding: .utf8)
        for argv in [["git", "init", "-q"], ["git", "add", "-A"], ["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"]] {
            _ = Proc.run(argv, cwd: paths.root.path)
        }
        
        runner.exec = { argv, cwd, env, stdin, timeout, pidCallback in
            let dir = cwd ?? ""
            if argv.contains(where: { $0 == "m1" }) {
                // broker
                let prompt = stdin ?? ""
                if prompt.contains("MASK step") {
                    let filesDir = URL(fileURLWithPath: dir).appendingPathComponent("files")
                    try? "generic brief".write(to: URL(fileURLWithPath: dir).appendingPathComponent("brief.md"), atomically: true, encoding: .utf8)
                    try? "{\"placeholders\":{\"P1\":\"orig\"},\"files\":{\"main.swift\":\"main.swift\"}}".write(to: URL(fileURLWithPath: dir).appendingPathComponent("map.json"), atomically: true, encoding: .utf8)
                    try? "[\"sh\",\"check.sh\"]".write(to: URL(fileURLWithPath: dir).appendingPathComponent("check.json"), atomically: true, encoding: .utf8)
                    try? "masked code".write(to: filesDir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
                } else if prompt.contains("DECODE step") {
                    try? "decoded code".write(to: URL(fileURLWithPath: dir).appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
                }
                return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "broker ok")
            } else if argv.contains(where: { $0 == "m2" }) {
                // untrusted worker: must get the sandbox stage env, not the user's
                guard env?["OPENCODE_CONFIG_CONTENT"] != nil, env?["XDG_DATA_HOME"]?.hasPrefix("/private/tmp/agenthub-") == true else {
                    return CheckResult(argv: argv, exitCode: 1, timedOut: false, output: "no stage env")
                }
                try? "edited code".write(to: URL(fileURLWithPath: dir).appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
                return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "worker ok")
            } else if argv.last == "check.sh" {
                let edited = (try? String(contentsOfFile: dir + "/main.swift", encoding: .utf8)) == "edited code"
                return CheckResult(argv: argv, exitCode: edited ? 0 : 1, timedOut: false, output: edited ? "check ok" : "not edited")
            } else if argv == ["sh", "test.sh"] {
                return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "check ok")
            }
            return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "ok")
        }
        
        let finalJob = runner.start(job, worker: s.config.model("m2")!, now: now)
        #expect(finalJob.state == .verified)
        #expect(finalJob.note == "masked via m1")
        #expect(try String(contentsOf: paths.root.appendingPathComponent("main.swift"), encoding: .utf8) == "decoded code")
    }

    @Test func testRunnerFakeExecLeakedToken() throws {
        let s = snapshot()
        let paths = HubPaths(root: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hub-\(UUID().uuidString)"))
        try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        
        let runner = Runner(paths: paths, config: s.config)
        
        var job = Job(project: paths.root.path, objective: "obj", allowedFiles: ["main.swift"], checkArgv: ["sh", "test.sh"], size: .hard, kind: .implement, privacy: .project, created: now)
        job.broker = "m1"
        try? "original code".write(to: paths.root.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try "exit 0\n".write(to: paths.root.appendingPathComponent("test.sh"), atomically: true, encoding: .utf8)
        for argv in [["git", "init", "-q"], ["git", "add", "-A"], ["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"]] {
            _ = Proc.run(argv, cwd: paths.root.path)
        }
        
        runner.exec = { argv, cwd, env, stdin, timeout, pidCallback in
            let dir = cwd ?? ""
            if argv.contains(where: { $0 == "m1" }) {
                let prompt = stdin ?? ""
                if prompt.contains("MASK step") {
                    let filesDir = URL(fileURLWithPath: dir).appendingPathComponent("files")
                    try? "generic brief with orig token leaked".write(to: URL(fileURLWithPath: dir).appendingPathComponent("brief.md"), atomically: true, encoding: .utf8)
                    try? "{\"placeholders\":{\"P1\":\"orig\"},\"files\":{\"main.swift\":\"main.swift\"}}".write(to: URL(fileURLWithPath: dir).appendingPathComponent("map.json"), atomically: true, encoding: .utf8)
                    try? "[\"sh\",\"check.sh\"]".write(to: URL(fileURLWithPath: dir).appendingPathComponent("check.json"), atomically: true, encoding: .utf8)
                    try? "masked code".write(to: filesDir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
                }
                return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "broker ok")
            }
            return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "ok")
        }
        
        let finalJob = runner.start(job, worker: s.config.model("m2")!, now: now)
        #expect(finalJob.state == .queued)
        #expect(finalJob.offload == false)
        #expect(finalJob.note?.contains("orig") == true)
        #expect(try String(contentsOf: paths.root.appendingPathComponent("main.swift"), encoding: .utf8) == "original code")
    }
}
