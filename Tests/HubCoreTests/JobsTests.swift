import Testing
import Foundation
@testable import HubCore
import CryptoKit

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
    
    // Polyfill for expectation since we're in Swift Testing
    // Swift Testing doesn't have expectation. We can just wait for it.
    private func expectation(description: String) -> Expectation {
        return Expectation()
    }
    class Expectation {
        var isFulfilled = false
        func fulfill() { isFulfilled = true }
    }
}
