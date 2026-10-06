import Testing
import Foundation
@testable import HubCore

@Suite("Phase 6 Runner regressions")
struct Phase6RunnerTests {
    func project() -> String {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try! FileManager.default.createDirectory(atPath: temp, withIntermediateDirectories: true)
        _ = Proc.run(["git", "init", "-q"], cwd: temp)
        _ = Proc.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "init"], cwd: temp)
        return temp
    }
    func paths() -> HubPaths { HubPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)) }
    let worker = ModelEntry(id: "gpt-6.1-sol", harness: "codex", name: "GPT-6.1 Sol", intelligence: 97, isMain: true, isWorker: true, effort: "xhigh")

    func job(_ p: String, kind: JobKind = .implement) -> Job {
        Job(project: p, objective: "edit allowed.txt", allowedFiles: ["allowed.txt"], checkArgv: ["echo", "ok"], size: .tiny, kind: kind, privacy: .project, created: Date())
    }

    @Test func implementWithZeroChangesFails() {
        let runner = Runner(paths: paths(), config: ConfigStore.defaults())
        runner.exec = { argv, _, _, _, _, _, _ in CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "done, all good") }
        let r = runner.start(job(project()), worker: worker, now: Date())
        #expect(r.state == .failed)
        #expect(r.note?.contains("no changes / writes denied") == true)
    }

    @Test func deniedWritesAreReportedInReceipt() {
        let runner = Runner(paths: paths(), config: ConfigStore.defaults())
        runner.exec = { argv, _, _, _, _, _, _ in
            CheckResult(argv: argv, exitCode: 0, timedOut: false,
                        output: "apply_patch failed: allowed.txt: Operation not permitted\nfinished")
        }
        let r = runner.start(job(project()), worker: worker, now: Date())
        #expect(r.state == .failed)
        #expect(r.permissionDenials?.first?.contains("Operation not permitted") == true)
        #expect(r.note?.contains("Operation not permitted") == true)
    }

    @Test func claudePermissionDenialsJSONIsParsed() {
        let json = #"{"type":"result","result":"I could not edit","permission_denials":[{"tool_name":"Edit","tool_use_id":"x","tool_input":{"file_path":"/p/allowed.txt"}}]}"#
        #expect(Runner.permissionDenials(json) == ["Edit /p/allowed.txt"])
        #expect(Runner.permissionDenials("all fine").isEmpty)
    }

    @Test func failedWorkerWithoutDenialsStaysNeedsReview() {
        let runner = Runner(paths: paths(), config: ConfigStore.defaults())
        runner.exec = { argv, _, _, _, _, _, _ in CheckResult(argv: argv, exitCode: argv.first == "echo" ? 0 : 2, timedOut: false, output: "crashed") }
        let r = runner.start(job(project()), worker: worker, now: Date())
        #expect(r.state != .verified)
        #expect(r.state != .failed || r.note?.contains("no changes") != true)
    }

    @Test func reviewJobWithZeroChangesStillVerifies() {
        let runner = Runner(paths: paths(), config: ConfigStore.defaults())
        runner.exec = { argv, _, _, _, _, _, _ in CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "review: looks good") }
        let r = runner.start(job(project(), kind: .review), worker: worker, now: Date())
        #expect(r.state != .failed)
    }

    // MARK: 7. ZDR allowlist route

    func zdrConfig(allowed: Bool) -> (AppConfig, ModelEntry) {
        var c = ConfigStore.defaults()
        c.harnesses.append(Harness(id: "opencode", name: "OpenCode", executable: "opencode", trusted: false, usageSource: .none, hookStyle: .none, mainArgs: [], workerArgs: ["{exe}", "run", "{prompt}"]))
        var bunny = ModelEntry(id: "space-bunny-free", harness: "opencode", name: "Space Bunny", intelligence: 81, isMain: false, isWorker: true, free: true)
        bunny.zdr = true; bunny.zdrSource = "user-declared (test)"; bunny.zdrDate = "2026-10-06"
        c.models.append(bunny)
        c.zdrProjectWorkers = allowed
        return (c, bunny)
    }

    @Test func allowedZDRWorkerRunsProjectJobInSandbox() {
        guard Sandbox.available() else { return }
        let (c, bunny) = zdrConfig(allowed: true)
        let runner = Runner(paths: paths(), config: c)
        runner.exec = { argv, cwd, _, _, _, _, _ in
            if argv.first != "echo" { try? "done".write(to: URL(fileURLWithPath: cwd!).appendingPathComponent("allowed.txt"), atomically: true, encoding: .utf8) }
            return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "ok")
        }
        let r = runner.start(job(project()), worker: bunny, now: Date())
        #expect(r.state == .verified)
        #expect(r.zdr == true)
        #expect(r.masked == false)
    }

    @Test func zdrWorkerWithoutUserApprovalCannotTakeProjectJob() {
        let (c, bunny) = zdrConfig(allowed: false)
        let runner = Runner(paths: paths(), config: c)
        runner.exec = { argv, _, _, _, _, _, _ in CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "ok") }
        let r = runner.start(job(project()), worker: bunny, now: Date())
        #expect(r.state == .failed)
        #expect(r.note == "untrusted harness only runs generic jobs")
    }

    @Test func zdrRequiresSourceAndDate() {
        var m = ModelEntry(id: "x", harness: "opencode", name: "X", intelligence: 50, isMain: false, isWorker: true)
        m.zdr = true
        #expect(!m.isZDR)
        m.zdrSource = "vendor policy"; m.zdrDate = "2026-10-06"
        #expect(m.isZDR)
    }

    // MARK: 8. masked classes

    @Test func maskedClassesAreRecorded() {
        let placeholders = ["P1": "Notch", "P2": "/Users/me/dev/notch/App.swift", "P3": "https://api.example.com/v1", "P4": "dev@example.com", "P5": "example.com", "P6": "notchState"]
        #expect(Masked.classes(placeholders: placeholders, labels: nil) == ["domain", "email", "identifier", "name", "path", "url"])
        #expect(Masked.classes(placeholders: ["P1": "x"], labels: ["P1": "Name"]) == ["name"])
        #expect(Masked.classes(placeholders: ["P1": "x"], labels: ["P1": "bogus"]) == ["identifier"])
    }
}

