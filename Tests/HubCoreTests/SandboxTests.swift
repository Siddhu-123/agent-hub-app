import Testing
import Foundation
@testable import HubCore

@Suite("Sandbox Tests")
struct SandboxTests {
    @Test func testSandboxAvailabilityAndRules() {
        #expect(Sandbox.available() == true)
        
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let testFile = tempDir.appendingPathComponent("secret.txt")
        try? "secret".write(to: testFile, atomically: true, encoding: .utf8)
        
        let readArgv = Sandbox.wrap(["/bin/sh", "-c", "cat \(testFile.path)"])
        let readRes = Proc.run(readArgv)
        #expect(!readRes.passed)
        
        let stageDir = URL(fileURLWithPath: "/private/tmp/agenthub-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
        
        let writeArgv = Sandbox.wrap(["/bin/sh", "-c", "echo hello > \(stageDir.path)/out.txt"])
        let writeRes = Proc.run(writeArgv)
        #expect(writeRes.passed)
    }
    
    @Test func testPrepareAndCollect() throws {
        let runDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        let f1 = runDir.appendingPathComponent("a/b/c.swift")
        try FileManager.default.createDirectory(at: f1.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "c".write(to: f1, atomically: true, encoding: .utf8)
        
        let f2 = runDir.appendingPathComponent("d.swift")
        try "d".write(to: f2, atomically: true, encoding: .utf8)
        
        var job = Job(project: runDir.path, objective: "test", allowedFiles: ["a/b/c.swift", "d.swift"], checkArgv: ["true"], size: .tiny, kind: .implement, privacy: .generic, created: Date())
        let stage = try Sandbox.prepare(job: job, runDir: runDir.path, baseEnv: ["FOO": "BAR"])
        
        #expect(stage.names == ["c.swift": "a/b/c.swift", "d.swift": "d.swift"])
        
        let stagedC = stage.dir.appendingPathComponent("c.swift").path
        let stagedD = stage.dir.appendingPathComponent("d.swift").path
        #expect(FileManager.default.fileExists(atPath: stagedC))
        #expect(FileManager.default.fileExists(atPath: stagedD))
        
        #expect(stage.env["PWD"] == stage.dir.path)
        #expect(stage.env["XDG_CONFIG_HOME"] == stage.work.appendingPathComponent("config").path)
        
        let configStr = stage.env["OPENCODE_CONFIG_CONTENT"]!
        let configData = configStr.data(using: .utf8)!
        let configDict = try JSONSerialization.jsonObject(with: configData, options: []) as! [String: Any]
        let perm = configDict["permission"] as! [String: Any]
        let edit = perm["edit"] as! [String: Any]
        #expect(perm["bash"] as? String == "ask")
        #expect(edit["c.swift"] as? String == "allow")
        // OpenCode's last matching rule wins, so the "*" fallback must come before every per-file allow in the raw JSON.
        for section in ["\"read\":{", "\"edit\":{"] {
            let body = configStr.components(separatedBy: section)[1]
            #expect(body.hasPrefix("\"*\":\"ask\""))
        }
        job.allowedFiles = ["!x.swift"]
        #expect(throws: HubError.self) { try Sandbox.prepare(job: job, runDir: runDir.path, baseEnv: [:]) }
        job.allowedFiles = ["a/b/c.swift", "d.swift"]
        
        // reject duplicate basenames
        job.allowedFiles = ["a/x.swift", "b/x.swift"]
        #expect(throws: HubError.self) { try Sandbox.prepare(job: job, runDir: runDir.path, baseEnv: [:]) }
        
        // reject glob
        job.allowedFiles = ["*.swift"]
        #expect(throws: HubError.self) { try Sandbox.prepare(job: job, runDir: runDir.path, baseEnv: [:]) }
        
        // collect
        try "new c".write(toFile: stagedC, atomically: true, encoding: .utf8)
        
        // extra file should be ignored
        try "extra".write(toFile: stage.dir.appendingPathComponent("extra.txt").path, atomically: true, encoding: .utf8)
        // staged symlink should be ignored
        try? FileManager.default.removeItem(atPath: stage.dir.appendingPathComponent("d.swift").path)
        try FileManager.default.createSymbolicLink(atPath: stage.dir.appendingPathComponent("d.swift").path, withDestinationPath: "/etc/passwd")
        
        let collected = try Sandbox.collect(stage, into: runDir.path)
        #expect(collected == ["a/b/c.swift"]) // d.swift is symlink so ignored
        #expect(try String(contentsOf: f1) == "new c")
        #expect(!FileManager.default.fileExists(atPath: runDir.appendingPathComponent("extra.txt").path))
        
        Sandbox.cleanup(stage)
        #expect(!FileManager.default.fileExists(atPath: stage.work.path))
    }
    
    @Test func testRunnerUntrustedHarness() throws {
        let paths = HubPaths(root: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString))
        var config = AppConfig(harnesses: [], models: [], mainOrder: [])
        var h = Harness(id: "untrusted", name: "untrusted", executable: "fake", accounts: [], trusted: false, usageSource: .none, hookStyle: .none, mainArgs: [], workerArgs: ["{exe}", "{project}"], promptViaStdin: false)
        config.harnesses.append(h)
        let runner = Runner(paths: paths, config: config)
        
        let runDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        
        _ = Proc.run(["git", "init"], cwd: runDir.path)
        
        let job = Job(project: runDir.path, objective: "test", allowedFiles: ["c.swift"], checkArgv: ["true"], size: .tiny, kind: .implement, privacy: .generic, created: Date())
        let qjob = try JobStore(paths: paths).enqueue(job)
        
        var calledArgv: [String] = []
        var calledCwd: String? = nil

        runner.exec = { (argv: [String], cwd: String?, env: [String: String]?, stdin: String?, timeout: TimeInterval, cb: @escaping (Int32) -> Void, _: @escaping (Data) -> Void) -> CheckResult in
            calledArgv = argv
            calledCwd = cwd
            
            // write the allowed basename in cwd
            if let c = cwd {
                try? "mod".write(toFile: URL(fileURLWithPath: c).appendingPathComponent("c.swift").path, atomically: true, encoding: .utf8)
            }
            return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "")
        }
        
        let worker = ModelEntry(id: "m", harness: "untrusted", name: "m", intelligence: 100, isMain: true, isWorker: true, free: true, effort: nil, enabled: true)
        let finalJob = runner.start(qjob, worker: worker, now: Date())
        #expect(finalJob.state == JobState.verified)

        #expect(calledArgv.first == Sandbox.exe)
        #expect(calledArgv.contains("fake") == true)
        #expect(calledCwd?.hasPrefix("/private/tmp/agenthub-") == true)
        
        let cPath = runDir.appendingPathComponent("c.swift").path
        #expect(try String(contentsOfFile: cPath) == "mod")
        
        // project privacy job should fail
        let pJob = Job(project: runDir.path, objective: "test", allowedFiles: ["c.swift"], checkArgv: ["true"], size: .tiny, kind: .implement, privacy: .project, created: Date())
        let pqjob = try JobStore(paths: paths).enqueue(pJob)
        let finalPJob = runner.start(pqjob, worker: worker, now: Date())
        #expect(finalPJob.state == JobState.failed)
        #expect(finalPJob.note?.contains("untrusted harness only runs generic jobs") == true)
    }
    
