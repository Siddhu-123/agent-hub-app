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

    @Test func offloadAlwaysMasksTinyJobs() {
        var job = Job(project: "/tmp/p", objective: "obj", allowedFiles: [], checkArgv: [], size: .tiny, kind: .implement, privacy: .project, created: now)
        job.offload = true
        let plan = PolicyEngine.plan(snapshot(), job)
        #expect(plan?.worker.id == "m2")
        #expect(plan?.broker?.id == "m1")
    }

    @Test func offloadAlwaysFallsBackToLeastCapableTrustedBroker() {
        var s = snapshot()
        s.config.models[0].intelligence = 85 // nothing left in 55...79
        var job = Job(project: "/tmp/p", objective: "obj", allowedFiles: [], checkArgv: [], size: .tiny, kind: .implement, privacy: .project, created: now)
        job.offload = true
        #expect(PolicyEngine.plan(s, job)?.broker?.id == "m1") // 85 < m3's 90
        s.config.models[0].brokerEligible = false
        #expect(PolicyEngine.plan(s, job)?.broker?.id == "m3")
        job.offload = nil
        job.size = .hard
        #expect(PolicyEngine.plan(s, job)?.broker == nil) // auto mode keeps the old range-only behaviour
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
        
        let binaryFile = maskDir.appendingPathComponent("binary.bin")
        let invalidUtf8Bytes: [UInt8] = [0xFF, 0xFE, 0xFD, 0x80]
        try? Data(invalidUtf8Bytes).write(to: binaryFile)
        let problems = Masked.scan(dir: maskDir, tokens: ["secrettoken"])
        #expect(problems.contains("binary.bin: unreadable or binary file"))
    }
    
    @Test func feedbackScrubsDirsAndWithholdsPrivateText() {
        #expect(Masked.feedback("fail at /private/tmp/agenthub-mask-ab/files/x.py", dirs: ["/private/tmp/agenthub-mask-ab/files"], tokens: []) == "fail at ./x.py")
        #expect(Masked.feedback("fail for zephyrco", dirs: [], tokens: ["zephyrco"]) == "(output withheld)")
        #expect(Masked.feedback("see /Users/someone/x", dirs: [], tokens: []) == "(output withheld)")
    }

    @Test(arguments: [Int32(0), Int32(1)])
    func testRunnerFakeExec(heavyExit: Int32) throws {
        var s = snapshot()
        s.config.limits.jobTimeoutSeconds = 42.5
        s.config.harnesses[0].workerArgs.append("{timeout}s")
        let paths = HubPaths(root: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hub-\(UUID().uuidString)"))
        try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        
        let runner = Runner(paths: paths, config: s.config)
        // The project sits beside the hub data so the live job log is not a project change.
        let project = paths.root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        
        var job = Job(project: project.path, objective: "obj", allowedFiles: ["Sources/main.swift"], checkArgv: ["sh", "test.sh"], size: .hard, kind: .implement, privacy: .project, created: now)
        job.broker = "m1"
        try FileManager.default.createDirectory(at: project.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try? "original code".write(to: project.appendingPathComponent("Sources/main.swift"), atomically: true, encoding: .utf8)
        try "exit 0\n".write(to: project.appendingPathComponent("test.sh"), atomically: true, encoding: .utf8)
        for argv in [["git", "init", "-q"], ["git", "add", "-A"], ["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"]] {
            _ = Proc.run(argv, cwd: project.path)
        }
        
        let workerPrompts = Box<[String]>([])
        runner.exec = { argv, cwd, env, stdin, timeout, pidCallback, onOutput in
            let dir = cwd ?? ""
            if argv.contains(where: { $0 == "m1" }) {
                // Broker helper receives the configured fractional timeout.
                #expect(argv.contains("42.5s"))
                let prompt = stdin ?? ""
                if prompt.contains("MASK step") {
                    let filesDir = URL(fileURLWithPath: dir).appendingPathComponent("files")
                    try? "generic brief".write(to: URL(fileURLWithPath: dir).appendingPathComponent("brief.md"), atomically: true, encoding: .utf8)
                    try? "{\"placeholders\":{\"P1\":\"orig\"},\"files\":{\"neutral.swift\":\"Sources/main.swift\"}}".write(to: URL(fileURLWithPath: dir).appendingPathComponent("map.json"), atomically: true, encoding: .utf8)
                    try? "[\"sh\",\"check.sh\"]".write(to: URL(fileURLWithPath: dir).appendingPathComponent("check.json"), atomically: true, encoding: .utf8)
                    try? "masked code".write(to: filesDir.appendingPathComponent("neutral.swift"), atomically: true, encoding: .utf8)
                } else if prompt.contains("DECODE step") {
                    try? "decoded code".write(to: URL(fileURLWithPath: dir).appendingPathComponent("Sources/main.swift"), atomically: true, encoding: .utf8)
                }
                return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "broker ok")
            } else if argv.contains(where: { $0 == "m2" }) {
                // untrusted worker: must get the sandbox stage env, not the user's
                guard env?["OPENCODE_CONFIG_CONTENT"] != nil, env?["XDG_DATA_HOME"]?.hasPrefix("/private/tmp/agenthub-") == true else {
                    return CheckResult(argv: argv, exitCode: 1, timedOut: false, output: "no stage env")
                }
                // The first attempt does nothing; the retry must carry the scrubbed check output.
                workerPrompts.value.append(stdin ?? "")
                if workerPrompts.value.count > 1 {
                    try? "edited code".write(to: URL(fileURLWithPath: dir).appendingPathComponent("neutral.swift"), atomically: true, encoding: .utf8)
                }
                return CheckResult(argv: argv, exitCode: heavyExit, timedOut: false, output: "worker output")
            } else if argv.last == "check.sh" {
                let edited = (try? String(contentsOfFile: dir + "/neutral.swift", encoding: .utf8)) == "edited code"
                return CheckResult(argv: argv, exitCode: edited ? 0 : 1, timedOut: false, output: edited ? "check ok" : "not edited: \(dir)/neutral.swift")
            } else if argv == ["sh", "test.sh"] {
                return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "check ok")
            }
            return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "ok")
        }
        
        let finalJob = runner.start(job, worker: s.config.model("m2")!, now: now)
        #expect(finalJob.state == (heavyExit == 0 ? .verified : .needsReview))
        #expect(finalJob.note == (heavyExit == 0 ? "masked via m1" : "worker failed (nonzero exit)"))
        #expect(finalJob.masked == true)
        #expect(finalJob.maskedClasses == ["identifier"])
        #expect(finalJob.zdr == false)
        #expect(workerPrompts.value.count == 2)
        #expect(workerPrompts.value.last?.contains("not edited: ./neutral.swift") == true)
        #expect(workerPrompts.value.last?.contains("agenthub-mask") == false)
        #expect(try String(contentsOf: project.appendingPathComponent("Sources/main.swift"), encoding: .utf8) == "decoded code")
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
        
        runner.exec = { argv, cwd, env, stdin, timeout, pidCallback, onOutput in
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

    @Test func testRunnerFakeExecMissingBriefRecovery() throws {
        let s = snapshot()
        let paths = HubPaths(root: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hub-\(UUID().uuidString)"))
        try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)

        let runner = Runner(paths: paths, config: s.config)
        let project = paths.root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        var job = Job(project: project.path, objective: "obj", allowedFiles: ["main.swift"], checkArgv: ["sh", "test.sh"], size: .hard, kind: .implement, privacy: .project, created: now)
        job.broker = "m1"
        try? "original code".write(to: project.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try "exit 0\n".write(to: project.appendingPathComponent("test.sh"), atomically: true, encoding: .utf8)
        for argv in [["git", "init", "-q"], ["git", "add", "-A"], ["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"]] {
            _ = Proc.run(argv, cwd: project.path)
        }

        var maskAttempts = 0
        let workerPrompts = Box<[String]>([])
        runner.exec = { argv, cwd, env, stdin, timeout, pidCallback, onOutput in
            let dir = cwd ?? ""
            if argv.contains(where: { $0 == "m1" }) {
                let prompt = stdin ?? ""
                if prompt.contains("MASK step") {
                    maskAttempts += 1
                    let filesDir = URL(fileURLWithPath: dir).appendingPathComponent("files")
                    try? "masked code".write(to: filesDir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)

                    if maskAttempts == 1 {
                        // First attempt: skip writing valid files to trigger recovery
                        try? "   \n  \t ".write(to: URL(fileURLWithPath: dir).appendingPathComponent("brief.md"), atomically: true, encoding: .utf8)
                        try? "{\"placeholders\":{\"P1\":\"orig\"},\"files\":{}}".write(to: URL(fileURLWithPath: dir).appendingPathComponent("map.json"), atomically: true, encoding: .utf8)
                        try? "[\"\"]".write(to: URL(fileURLWithPath: dir).appendingPathComponent("check.json"), atomically: true, encoding: .utf8)
                    } else {
                        // Second attempt: write it correctly
                        try? "generic brief".write(to: URL(fileURLWithPath: dir).appendingPathComponent("brief.md"), atomically: true, encoding: .utf8)
                        try? "{\"placeholders\":{\"P1\":\"orig\"},\"files\":{\"main.swift\":\"main.swift\"}}".write(to: URL(fileURLWithPath: dir).appendingPathComponent("map.json"), atomically: true, encoding: .utf8)
                        try? "[\"sh\",\"check.sh\"]".write(to: URL(fileURLWithPath: dir).appendingPathComponent("check.json"), atomically: true, encoding: .utf8)
                    }
                } else if prompt.contains("DECODE step") {
                    try? "decoded code".write(to: URL(fileURLWithPath: dir).appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
                }
                return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "broker ok")
            } else if argv.contains(where: { $0 == "m2" }) {
                workerPrompts.value.append(stdin ?? "")
                try? "edited code".write(to: URL(fileURLWithPath: dir).appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
                return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "worker ok")
            } else if argv.last == "check.sh" || argv == ["sh", "test.sh"] {
                return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "check ok")
            }
            return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "ok")
        }

        let finalJob = runner.start(job, worker: s.config.model("m2")!, now: now)
        #expect(finalJob.state == .verified)
        #expect(maskAttempts == 2)
        #expect(workerPrompts.value.count == 1) // Heavy worker ran successfully
    }

    @Test func testRunnerFakeExecUnsuccessfulRecovery() throws {
        let s = snapshot()
        let paths = HubPaths(root: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hub-\(UUID().uuidString)"))
        try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let runner = Runner(paths: paths, config: s.config)
        let project = paths.root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        var job = Job(project: project.path, objective: "obj", allowedFiles: ["main.swift"], checkArgv: ["sh", "test.sh"], size: .hard, kind: .implement, privacy: .project, created: now)
        job.broker = "m1"
        try? "original code".write(to: project.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try "exit 0\n".write(to: project.appendingPathComponent("test.sh"), atomically: true, encoding: .utf8)
        for argv in [["git", "init", "-q"], ["git", "add", "-A"], ["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"]] {
            _ = Proc.run(argv, cwd: project.path)
        }

        var workerExecuted = false
        runner.exec = { argv, cwd, env, stdin, timeout, pidCallback, onOutput in
            if argv.contains(where: { $0 == "m1" }) {
                // Always fail to write brief.md
                let dir = cwd ?? ""
                let filesDir = URL(fileURLWithPath: dir).appendingPathComponent("files")
                try? "{\"placeholders\":{\"P1\":\"orig\"},\"files\":{\"main.swift\":\"main.swift\"}}".write(to: URL(fileURLWithPath: dir).appendingPathComponent("map.json"), atomically: true, encoding: .utf8)
                try? "[\"sh\",\"check.sh\"]".write(to: URL(fileURLWithPath: dir).appendingPathComponent("check.json"), atomically: true, encoding: .utf8)
                try? "masked code".write(to: filesDir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
                return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "broker ok")
            } else if argv.contains(where: { $0 == "m2" }) {
                workerExecuted = true
                return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "worker ok")
            }
            return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "ok")
        }

        let finalJob = runner.start(job, worker: s.config.model("m2")!, now: now)
        #expect(finalJob.state == .queued) // fallbackMasked
        #expect(finalJob.offload == false)
        #expect(!workerExecuted)
        #expect(finalJob.note?.contains("brief.md missing") == true)
    }

    @Test func testCancellationDuringMaskRepair() throws {
        let s = snapshot()
        let paths = HubPaths(root: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hub-\(UUID().uuidString)"))
        try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)

        let runner = Runner(paths: paths, config: s.config)
        let project = paths.root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        var job = Job(project: project.path, objective: "obj", allowedFiles: ["main.swift"], checkArgv: ["sh", "test.sh"], size: .hard, kind: .implement, privacy: .project, created: now)
        job.broker = "m1"
        try? "original code".write(to: project.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        let store = JobStore(paths: paths)
        try! store.enqueue(job)
        let queuedJob = store.active().first!

        var maskAttempts = 0
        runner.exec = { argv, cwd, env, stdin, timeout, pidCallback, onOutput in
            let dir = cwd ?? ""
            if argv.contains(where: { $0 == "m1" }) {
                let prompt = stdin ?? ""
                if prompt.contains("MASK step") {
                    maskAttempts += 1
                    let filesDir = URL(fileURLWithPath: dir).appendingPathComponent("files")
                    try? "masked code".write(to: filesDir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
                    if maskAttempts == 1 {
                        // First attempt: invalid artifacts
                        try? "".write(to: URL(fileURLWithPath: dir).appendingPathComponent("brief.md"), atomically: true, encoding: .utf8)
                    } else {
                        // Second attempt (repair): Cancel it!
                        runner.cancel(queuedJob.id) // This updates state to .cancelled in store
                    }
                }
                return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "broker ok")
            }
            return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "ok")
        }

        let finalJob = runner.start(queuedJob, worker: s.config.model("m2")!, now: now)
        #expect(finalJob.state == .cancelled)
        #expect(maskAttempts == 2)
    }
}