@Suite("Phase 6 fan-out")
struct Phase6FanoutTests {
    func snap() -> Snapshot {
        let trusted = Harness(id: "codex", name: "Codex", executable: "codex", trusted: true, usageSource: .none, hookStyle: .none, mainArgs: [], workerArgs: [])
        let oc = Harness(id: "opencode", name: "OpenCode", executable: "opencode", trusted: false, usageSource: .none, hookStyle: .none, mainArgs: [], workerArgs: [])
        let c = AppConfig(harnesses: [trusted, oc], models: [
            ModelEntry(id: "gpt-6-luna", harness: "codex", name: "Luna", intelligence: 80, isMain: false, isWorker: true),
            ModelEntry(id: "opencode/space-bunny-free", harness: "opencode", name: "Space Bunny", intelligence: 81, isMain: false, isWorker: true, free: true),
            ModelEntry(id: "opencode/longcat-2.5-preview-free", harness: "opencode", name: "Longcat", intelligence: 75, isMain: false, isWorker: true, free: true),
            ModelEntry(id: "opencode/longcat-2.4-free", harness: "opencode", name: "Longcat old", intelligence: 70, isMain: false, isWorker: true, free: true),
        ], mainOrder: [])
        return Snapshot(config: c, usage: [:], sessions: [], jobs: [], now: Date())
    }
    func job(files: [String]) -> Job {
        Job(project: "/tmp/p", objective: "refactor", allowedFiles: files, checkArgv: ["true"], size: .routine, kind: .implement, privacy: .project, created: Date())
    }

    @Test func splitSendsMaskedSlicesToDistinctProviders() throws {
        let slices = try Fanout.split(snap(), job(files: ["a.swift", "b.swift", "c.swift"]), n: 2, group: "g")
        #expect(slices.count == 2)
        #expect(slices.map(\.requestedWorker) == ["opencode/opencode/space-bunny-free", "opencode/opencode/longcat-2.5-preview-free"])
        let providers = slices.compactMap { $0.requestedWorker.flatMap { snap().config.model($0)?.providerKey } }
        #expect(Set(providers) == ["space", "longcat"])
        #expect(slices.allSatisfy { $0.offload == true && $0.splitOf == "g" })
        #expect(slices.map(\.slice) == ["1/2", "2/2"])
        #expect(slices[0].allowedFiles == ["a.swift", "c.swift"] && slices[1].allowedFiles == ["b.swift"])
        // Each slice plans as a masked job with a trusted broker on its own worker.
        for sl in slices {
            let plan = try #require(PolicyEngine.plan(snap(), sl))
            #expect(plan.worker.qualifiedID == sl.requestedWorker)
            #expect(plan.broker?.id == "gpt-6-luna")
        }
    }

    @Test func fanoutAndZDRFlagsParse() throws {
        let d = try CLIArgs(["delegate", "--fanout", "--split", "3", "--offload", "always"])
        #expect(d.has("fanout") && d.flags["split"] == ["3"])
        #expect(try CLIArgs(["models", "--zdr"]).has("zdr"))
    }

    @Test func splitRefusesWhenProvidersOrFilesAreShort() {
        #expect(throws: HubError.self) { try Fanout.split(snap(), job(files: ["a", "b", "c"]), n: 3, group: "g") } // only 2 providers
        #expect(throws: HubError.self) { try Fanout.split(snap(), job(files: ["a"]), n: 2, group: "g") }
        var generic = job(files: ["a", "b"]); generic.privacy = .generic
        #expect(throws: HubError.self) { try Fanout.split(snap(), generic, n: 2, group: "g") }
        #expect((try? Fanout.split(snap(), job(files: ["a", "b", "c"]), n: nil, group: "g"))?.count == 2) // --fanout
    }
}

