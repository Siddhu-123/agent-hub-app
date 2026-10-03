import Testing
import Foundation
@testable import HubCore
import CryptoKit

private final class JobResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Job?
    func set(_ value: Job) { lock.lock(); result = value; lock.unlock() }
    func get() -> Job? { lock.lock(); defer { lock.unlock() }; return result }
}

@Suite("Jobs Tests")
struct JobsTests {
    
    func createTempPaths() -> HubPaths {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return HubPaths(root: temp)
    }
    
    func createTempProject() -> String {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try! FileManager.default.createDirectory(atPath: temp, withIntermediateDirectories: true)
        _ = Proc.run(["git", "init", "-q"], cwd: temp)
        _ = Proc.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "init"], cwd: temp)
        return temp
    }
    
    @Test
    func testEnqueueValidation() throws {
        let paths = createTempPaths()
        let store = JobStore(paths: paths)
        let project = createTempProject()
        
        let validJob = Job(project: project, objective: "test", allowedFiles: ["file.txt"], checkArgv: ["echo", "ok"], size: .tiny, kind: .implement, privacy: .project, created: Date())
        
        // accepts valid
        try store.enqueue(validJob)
        let j = store.active().first!
        #expect(j.state == .queued)
        
        // invalid project
        var invalidProject = validJob; invalidProject.project = "/nonexistent/project"
        #expect(throws: HubError.self) { try store.enqueue(invalidProject) }
        
        // secret looking objective
        var secretJob = validJob; secretJob.objective = "my secret is password = 12345"
        #expect(throws: HubError.self) { try store.enqueue(secretJob) }
        
        // invalid file names
        var invalidFile = validJob; invalidFile.allowedFiles = ["/absolute/path"]
        #expect(throws: HubError.self) { try store.enqueue(invalidFile) }
        
        var hiddenFile = validJob; hiddenFile.allowedFiles = [".hidden"]
        #expect(throws: HubError.self) { try store.enqueue(hiddenFile) }
        
        var sensitiveFile = validJob; sensitiveFile.allowedFiles = ["credentials.json"]
        #expect(throws: HubError.self) { try store.enqueue(sensitiveFile) }
        
        // checkArgv
        var emptyArgv = validJob; emptyArgv.checkArgv = []
        #expect(throws: HubError.self) { try store.enqueue(emptyArgv) }
    }
    
    @Test
    func testCheckoutRunAllowedWrite() throws {
        let paths = createTempPaths()
        let project = createTempProject()
        
        var config = ConfigStore.defaults()
        let runner = Runner(paths: paths, config: config)
        
        let job = Job(project: project, objective: "test", allowedFiles: ["allowed.txt"], checkArgv: ["echo", "ok"], size: .tiny, kind: .implement, privacy: .project, created: Date())
        
        runner.exec = { argv, cwd, env, stdin, timeout, onStart, onOutput in
            // write allowed file
            let url = URL(fileURLWithPath: cwd!).appendingPathComponent("allowed.txt")
            try! "content".write(to: url, atomically: true, encoding: .utf8)
            return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "done")
        }
        
        let worker = ModelEntry(id: "gpt-6.1-sol", harness: "codex", name: "GPT-6.1 Sol", intelligence: 97, isMain: true, isWorker: true, effort: "xhigh")
        let result = runner.start(job, worker: worker, now: Date())
        
        #expect(result.state == .verified)
    }
    
    @Test
    func testCheckoutRunOutsideAllowed() throws {
        let paths = createTempPaths()
        let project = createTempProject()
        
        var config = ConfigStore.defaults()
        let runner = Runner(paths: paths, config: config)
        
        let job = Job(project: project, objective: "test", allowedFiles: ["allowed.txt"], checkArgv: ["echo", "ok"], size: .tiny, kind: .implement, privacy: .project, created: Date())
        
        runner.exec = { argv, cwd, env, stdin, timeout, onStart, onOutput in
            // write outside allowed
            let url = URL(fileURLWithPath: cwd!).appendingPathComponent("outside.txt")
            try! "content".write(to: url, atomically: true, encoding: .utf8)
            return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "done")
        }
        
        let worker = ModelEntry(id: "gpt-6.1-sol", harness: "codex", name: "GPT-6.1 Sol", intelligence: 97, isMain: true, isWorker: true, effort: "xhigh")
        let result = runner.start(job, worker: worker, now: Date())
        
        #expect(result.state == .needsReview)
        #expect(result.gate?.outsideAllowed == ["outside.txt"])
    }

    @Test
    func testCheckoutQuotaRequeueKeepsOriginalScopeBaseline() throws {
        let paths = createTempPaths()
        let project = createTempProject()
        var config = ConfigStore.defaults()
        config.harnesses.append(Harness(id: "custom", name: "Custom", executable: "c", accounts: ["acc1"], trusted: true, usageSource: .none, hookStyle: .none, mainArgs: [], workerArgs: []))
        let runner = Runner(paths: paths, config: config)
        let worker = ModelEntry(id: "custom-model", harness: "custom", name: "Custom", intelligence: 50, isMain: false, isWorker: true)
        let job = Job(project: project, objective: "t", allowedFiles: ["allowed.txt"], checkArgv: ["echo", "ok"], size: .tiny, kind: .implement, privacy: .project, created: Date())
        let store = JobStore(paths: paths)
        try store.enqueue(job)
        var callCount = 0
        runner.exec = { argv, cwd, env, stdin, timeout, onStart, onOutput in
            callCount += 1
            if callCount == 1 {
                try! "content".write(to: URL(fileURLWithPath: cwd!).appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
                return CheckResult(argv: argv, exitCode: 1, timedOut: false, output: "429 rate limit exceeded resets in 1h")
            }
            return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "done")
        }

        let now = Date()
        let first = runner.start(store.active().first!, worker: worker, now: now)
        #expect(first.state == .queued)
        #expect(first.baseline != nil)
        Cooldowns.set("account:acc1", until: now.addingTimeInterval(-10), paths: paths)
        let final = runner.start(store.active().first!, worker: worker, now: now)

        #expect(final.state == .needsReview)
        #expect(final.gate?.outsideAllowed == ["outside.txt"])
    }

    @Test
    func testCheckoutRunOutsideAllowedInNonGitProject() throws {
        let paths = createTempPaths()
        let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let project = projectURL.path
        let runner = Runner(paths: paths, config: ConfigStore.defaults())
        let job = Job(project: project, objective: "t", allowedFiles: ["allowed.txt"], checkArgv: ["echo", "ok"], size: .tiny, kind: .implement, privacy: .project, created: Date())
        let worker = ModelEntry(id: "gpt-6.1-sol", harness: "codex", name: "GPT", intelligence: 97, isMain: true, isWorker: true)
        runner.exec = { argv, cwd, env, stdin, timeout, onStart, onOutput in
            try! "content".write(to: URL(fileURLWithPath: cwd!).appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
            return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "done")
        }

        let result = runner.start(job, worker: worker, now: Date())
        #expect(result.state == .needsReview)
        #expect(result.gate?.outsideAllowed == ["outside.txt"])
    }
    
    @Test
    func testSandboxCollectFailureFailsJob() throws {
        let paths = createTempPaths()
        let project = createTempProject()
        try "blocked".write(to: URL(fileURLWithPath: project).appendingPathComponent("folder"), atomically: true, encoding: .utf8)
        let runner = Runner(paths: paths, config: ConfigStore.defaults())
        let worker = ModelEntry(id: "fake", harness: "opencode", name: "Fake", intelligence: 50, isMain: false, isWorker: true)
        let job = Job(project: project, objective: "t", allowedFiles: ["folder/output.txt"], checkArgv: ["echo", "ok"], size: .tiny, kind: .implement, privacy: .generic, created: Date())
        runner.exec = { argv, cwd, _, _, _, _, _ in
            try! "output".write(to: URL(fileURLWithPath: cwd!).appendingPathComponent("output.txt"), atomically: true, encoding: .utf8)
            return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "done")
        }
        let result = runner.start(job, worker: worker, now: Date())
        #expect(result.state == .failed)
        #expect(result.note?.hasPrefix("Sandbox.collect failed:") == true)
        #expect(result.gate == nil)
        #expect(JobLog.tail(paths, job.id).contains("job failed"))
    }

    @Test
    func testLockHeldIsolation() throws {
        let paths = createTempPaths()
        let project = createTempProject()
        
        // Take lock
        let stdProject = URL(fileURLWithPath: project).standardized.path
        let sha256 = SHA256.hash(data: Data(stdProject.utf8)).map { String(format: "%02x", $0) }.joined()
        try! FileManager.default.createDirectory(at: paths.locks, withIntermediateDirectories: true)
        let lockPath = paths.locks.appendingPathComponent("\(sha256).lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN); close(fd) }
        
        var config = ConfigStore.defaults()
        let runner = Runner(paths: paths, config: config)
        let worker = ModelEntry(id: "gpt-6.1-sol", harness: "codex", name: "GPT-6.1 Sol", intelligence: 97, isMain: true, isWorker: true, effort: "xhigh")
        
        // .checkout -> stays queued
        let job1 = Job(project: project, objective: "t", allowedFiles: ["a.txt"], checkArgv: ["echo"], size: .tiny, kind: .implement, privacy: .project, isolation: .checkout, created: Date())
        let store = JobStore(paths: paths)
        try! store.enqueue(job1)
        
        let res1 = runner.start(store.active().first!, worker: worker, now: Date())
        #expect(res1.state == .queued)
        
        // .worktree -> creates worktree
        let job2 = Job(project: project, objective: "t", allowedFiles: ["a.txt"], checkArgv: ["echo"], size: .tiny, kind: .implement, privacy: .project, isolation: .worktree, created: Date())
        try! store.enqueue(job2)
        
        runner.exec = { argv, cwd, env, stdin, timeout, onStart, onOutput in
            let url = URL(fileURLWithPath: cwd!).appendingPathComponent("a.txt")
            try! "content".write(to: url, atomically: true, encoding: .utf8)
            return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "done")
        }
        
        let res2 = runner.start(store.active().first(where: { $0.isolation == .worktree })!, worker: worker, now: Date())
        #expect(res2.state == .verified)
        #expect(res2.worktree?.hasSuffix("/" + res2.id) == true)
    }
    
    @Test
    func testMergeWorktree() throws {
        let paths = createTempPaths()
        let project = createTempProject()
        
        var config = ConfigStore.defaults()
        let runner = Runner(paths: paths, config: config)
        let worker = ModelEntry(id: "gpt-6.1-sol", harness: "codex", name: "GPT-6.1 Sol", intelligence: 97, isMain: true, isWorker: true, effort: "xhigh")
        
        let job = Job(project: project, objective: "t", allowedFiles: ["a.txt"], checkArgv: ["echo"], size: .tiny, kind: .implement, privacy: .project, isolation: .worktree, created: Date())
        let store = JobStore(paths: paths)
        try! store.enqueue(job)
        
        runner.exec = { argv, cwd, env, stdin, timeout, onStart, onOutput in
            let url = URL(fileURLWithPath: cwd!).appendingPathComponent("a.txt")
            try! "content".write(to: url, atomically: true, encoding: .utf8)
            _ = Proc.run(["git", "add", "a.txt"], cwd: cwd!)
            _ = Proc.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-m", "added a.txt"], cwd: cwd!)
            return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "done")
        }
        
        // Take lock so worktree is used
        let stdProject = URL(fileURLWithPath: project).standardized.path
        let sha256 = SHA256.hash(data: Data(stdProject.utf8)).map { String(format: "%02x", $0) }.joined()
        try! FileManager.default.createDirectory(at: paths.locks, withIntermediateDirectories: true)
        let lockPath = paths.locks.appendingPathComponent("\(sha256).lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        flock(fd, LOCK_EX)
        
        let res = runner.start(store.active().first!, worker: worker, now: Date())
        flock(fd, LOCK_UN); close(fd)
        
        #expect(res.state == .verified)
        
        try! runner.mergeWorktree(res)
        let finalStatus = Proc.run(["git", "status"], cwd: project).output
        #expect(!FileManager.default.fileExists(atPath: res.worktree!))
    }
    
    @Test
    func testQuotaFailover() throws {
        let paths = createTempPaths()
        let project = createTempProject()
        var config = ConfigStore.defaults()
        // custom harness with accounts
        let harness = Harness(id: "custom", name: "Custom", executable: "c", accounts: ["acc1", "acc2"], trusted: true, usageSource: .none, hookStyle: .none, mainArgs: [], workerArgs: [])
        config.harnesses.append(harness)
        let runner = Runner(paths: paths, config: config)
        let worker = ModelEntry(id: "custom-model", harness: "custom", name: "Custom", intelligence: 50, isMain: false, isWorker: true)
        
        let job = Job(project: project, objective: "t", allowedFiles: ["a.txt"], checkArgv: ["echo"], size: .tiny, kind: .implement, privacy: .project, created: Date())
        let store = JobStore(paths: paths)
        try! store.enqueue(job)
        
        runner.exec = { argv, cwd, env, stdin, timeout, onStart, onOutput in
            return CheckResult(argv: argv, exitCode: 1, timedOut: false, output: "429 rate limit exceeded resets in 1h")
        }
        
        let now = Date()
        let res = runner.start(store.active().first!, worker: worker, now: now)
        
        #expect(res.state == .queued)
        #expect(res.harness == nil)
        #expect(res.attempts.count == 2)
        #expect(Cooldowns.until(account: "acc1", paths: paths, now: now) != nil)
        #expect(Cooldowns.until(account: "acc2", paths: paths, now: now) != nil)
        #expect(Cooldowns.until(harness: "custom", paths: paths, now: now) != nil)
        
        // Try again -> should exhaust 3rd attempt
        // We need to clear cooldown on one account to allow 3rd attempt, otherwise it immediately returns.
        Cooldowns.set("account:acc1", until: now.addingTimeInterval(-10), paths: paths) // clear it
        let res2 = runner.start(store.active().first!, worker: worker, now: now)
        #expect(res2.state == .failed)
        #expect(res2.attempts.count == 3)
    }
    
    @Test
    func testOutputCompaction() throws {
        let paths = createTempPaths()
        let project = createTempProject()
        let config = ConfigStore.defaults()
        let runner = Runner(paths: paths, config: config)
        
        // Codex jsonl
        let job1 = Job(project: project, objective: "t", allowedFiles: ["a.txt"], checkArgv: ["echo"], size: .tiny, kind: .implement, privacy: .project, created: Date())
        let worker1 = ModelEntry(id: "gpt-6.1-sol", harness: "codex", name: "GPT", intelligence: 97, isMain: true, isWorker: true)
        runner.exec = { argv, cwd, env, stdin, timeout, onStart, onOutput in
            let longText = String(repeating: "A", count: 5000)
            let out = """
            {"type": "item.completed", "item": {"type": "agent_message", "text": "foo"}}
            {"type": "item.completed", "item": {"type": "agent_message", "text": "\(longText)"}}
            """
            return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: out)
        }
        let res1 = runner.start(job1, worker: worker1, now: Date())
        #expect(res1.output!.count == 4000)
        #expect(res1.output!.hasPrefix("AAA"))
        
        // Claude json
        let job2 = Job(project: project, objective: "t", allowedFiles: ["a.txt"], checkArgv: ["echo"], size: .tiny, kind: .implement, privacy: .project, created: Date())
        let worker2 = ModelEntry(id: "claude-opus-5-5", harness: "claude", name: "Claude", intelligence: 97, isMain: true, isWorker: true)
        runner.exec = { argv, cwd, env, stdin, timeout, onStart, onOutput in
            let longText = String(repeating: "B", count: 5000)
            let out = "{\"result\": \"\(longText)\"}"
            return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: out)
        }
        let res2 = runner.start(job2, worker: worker2, now: Date())
        #expect(res2.output!.count == 4000)
        #expect(res2.output!.hasPrefix("BBB"))
    }
    
    @Test
    func testCancel() throws {
        let paths = createTempPaths()
        let project = createTempProject()
        
        var config = ConfigStore.defaults()
        // we need a harness that executes sleep
        config.harnesses.append(Harness(id: "sleeper", name: "Sleeper", executable: "/bin/sleep", accounts: [], trusted: true, usageSource: .none, hookStyle: .none, mainArgs: [], workerArgs: ["/bin/sleep", "30"]))
        
        let runner = Runner(paths: paths, config: config)
        let worker = ModelEntry(id: "sleeper-model", harness: "sleeper", name: "Sleeper", intelligence: 50, isMain: false, isWorker: true)
        let job = Job(project: project, objective: "t", allowedFiles: ["a.txt"], checkArgv: ["echo"], size: .tiny, kind: .implement, privacy: .project, created: Date())
        let store = JobStore(paths: paths)
        try! store.enqueue(job)
        let queuedJob = store.active().first!
        
        let expectation = expectation(description: "cancel")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            runner.cancel(queuedJob.id)
            expectation.fulfill()
        }
        
        let res = runner.start(queuedJob, worker: worker, now: Date())
        #expect(res.state == .cancelled)
    }

    @Test
    func testCancelStopsAcceptanceCommand() throws {
        let paths = createTempPaths()
        let project = createTempProject()
        let runner = Runner(paths: paths, config: ConfigStore.defaults())
        let worker = ModelEntry(id: "gpt-6.1-sol", harness: "codex", name: "GPT", intelligence: 97, isMain: true, isWorker: true)
        let job = Job(project: project, objective: "t", allowedFiles: ["a.txt"], checkArgv: ["/bin/sleep", "30"], size: .tiny, kind: .implement, privacy: .project, created: Date())
        let store = JobStore(paths: paths)
        try store.enqueue(job)
        runner.exec = { argv, cwd, env, stdin, timeout, onStart, onOutput in
            return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "done")
        }

        let queuedJob = store.active().first!
        let resultBox = JobResultBox()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            resultBox.set(runner.start(queuedJob, worker: worker, now: Date()))
            finished.signal()
        }
        let deadline = Date().addingTimeInterval(10)
        while !JobLog.tail(paths, queuedJob.id).contains("check /bin/sleep 30") && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(JobLog.tail(paths, queuedJob.id).contains("check /bin/sleep 30"))
        Thread.sleep(forTimeInterval: 0.2)
        let cancelledAt = Date()
        runner.cancel(queuedJob.id)
        let waitResult = finished.wait(timeout: .now() + 5)

        #expect(waitResult == .success)
        #expect(Date().timeIntervalSince(cancelledAt) < 5)
        #expect(resultBox.get()?.state == .cancelled)
    }
    
    @Test
    func testWorktreeRequeueAfterQuotaReusesDirectory() throws {
        let paths = createTempPaths()
        let project = createTempProject()
        
        // Take lock so worktree is used
        let stdProject = URL(fileURLWithPath: project).standardized.path
        let sha256 = SHA256.hash(data: Data(stdProject.utf8)).map { String(format: "%02x", $0) }.joined()
        try! FileManager.default.createDirectory(at: paths.locks, withIntermediateDirectories: true)
        let lockPath = paths.locks.appendingPathComponent("\(sha256).lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN); close(fd) }
        
        var config = ConfigStore.defaults()
        let harness = Harness(id: "custom", name: "Custom", executable: "c", accounts: ["acc1"], trusted: true, usageSource: .none, hookStyle: .none, mainArgs: [], workerArgs: [])
        config.harnesses.append(harness)
        let runner = Runner(paths: paths, config: config)
        let worker = ModelEntry(id: "custom-model", harness: "custom", name: "Custom", intelligence: 50, isMain: false, isWorker: true)
        
        let job = Job(project: project, objective: "t", allowedFiles: ["a.txt"], checkArgv: ["echo"], size: .tiny, kind: .implement, privacy: .project, isolation: .worktree, created: Date())
        let store = JobStore(paths: paths)
        try! store.enqueue(job)
        
        // First run: returns quota error exitCode 1
        runner.exec = { argv, cwd, env, stdin, timeout, onStart, onOutput in
            return CheckResult(argv: argv, exitCode: 1, timedOut: false, output: "429 rate limit exceeded resets in 1h")
        }
        
        let now = Date()
        let res1 = runner.start(store.active().first!, worker: worker, now: now)
        #expect(res1.state == .queued)
        #expect(res1.worktree != nil)
        let worktreeDir = res1.worktree!
        #expect(FileManager.default.fileExists(atPath: worktreeDir))
        
        // Clear cooldowns
        Cooldowns.set("account:acc1", until: now.addingTimeInterval(-10), paths: paths)
        Cooldowns.set("harness:custom", until: now.addingTimeInterval(-10), paths: paths)
        
        // Second run: successful exec writes allowed file
        runner.exec = { argv, cwd, env, stdin, timeout, onStart, onOutput in
            let url = URL(fileURLWithPath: cwd!).appendingPathComponent("a.txt")
            try! "content".write(to: url, atomically: true, encoding: .utf8)
            return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "done")
        }
        
        let res2 = runner.start(store.active().first!, worker: worker, now: now)
        #expect(res2.state == .verified)
        #expect(res2.worktree == worktreeDir)
    }

    @Test
    func testWorktreeRequeueAfterQuotaStaleCopyReusesWorktree() throws {
        let paths = createTempPaths()
        let project = createTempProject()
        
        let stdProject = URL(fileURLWithPath: project).standardized.path
        let sha256 = SHA256.hash(data: Data(stdProject.utf8)).map { String(format: "%02x", $0) }.joined()
        try! FileManager.default.createDirectory(at: paths.locks, withIntermediateDirectories: true)
        let lockPath = paths.locks.appendingPathComponent("\(sha256).lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN); close(fd) }
        
        var config = ConfigStore.defaults()
        let harness = Harness(id: "custom", name: "Custom", executable: "c", accounts: ["acc1"], trusted: true, usageSource: .none, hookStyle: .none, mainArgs: [], workerArgs: [])
        config.harnesses.append(harness)
        let runner = Runner(paths: paths, config: config)
        let worker = ModelEntry(id: "custom-model", harness: "custom", name: "Custom", intelligence: 50, isMain: false, isWorker: true)
        
        let job = Job(project: project, objective: "t", allowedFiles: ["a.txt"], checkArgv: ["echo"], size: .tiny, kind: .implement, privacy: .project, isolation: .worktree, created: Date())
        let store = JobStore(paths: paths)
        try! store.enqueue(job)
        
        // Stale copy of the job as originally enqueued (worktree is nil)
        let staleCopy = store.active().first!
        #expect(staleCopy.worktree == nil)
        
        // First run: returns quota error exitCode 1
        runner.exec = { argv, cwd, env, stdin, timeout, onStart, onOutput in
            return CheckResult(argv: argv, exitCode: 1, timedOut: false, output: "429 rate limit exceeded resets in 1h")
        }
        
        let now = Date()
        let res1 = runner.start(staleCopy, worker: worker, now: now)
        #expect(res1.state == .queued)
        #expect(res1.worktree != nil)
        let worktreeDir = res1.worktree!
        #expect(FileManager.default.fileExists(atPath: worktreeDir))
        
        // Clear cooldowns
        Cooldowns.set("account:acc1", until: now.addingTimeInterval(-10), paths: paths)
        Cooldowns.set("harness:custom", until: now.addingTimeInterval(-10), paths: paths)
        
        // Second run: calling runner.start with staleCopy (worktree is nil)
        runner.exec = { argv, cwd, env, stdin, timeout, onStart, onOutput in
            let url = URL(fileURLWithPath: cwd!).appendingPathComponent("a.txt")
            try! "content".write(to: url, atomically: true, encoding: .utf8)
            return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "done")
        }
        
        let res2 = runner.start(staleCopy, worker: worker, now: now)
        #expect(res2.state == .verified)
        #expect(res2.worktree == worktreeDir)
    }

    @Test
    func testWorktreeRecreatedFromExistingBranchWhenDirectoryDeleted() throws {
        let paths = createTempPaths()
        let project = createTempProject()
        
        let stdProject = URL(fileURLWithPath: project).standardized.path
        let sha256 = SHA256.hash(data: Data(stdProject.utf8)).map { String(format: "%02x", $0) }.joined()
        try! FileManager.default.createDirectory(at: paths.locks, withIntermediateDirectories: true)
        let lockPath = paths.locks.appendingPathComponent("\(sha256).lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN); close(fd) }
        
        var config = ConfigStore.defaults()
        let harness = Harness(id: "custom", name: "Custom", executable: "c", accounts: ["acc1"], trusted: true, usageSource: .none, hookStyle: .none, mainArgs: [], workerArgs: [])
        config.harnesses.append(harness)
        let runner = Runner(paths: paths, config: config)
        let worker = ModelEntry(id: "custom-model", harness: "custom", name: "Custom", intelligence: 50, isMain: false, isWorker: true)
        
        let job = Job(project: project, objective: "t", allowedFiles: ["a.txt"], checkArgv: ["echo"], size: .tiny, kind: .implement, privacy: .project, isolation: .worktree, created: Date())
        let store = JobStore(paths: paths)
        try! store.enqueue(job)
        
        // First run: returns quota error exitCode 1
        runner.exec = { argv, cwd, env, stdin, timeout, onStart, onOutput in
            return CheckResult(argv: argv, exitCode: 1, timedOut: false, output: "429 rate limit exceeded resets in 1h")
        }
        
        let now = Date()
        let res1 = runner.start(store.active().first!, worker: worker, now: now)
        #expect(res1.state == .queued)
        guard let worktreeDir = res1.worktree else {
            Issue.record("Expected worktree to be non-nil")
            return
        }
        #expect(FileManager.default.fileExists(atPath: worktreeDir))
        
        // Delete worktree directory via FileManager without deleting git branch
        try FileManager.default.removeItem(atPath: worktreeDir)
        #expect(!FileManager.default.fileExists(atPath: worktreeDir))
        
        // Clear cooldowns
        Cooldowns.set("account:acc1", until: now.addingTimeInterval(-10), paths: paths)
        Cooldowns.set("harness:custom", until: now.addingTimeInterval(-10), paths: paths)
        
        // Second run: should recreate worktree from existing branch and succeed
        runner.exec = { argv, cwd, env, stdin, timeout, onStart, onOutput in
            let url = URL(fileURLWithPath: cwd!).appendingPathComponent("a.txt")
            try! "content".write(to: url, atomically: true, encoding: .utf8)
            return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "done")
        }
        
        let res2 = runner.start(store.active().first!, worker: worker, now: now)
        #expect(res2.state == .verified)
        #expect(res2.worktree == worktreeDir)
        #expect(FileManager.default.fileExists(atPath: worktreeDir))
    }

    @Test
    func testJobLockHeldPreventsExecution() throws {
        let paths = createTempPaths()
        let project = createTempProject()
        
        var config = ConfigStore.defaults()
        let runner = Runner(paths: paths, config: config)
        let worker = ModelEntry(id: "gpt-6.1-sol", harness: "codex", name: "GPT-6.1 Sol", intelligence: 97, isMain: true, isWorker: true, effort: "xhigh")
        
        let job = Job(project: project, objective: "t", allowedFiles: ["a.txt"], checkArgv: ["echo"], size: .tiny, kind: .implement, privacy: .project, isolation: .worktree, created: Date())
        let store = JobStore(paths: paths)
        try! store.enqueue(job)
        let queuedJob = store.active().first!
        
        // Another fd holds flock on the job lock file
        try! FileManager.default.createDirectory(at: paths.locks, withIntermediateDirectories: true)
        let jobLockPath = paths.locks.appendingPathComponent("job-\(queuedJob.id).lock").path
        let fd = open(jobLockPath, O_CREAT | O_RDWR, 0o600)
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN); close(fd) }
        
        var execCalled = false
        runner.exec = { argv, cwd, env, stdin, timeout, onStart, onOutput in
            execCalled = true
            return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "done")
        }
        
        let res = runner.start(queuedJob, worker: worker, now: Date())
        #expect(res.state == .queued)
        #expect(!execCalled)
        #expect(store.get(queuedJob.id)?.state == .queued)
    }

    @Test
    func testSuccessfulOutputWithQuotaKeywordsNotTreatedAsQuota() throws {
        let paths = createTempPaths()
        let project = createTempProject()
        
        let config = ConfigStore.defaults()
        let runner = Runner(paths: paths, config: config)
        let worker = ModelEntry(id: "gpt-6.1-sol", harness: "codex", name: "GPT-6.1 Sol", intelligence: 97, isMain: true, isWorker: true, effort: "xhigh")
        
        let job = Job(project: project, objective: "review quota logic", allowedFiles: ["a.txt"], checkArgv: ["echo", "ok"], size: .tiny, kind: .implement, privacy: .project, created: Date())
        let store = JobStore(paths: paths)
        try! store.enqueue(job)
        
        runner.exec = { argv, cwd, env, stdin, timeout, onStart, onOutput in
            let url = URL(fileURLWithPath: cwd!).appendingPathComponent("a.txt")
            try! "content".write(to: url, atomically: true, encoding: .utf8)
            return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "code review complete: verified 429 rate limit exceeded resets in 1h handling")
        }
        
        let now = Date()
        let res = runner.start(store.active().first!, worker: worker, now: now)
        #expect(res.state == .verified)
        #expect(Cooldowns.until(model: "gpt-6.1-sol", paths: paths, now: now) == nil)
    }

    @Test
    func testCancelDoesNotKillReusedPid() throws {
        let paths = createTempPaths()
        let project = createTempProject()
        
        let config = ConfigStore.defaults()
        let runner = Runner(paths: paths, config: config)
        let worker = ModelEntry(id: "gpt-6.1-sol", harness: "codex", name: "GPT-6.1 Sol", intelligence: 97, isMain: true, isWorker: true)
        
        let job = Job(project: project, objective: "t", allowedFiles: ["a.txt"], checkArgv: ["echo"], size: .tiny, kind: .implement, privacy: .project, created: Date())
        let store = JobStore(paths: paths)
        try! store.enqueue(job)
        let queuedJob = store.active().first!
        
        // Spawn a dummy process that stays alive, pretending its PID is later reused
        let dummy = Process()
        dummy.executableURL = URL(fileURLWithPath: "/bin/sleep")
        dummy.arguments = ["10"]
        try dummy.run()
        defer {
            dummy.terminate()
            dummy.waitUntilExit()
        }
        let dummyPid = dummy.processIdentifier
        
        // exec reports dummyPid onStart, but exits immediately before runner.cancel is called
        runner.exec = { argv, cwd, env, stdin, timeout, onStart, onOutput in
            onStart(dummyPid)
            return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "done")
        }
        
        _ = runner.start(queuedJob, worker: worker, now: Date())
        // At this point, job finished and runner.pids[queuedJob.id] was removed.
        // Calling cancel(queuedJob.id) should find no pid in pids, or if pid was captured before,
        // the async recheck ensures pids[id] == pid before SIGKILL.
        runner.cancel(queuedJob.id)
        
        // Wait 2.2 seconds for the async SIGKILL block to execute
        Thread.sleep(forTimeInterval: 2.2)
        
        // dummy process must still be running (not killed by SIGKILL)
        #expect(dummy.isRunning)
    }

    @Test
    func testMaskedDecodeHelperFailureSetsNeedsReview() throws {
        var lim = Limits()
        lim.maxJobs = 4
        lim.maskedOffloadSizes = ["hard"]
        lim.brokerMinIntelligence = 55
        lim.brokerMaxIntelligence = 79
        let h1 = Harness(id: "h1", name: "h1", executable: "echo", trusted: true, usageSource: .none, hookStyle: .none, mainArgs: [], workerArgs: ["{exe}", "{model}"], promptViaStdin: true)
        let h2 = Harness(id: "h2", name: "h2", executable: "echo", trusted: false, usageSource: .none, hookStyle: .none, mainArgs: [], workerArgs: ["{exe}", "{model}"], promptViaStdin: true)
        let m1 = ModelEntry(id: "m1", harness: "h1", name: "m1", intelligence: 60, isMain: false, isWorker: true, free: false) // broker
        let m2 = ModelEntry(id: "m2", harness: "h2", name: "m2", intelligence: 80, isMain: false, isWorker: true, free: true) // free worker
        let config = AppConfig(harnesses: [h1, h2], models: [m1, m2], mainOrder: [], limits: lim)
        
        let paths = HubPaths(root: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hub-\(UUID().uuidString)"))
        try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let project = paths.root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        
        var job = Job(project: project.path, objective: "obj", allowedFiles: ["main.swift"], checkArgv: ["sh", "test.sh"], size: .hard, kind: .implement, privacy: .project, created: Date())
        job.broker = "m1"
        try? "original code".write(to: project.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try "exit 0\n".write(to: project.appendingPathComponent("test.sh"), atomically: true, encoding: .utf8)
        for argv in [["git", "init", "-q"], ["git", "add", "-A"], ["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"]] {
            _ = Proc.run(argv, cwd: project.path)
        }
        
        let runner = Runner(paths: paths, config: config)
        runner.exec = { argv, cwd, env, stdin, timeout, pidCallback, onOutput in
            let dir = cwd ?? ""
            if argv.contains(where: { $0 == "m1" }) {
                let prompt = stdin ?? ""
                if prompt.contains("MASK step") {
                    let filesDir = URL(fileURLWithPath: dir).appendingPathComponent("files")
                    try? "generic brief".write(to: URL(fileURLWithPath: dir).appendingPathComponent("brief.md"), atomically: true, encoding: .utf8)
                    try? "{\"placeholders\":{\"P1\":\"orig\"},\"files\":{\"main.swift\":\"main.swift\"}}".write(to: URL(fileURLWithPath: dir).appendingPathComponent("map.json"), atomically: true, encoding: .utf8)
                    try? "[\"sh\",\"check.sh\"]".write(to: URL(fileURLWithPath: dir).appendingPathComponent("check.json"), atomically: true, encoding: .utf8)
                    try? "masked code".write(to: filesDir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
                    return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "mask ok")
                } else if prompt.contains("DECODE step") {
                    // Decode helper exits nonzero (failed)
                    return CheckResult(argv: argv, exitCode: 1, timedOut: false, output: "decode error")
                }
            } else if argv.contains(where: { $0 == "m2" }) {
                return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "worker ok")
            } else if argv.last == "check.sh" {
                return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "check ok")
            } else if argv == ["sh", "test.sh"] {
                // acceptance check passes
                return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "acceptance ok")
            }
            return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "ok")
        }
        
        let finalJob = runner.start(job, worker: m2, now: Date())
        #expect(finalJob.state == .needsReview)
        #expect(finalJob.note == "decode helper failed")
        #expect(finalJob.gate != nil)
    }

    @Test
    func testGateResultPassedForKind() {
        let okCheck = CheckResult(argv: ["sh", "check.sh"], exitCode: 0, timedOut: false, output: "ok")
        
        // review with exit 0, no changes, no outside files -> true
        let reviewNoChanges = GateResult(acceptance: okCheck, changedFiles: [], outsideAllowed: [])
        #expect(reviewNoChanges.passed(for: .review) == true)
        
        // review with outside files -> false
        let reviewOutsideFiles = GateResult(acceptance: okCheck, changedFiles: [], outsideAllowed: ["other.swift"])
        #expect(reviewOutsideFiles.passed(for: .review) == false)
        
        // implement with no changes -> false
        let implementNoChanges = GateResult(acceptance: okCheck, changedFiles: [], outsideAllowed: [])
        #expect(implementNoChanges.passed(for: .implement) == false)
        
        // implement with changes -> true
        let implementWithChanges = GateResult(acceptance: okCheck, changedFiles: ["main.swift"], outsideAllowed: [])
        #expect(implementWithChanges.passed(for: .implement) == true)
    }

    @Test
    func testTimeoutArgumentPropagation() throws {
        let paths = createTempPaths()
        let project = createTempProject()

        var config = ConfigStore.defaults()
        config.harnesses.append(Harness(id: "timeout-test", name: "T", executable: "echo", trusted: true, usageSource: .none, hookStyle: .none, mainArgs: [], workerArgs: ["{exe}", "{timeout}s"]))
        let runner = Runner(paths: paths, config: config)
        let worker = ModelEntry(id: "m", harness: "timeout-test", name: "m", intelligence: 50, isMain: false, isWorker: true)

        let job = Job(project: project, objective: "obj", allowedFiles: ["a.txt"], checkArgv: ["echo"], size: .tiny, kind: .implement, privacy: .project, created: Date())
        let store = JobStore(paths: paths)
        try! store.enqueue(job)

        var executedArgv: [String] = []
        runner.exec = { argv, cwd, env, stdin, timeout, onStart, onOutput in
            executedArgv = argv
            return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "done")
        }

        _ = runner.start(store.active().first!, worker: worker, now: Date())
        #expect(executedArgv == ["echo", "\(Int(config.limits.jobTimeoutSeconds))s"])
    }

    @Test
    func testWorkerFailureVerdict() throws {
        let paths = createTempPaths()
        let project = createTempProject()

        let runner = Runner(paths: paths, config: ConfigStore.defaults())
        let worker = ModelEntry(id: "gpt-6.1-sol", harness: "codex", name: "GPT", intelligence: 97, isMain: true, isWorker: true)
        let job = Job(project: project, objective: "t", allowedFiles: ["a.txt"], checkArgv: ["echo"], size: .tiny, kind: .implement, privacy: .project, created: Date())
        let store = JobStore(paths: paths)
        try! store.enqueue(job)

        runner.exec = { argv, cwd, env, stdin, timeout, onStart, onOutput in
            if argv == ["echo"] {
                return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "ok")
            }
            // Worker exits 1 (failure)
            return CheckResult(argv: argv, exitCode: 1, timedOut: false, output: "compile error")
        }

        let res = runner.start(store.active().first!, worker: worker, now: Date())
        #expect(res.state == .needsReview)
        #expect(res.note == "worker failed (nonzero exit)")
    }

    @Test
    func testAntigravityTemplates() throws {
        let paths = createTempPaths()
        let project = createTempProject()
        var config = ConfigStore.defaults()
        config.limits.jobTimeoutSeconds = 42.5

        let harnessIndex = config.harnesses.firstIndex { $0.id == "antigravity" }!
        let timeoutIndex = config.harnesses[harnessIndex].workerArgs.firstIndex(of: "--print-timeout")! + 1
        config.harnesses[harnessIndex].workerArgs[timeoutIndex] = "600s"
        let legacyHarness = config.harness("antigravity")!
        var customHarness = legacyHarness
        customHarness.workerArgs = ["{exe}", "--model", "{model}", "--dangerously-skip-permissions", "--print-timeout", "300s", "-p", "{prompt}"] // Different from exact legacy match

        let runner = Runner(paths: paths, config: config)
        let workerLeg = ModelEntry(id: "leg", harness: "antigravity", name: "leg", intelligence: 50, isMain: false, isWorker: true)
        let workerCus = ModelEntry(id: "cus", harness: "antigravity", name: "cus", intelligence: 50, isMain: false, isWorker: true)

        let job1 = Job(project: project, objective: "t1", allowedFiles: ["a.txt"], checkArgv: ["echo"], size: .tiny, kind: .implement, privacy: .project, created: Date())
        let job2 = Job(project: project, objective: "t2", allowedFiles: ["a.txt"], checkArgv: ["echo"], size: .tiny, kind: .implement, privacy: .project, created: Date())
        let store = JobStore(paths: paths)
        try! store.enqueue(job1)
        try! store.enqueue(job2)

        var executedArgv: [String] = []
        runner.exec = { argv, _, _, _, _, _, _ in
            executedArgv = argv
            return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "done")
        }

        _ = runner.start(job1, worker: workerLeg, now: Date())
        #expect(executedArgv.contains("42.5s"))
        #expect(!executedArgv.contains("600s"))

        config.harnesses[harnessIndex] = customHarness
        runner.config = config
        _ = runner.start(job2, worker: workerCus, now: Date())
        #expect(executedArgv.contains("300s"))
        #expect(!executedArgv.contains("42.5s"))
    }

    @Test
    func testAgyTimeoutVsNonzero() throws {
        let paths = createTempPaths()
        let project = createTempProject()
        let config = ConfigStore.defaults()
        let runner = Runner(paths: paths, config: config)
        let worker = config.model("gemini-3.1-pro-high")!
        let job1 = Job(project: project, objective: "t1", allowedFiles: ["a.txt"], checkArgv: ["echo"], size: .tiny, kind: .implement, privacy: .project, created: Date())
        let job2 = Job(project: project, objective: "t2", allowedFiles: ["a.txt"], checkArgv: ["echo"], size: .tiny, kind: .implement, privacy: .project, created: Date())
        let store = JobStore(paths: paths)
        try! store.enqueue(job1)
        try! store.enqueue(job2)

        // Zero-exit agy print timeout
        runner.exec = { _, _, _, _, _, _, _ in
            return CheckResult(argv: [], exitCode: 0, timedOut: false, output: "[agy] print timeout reached")
        }
        let res1 = runner.start(job1, worker: worker, now: Date())
        #expect(res1.state == .needsReview)
        #expect(res1.note == "worker failed (timeout)")

        // Real nonzero failure
        runner.exec = { _, _, _, _, _, _, _ in
            return CheckResult(argv: [], exitCode: 1, timedOut: false, output: "syntax error")
        }
        let res2 = runner.start(job2, worker: worker, now: Date())
        #expect(res2.state == .needsReview)
        #expect(res2.note == "worker failed (nonzero exit)")
    }

    // Swift Testing doesn't have expectation. We can just wait for it.
    private func expectation(description: String) -> Expectation {
        return Expectation()
    }
    class Expectation {
        var isFulfilled = false
        func fulfill() { isFulfilled = true }
    }

    @Test
    func testStaleCallerRetryPreservesBaselineAndPreQuotaViolations() throws {
        let paths = createTempPaths()
        let project = createTempProject()
        var config = ConfigStore.defaults()
        config.harnesses.append(Harness(id: "custom", name: "Custom", executable: "c", accounts: ["acc1"], trusted: true, usageSource: .none, hookStyle: .none, mainArgs: [], workerArgs: []))
        let runner = Runner(paths: paths, config: config)
        let worker = ModelEntry(id: "custom-model", harness: "custom", name: "Custom", intelligence: 50, isMain: false, isWorker: true)
        let job = Job(project: project, objective: "t", allowedFiles: ["allowed.txt"], checkArgv: ["echo", "ok"], size: .tiny, kind: .implement, privacy: .project, created: Date())
        let store = JobStore(paths: paths)
        try store.enqueue(job)
        let staleCallerJob = store.active().first!

        var callCount = 0
        runner.exec = { argv, cwd, env, stdin, timeout, onStart, onOutput in
            callCount += 1
            if callCount == 1 {
                try! "content".write(to: URL(fileURLWithPath: cwd!).appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
                return CheckResult(argv: argv, exitCode: 1, timedOut: false, output: "429 rate limit exceeded resets in 1h")
            }
            return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "done")
        }

        let now = Date()
        let first = runner.start(staleCallerJob, worker: worker, now: now)
        #expect(first.state == .queued)
        #expect(first.baseline != nil)

        Cooldowns.set("account:acc1", until: now.addingTimeInterval(-10), paths: paths)

        let final = runner.start(staleCallerJob, worker: worker, now: now)

        #expect(final.state == .needsReview)
        #expect(final.gate?.outsideAllowed == ["outside.txt"])
    }

    @Test
    func testRetryReusesWorktreeAfterExternalProjectLockIsReleased() throws {
        let paths = createTempPaths()
        let project = createTempProject()

        var config = ConfigStore.defaults()
        let harness = Harness(id: "custom", name: "Custom", executable: "c", accounts: ["acc1"], trusted: true, usageSource: .none, hookStyle: .none, mainArgs: [], workerArgs: [])
        config.harnesses.append(harness)
        let runner = Runner(paths: paths, config: config)
        let worker = ModelEntry(id: "custom-model", harness: "custom", name: "Custom", intelligence: 50, isMain: false, isWorker: true)

        let job = Job(project: project, objective: "t", allowedFiles: ["a.txt"], checkArgv: ["echo"], size: .tiny, kind: .implement, privacy: .project, isolation: .worktree, created: Date())
        let store = JobStore(paths: paths)
        try store.enqueue(job)

        let stdProject = URL(fileURLWithPath: project).resolvingSymlinksInPath().standardized.path
        let sha256 = SHA256.hash(data: Data(stdProject.utf8)).map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: paths.locks, withIntermediateDirectories: true)
        let lockPath = paths.locks.appendingPathComponent("\(sha256).lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        flock(fd, LOCK_EX)

        runner.exec = { argv, cwd, env, stdin, timeout, onStart, onOutput in
            return CheckResult(argv: argv, exitCode: 1, timedOut: false, output: "429 rate limit exceeded resets in 1h")
        }

        let now = Date()
        let res1 = runner.start(store.active().first!, worker: worker, now: now)
        #expect(res1.state == .queued)
        #expect(res1.worktree != nil)
        let worktreeDir = res1.worktree!

        flock(fd, LOCK_UN); close(fd)

        Cooldowns.set("account:acc1", until: now.addingTimeInterval(-10), paths: paths)
        Cooldowns.set("harness:custom", until: now.addingTimeInterval(-10), paths: paths)

        runner.exec = { argv, cwd, env, stdin, timeout, onStart, onOutput in
            let url = URL(fileURLWithPath: cwd!).appendingPathComponent("a.txt")
            try! "content".write(to: url, atomically: true, encoding: .utf8)
            return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "done")
        }

        let res2 = runner.start(store.active().first!, worker: worker, now: now)
        #expect(res2.state == .verified)
        #expect(res2.worktree == worktreeDir)
    }

    @Test
    func testAliasedSameProjectCannotBothRunCheckoutWorkers() throws {
        let paths = createTempPaths()
        let project = createTempProject()
        let aliasedProject = paths.root.appendingPathComponent("alias-project").path
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: aliasedProject, withDestinationPath: project)

        var config = ConfigStore.defaults()
        let runner = Runner(paths: paths, config: config)
        let worker = ModelEntry(id: "gpt-6.1-sol", harness: "codex", name: "GPT-6.1 Sol", intelligence: 97, isMain: true, isWorker: true, effort: "xhigh")

        let stdProject = URL(fileURLWithPath: aliasedProject).resolvingSymlinksInPath().standardized.path
        let sha256 = SHA256.hash(data: Data(stdProject.utf8)).map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: paths.locks, withIntermediateDirectories: true)
        let lockPath = paths.locks.appendingPathComponent("\(sha256).lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN); close(fd) }

        let job = Job(project: aliasedProject, objective: "t", allowedFiles: ["a.txt"], checkArgv: ["echo"], size: .tiny, kind: .implement, privacy: .project, isolation: .checkout, created: Date())
        let store = JobStore(paths: paths)
        try store.enqueue(job)

        runner.exec = { argv, cwd, env, stdin, timeout, onStart, onOutput in
            return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "done")
        }

        let res = runner.start(store.active().first!, worker: worker, now: Date())
        #expect(res.state == .queued)
    }

    @Test
    func testStaleMaskedPlanCannotOverwriteOffloadFalse() throws {
        let paths = createTempPaths()
        let project = createTempProject()

        let untrustedHarness = Harness(id: "untrusted", name: "Untrusted", executable: "echo", trusted: false, usageSource: .none, hookStyle: .none, mainArgs: [], workerArgs: ["{exe}", "{model}"], promptViaStdin: true)
        let trustedHarness = Harness(id: "trusted", name: "Trusted", executable: "echo", trusted: true, usageSource: .none, hookStyle: .none, mainArgs: [], workerArgs: ["{exe}", "{model}"], promptViaStdin: true)
        let untrustedWorker = ModelEntry(id: "untrusted-worker", harness: "untrusted", name: "Untrusted Worker", intelligence: 50, isMain: false, isWorker: true)
        let trustedWorker = ModelEntry(id: "trusted-worker", harness: "trusted", name: "Trusted Worker", intelligence: 50, isMain: false, isWorker: true)

        var config = ConfigStore.defaults()
        config.harnesses = [untrustedHarness, trustedHarness]
        config.models = [untrustedWorker, trustedWorker]
        let runner = Runner(paths: paths, config: config)

        let job = Job(project: project, objective: "t", allowedFiles: ["a.txt"], checkArgv: ["echo"], size: .tiny, kind: .implement, privacy: .project, created: Date())
        let store = JobStore(paths: paths)
        try store.enqueue(job)
        let originalJob = store.active().first!

        var failedMaskedJob = originalJob
        failedMaskedJob.state = .queued
        failedMaskedJob.offload = false
        failedMaskedJob.note = "masked fallback"
        try store.save(failedMaskedJob)

        var staleJob = originalJob
        staleJob.offload = true
        staleJob.broker = "trusted-worker"

        let res = runner.start(staleJob, worker: untrustedWorker, now: Date())

        #expect(res.state == .queued)
        #expect(res.offload == false)
        #expect(res.note == "masked fallback")
    }
}