extension MaskedTests {
    @Test func failedFreeWorkerFallsThroughToAnotherRoute() throws {
        let s = snapshot()
        let paths = HubPaths(root: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hub-\(UUID().uuidString)"))
        try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let runner = Runner(paths: paths, config: s.config)
        let project = paths.root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var job = Job(project: project.path, objective: "obj", allowedFiles: ["main.swift"], checkArgv: ["sh", "test.sh"], size: .hard, kind: .implement, privacy: .project, requestedWorker: "m2", created: now)
        job.broker = "m1"
        job.offload = true
        try "original code".write(to: project.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        runner.exec = { argv, cwd, env, stdin, timeout, pidCallback, onOutput in
            let dir = cwd ?? ""
            if argv.contains("m1") {
                if (stdin ?? "").contains("MASK step") {
                    let files = URL(fileURLWithPath: dir).appendingPathComponent("files")
                    try? FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
                    try? "masked code".write(to: files.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
                    try? "generic brief".write(to: URL(fileURLWithPath: dir).appendingPathComponent("brief.md"), atomically: true, encoding: .utf8)
                    try? "{\"placeholders\":{\"P1\":\"orig\"},\"files\":{\"main.swift\":\"main.swift\"}}".write(to: URL(fileURLWithPath: dir).appendingPathComponent("map.json"), atomically: true, encoding: .utf8)
                    try? "[\"sh\",\"check.sh\"]".write(to: URL(fileURLWithPath: dir).appendingPathComponent("check.json"), atomically: true, encoding: .utf8)
                }
                return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "broker ok")
            }
            if argv.last == "check.sh" {
                // The masked check runs fenced in the stage, never in the mask dir.
                #expect(!dir.contains("agenthub-mask-"))
                #expect(argv.first == Sandbox.exe)
                return CheckResult(argv: argv, exitCode: 1, timedOut: false, output: "check failed")
            }
            return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "worker ok")
        }
        let result = runner.start(job, worker: s.config.model("m2")!, now: now)
        #expect(result.state == .queued)
        #expect(result.maskedTried == [s.config.model("m2")!.qualifiedID])
        #expect(result.requestedWorker == nil)
        #expect(result.offload == true)
        // The failed provider is excluded, so the next route is a trusted worker rather than a stuck queue.
        let next = PolicyEngine.plan(s, result)
        #expect(next?.worker.id == "m3")
        #expect(next?.broker == nil)
    }

    @Test func fencedSandboxSeesOnlyItsOwnStage() throws {
        guard Sandbox.available() else { return }
        let own = URL(fileURLWithPath: "/private/tmp/agenthub-fence-\(UUID().uuidString)")
        let other = URL(fileURLWithPath: "/private/tmp/agenthub-other-\(UUID().uuidString)")
        let mask = URL(fileURLWithPath: "/private/tmp/agenthub-mask-fence-\(UUID().uuidString)")
        for d in [own, other, mask] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        defer { for d in [own, other, mask] { try? FileManager.default.removeItem(at: d) } }
        try "x".write(to: other.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "x".write(to: mask.appendingPathComponent("map.json"), atomically: true, encoding: .utf8)
        try "exit 0\n".write(to: own.appendingPathComponent("t.sh"), atomically: true, encoding: .utf8)

        #expect(Proc.run(Sandbox.wrap(["/bin/sh", "t.sh"], own: own.path), cwd: own.path).passed)
        #expect(Proc.run(Sandbox.wrap(["/bin/sh", "-c", "echo hi > out.txt"], own: own.path), cwd: own.path).passed)
        #expect(!Proc.run(Sandbox.wrap(["/bin/cat", other.appendingPathComponent("a.txt").path], own: own.path)).passed)
        #expect(!Proc.run(Sandbox.wrap(["/bin/cat", mask.appendingPathComponent("map.json").path], own: own.path)).passed)
        #expect(!Proc.run(Sandbox.wrap(["/bin/ls", NSHomeDirectory()], own: own.path)).passed)
    }
}