@Test func cancelMarksActiveJobsOnly() throws {
    let paths = HubPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("cancel-\(UUID().uuidString)"))
    try FileManager.default.createDirectory(at: paths.jobs, withIntermediateDirectories: true)
    let store = JobStore(paths: paths)
    var j = Job(id: "j-1", project: "/tmp", objective: "x", allowedFiles: [], checkArgv: ["true"], size: .tiny, kind: .implement, privacy: .project, created: Date())
    j.state = .running
    try store.save(j)
    #expect(try store.cancel("j-1").state == .cancelled)
    #expect(store.get("j-1")?.state == .cancelled)
    #expect(throws: (any Error).self) { try store.cancel("j-1") }
    #expect(throws: (any Error).self) { try store.cancel("missing") }
}

@Test func antigravityModelsWithEffortGetTheFlag() {
    let agy = ConfigStore.defaults().harness("antigravity")!
    let claude = ModelEntry(id: "claude-opus-5-5", harness: "antigravity", name: "C", intelligence: 90, isMain: true, isWorker: true, effort: "medium")
    let gemini = ModelEntry(id: "gemini-3.8-flash-low", harness: "antigravity", name: "G", intelligence: 55, isMain: false, isWorker: true)
    let t = agy.withEffort(agy.workerArgs, claude)
    #expect(t[t.firstIndex(of: "{model}")! + 1 ..< t.firstIndex(of: "{model}")! + 3] == ["--effort", "medium"])
    #expect(agy.withEffort(agy.workerArgs, gemini) == agy.workerArgs)
    #expect(agy.withEffort(agy.mainArgs, claude).contains("--effort"))
}

@Test func cancelJobFlagParses() throws {
    let a = try CLIArgs(["cancel", "--job", "j-1"])
    #expect(a.subcommand == "cancel" && a.value("job") == "j-1")
}

struct FanoutCombineTests {
    func setup() throws -> (project: URL, wt: URL, slices: [Job]) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("combine-\(UUID().uuidString)")
        let project = root.appendingPathComponent("p"), wt = root.appendingPathComponent("wt")
        for d in [project, wt] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try "fixed a".write(to: project.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)
        try "old b".write(to: project.appendingPathComponent("b.py"), atomically: true, encoding: .utf8)
        try "fixed b".write(to: wt.appendingPathComponent("b.py"), atomically: true, encoding: .utf8)
        let fail = CheckResult(argv: ["c"], exitCode: 1, timedOut: false, output: "")
        var s1 = Job(project: project.path, objective: "o", allowedFiles: ["a.py"], checkArgv: ["c"], size: .routine, kind: .implement, privacy: .project, created: Date())
        s1.state = .needsReview; s1.gate = GateResult(acceptance: fail, changedFiles: ["a.py"], outsideAllowed: [])
        var s2 = s1
        s2.allowedFiles = ["b.py"]; s2.worktree = wt.path; s2.gate = GateResult(acceptance: fail, changedFiles: ["b.py"], outsideAllowed: [])
        return (project, wt, [s1, s2])
    }

    @Test func mergesSlicesAndRunsTheCheckOnce() throws {
        let (project, _, slices) = try setup()
        var runs = 0
        let c = Fanout.combine(slices, project: project.path, check: ["c"]) { argv, cwd in
            runs += 1
            #expect(cwd == project.path)
            return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "ok")
        }
        #expect(c?.passed == true)
        #expect(c?.applied == ["b.py"])
        #expect(runs == 1)
        #expect(try String(contentsOf: project.appendingPathComponent("b.py"), encoding: .utf8) == "fixed b")
    }

    @Test func failedCombinedCheckRestoresTheCheckout() throws {
        let (project, _, slices) = try setup()
        let c = Fanout.combine(slices, project: project.path, check: ["c"]) { argv, _ in CheckResult(argv: argv, exitCode: 1, timedOut: false, output: "no") }
        #expect(c?.passed == false)
        #expect(try String(contentsOf: project.appendingPathComponent("b.py"), encoding: .utf8) == "old b")
    }

    @Test func refusesWhenASliceIsNotReady() throws {
        let (project, _, slices) = try setup()
        var bad = slices
        bad[1].gate?.outsideAllowed = ["x.py"]
        #expect(Fanout.combine(bad, project: project.path, check: ["c"]) { _, _ in Issue.record("must not run"); return CheckResult(argv: [], exitCode: 0, timedOut: false, output: "") } == nil)
        bad = slices
        bad[0].state = .queued
        #expect(Fanout.combine(bad, project: project.path, check: ["c"]) { _, _ in Issue.record("must not run"); return CheckResult(argv: [], exitCode: 0, timedOut: false, output: "") } == nil)
    }
}

@Test func gateIgnoresInterpreterCaches() {
    #expect(Runner.isCacheArtifact("__pycache__/greet.cpython-314.pyc"))
    #expect(Runner.isCacheArtifact("pkg/__pycache__/x.pyc"))
    #expect(Runner.isCacheArtifact(".pytest_cache/v/cache/nodeids"))
    #expect(Runner.isCacheArtifact("a/.DS_Store"))
    #expect(!Runner.isCacheArtifact("greet.py"))
    #expect(!Runner.isCacheArtifact("pycache_notes.md"))
}