    @Test func testEnqueuePrivacy() throws {
        let paths = HubPaths(root: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString))
        let store = JobStore(paths: paths)
        let runDir = NSTemporaryDirectory()
        
        let j1 = Job(project: runDir, objective: "do /Users/x", allowedFiles: ["x"], checkArgv: ["true"], size: .tiny, kind: .implement, privacy: .generic, created: Date())
        #expect(throws: HubError.self) { try store.enqueue(j1) }
        
        let j2 = Job(project: runDir, objective: "contact test@example.com", allowedFiles: ["x"], checkArgv: ["true"], size: .tiny, kind: .implement, privacy: .generic, created: Date())
        #expect(throws: HubError.self) { try store.enqueue(j2) }
        
        let j3 = Job(project: runDir, objective: "do /Users/x", allowedFiles: ["x"], checkArgv: ["true"], size: .tiny, kind: .implement, privacy: .project, created: Date())
        let s = try store.enqueue(j3)
        #expect(s.state == JobState.queued)
    }
    
    @Test func testSandboxScrubbed() {
        let inputEnv: [String: String] = [
            "SAFE_VAR": "value1",
            "PATH": "/usr/bin:/bin",
            "USER_TOKEN": "secret1",
            "my_token_var": "secret2",
            "CLIENT_SECRET": "secret3",
            "USER_PASSWORD": "secret4",
            "DB_PASSWD": "secret5",
            "APP_CREDENTIAL": "secret6",
            "API_KEY": "secret7",
            "SERVICE_APIKEY": "secret8",
            "MY_PRIVATE_KEY": "secret9",
            "USER_ACCESS_KEY": "secret10",
            "CURRENT_SESSION_KEY": "secret11",
            "SIGNING_KEY": "secret12",
            "AWS_REGION": "us-east-1",
            "GH_TOKEN": "ghp_123",
            "GITHUB_ACTIONS": "true",
            "ANTHROPIC_API_KEY": "sk-ant-123",
            "OPENAI_BASE_URL": "https://api.openai.com",
            "GEMINI_MODEL": "gemini-pro",
            "GOOGLE_API_PROJECT": "project-123"
        ]
        
        let scrubbed = Sandbox.scrubbed(inputEnv)
        #expect(scrubbed["SAFE_VAR"] == "value1")
        #expect(scrubbed["PATH"] == "/usr/bin:/bin")
        #expect(scrubbed.count == 2)
        #expect(scrubbed["USER_TOKEN"] == nil)
        #expect(scrubbed["my_token_var"] == nil)
        #expect(scrubbed["CLIENT_SECRET"] == nil)
        #expect(scrubbed["USER_PASSWORD"] == nil)
        #expect(scrubbed["DB_PASSWD"] == nil)
        #expect(scrubbed["APP_CREDENTIAL"] == nil)
        #expect(scrubbed["API_KEY"] == nil)
        #expect(scrubbed["SERVICE_APIKEY"] == nil)
        #expect(scrubbed["MY_PRIVATE_KEY"] == nil)
        #expect(scrubbed["USER_ACCESS_KEY"] == nil)
        #expect(scrubbed["CURRENT_SESSION_KEY"] == nil)
        #expect(scrubbed["SIGNING_KEY"] == nil)
        #expect(scrubbed["AWS_REGION"] == nil)
        #expect(scrubbed["GH_TOKEN"] == nil)
        #expect(scrubbed["GITHUB_ACTIONS"] == nil)
        #expect(scrubbed["ANTHROPIC_API_KEY"] == nil)
        #expect(scrubbed["OPENAI_BASE_URL"] == nil)
        #expect(scrubbed["GEMINI_MODEL"] == nil)
        #expect(scrubbed["GOOGLE_API_PROJECT"] == nil)
    }
    
    @Test func testCollectSymlinkContainment() throws {
        let runDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let outsideDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: runDir)
            try? FileManager.default.removeItem(at: outsideDir)
        }
        
        let outsideFile = outsideDir.appendingPathComponent("config.txt")
        try "original outside".write(to: outsideFile, atomically: true, encoding: .utf8)
        
        // Create symlink 'linked' -> outsideDir inside runDir
        let symlinkPath = runDir.appendingPathComponent("linked").path
        try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: outsideDir.path)
        
        // Prepare stage with allowed file 'linked/config.txt'
        let stageWork = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let stageDir = stageWork.appendingPathComponent("stage")
        try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stageWork) }
        
        let stagedConfig = stageDir.appendingPathComponent("config.txt")
        try "malicious overwrite".write(to: stagedConfig, atomically: true, encoding: .utf8)
        
        let stage = Sandbox.Stage(
            work: stageWork,
            dir: stageDir,
            env: [:],
            names: ["config.txt": "linked/config.txt"]
        )
        
        let collected = try Sandbox.collect(stage, into: runDir.path)
        #expect(collected.isEmpty)
        #expect(try String(contentsOf: outsideFile) == "original outside")
    }
}
