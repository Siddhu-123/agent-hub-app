import Testing
import Foundation
@testable import HubCore
import CryptoKit

@Suite("Engine Tests")
@MainActor
struct EngineTests {
    
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
    func testEngine() async throws {
        let paths = createTempPaths()
        let project = createTempProject()
        
        // 1. Setup fakes and engine
        var openScriptUrls: [URL] = []
        let openScript: @Sendable (URL) -> Bool = { url in
            openScriptUrls.append(url)
            return true
        }
        
        let exec: Runner.Exec = { argv, cwd, env, stdin, timeout, onStart, onOutput in
            let cwdStr = cwd ?? project
            let allowedFile = URL(fileURLWithPath: cwdStr).appendingPathComponent("file.txt")
            try? "dummy".write(to: allowedFile, atomically: true, encoding: .utf8)
            return CheckResult(argv: argv, exitCode: 0, timedOut: false, output: "done")
        }
        
        let engine = Engine(paths: paths, ctlPath: "/bin/ctl", exec: exec, openScript: openScript)
        
        let config = AppConfig(
            harnesses: [
                Harness(id: "h1", name: "H1", executable: "exe", accounts: [], trusted: true, usageSource: .none, hookStyle: .none, mainArgs: ["{prompt}"], workerArgs: ["{prompt}"])
            ],
            models: [
                ModelEntry(id: "m1", harness: "h1", name: "M1", intelligence: 100, isMain: true, isWorker: true)
            ],
            mainOrder: ["m1"]
        )
        try engine.saveConfig(config)
        
        // 2. tick writes engine.json with a "heartbeat" key
        engine.tick()
        let engineJsonPath = paths.root.appendingPathComponent("engine.json")
        let data = try Data(contentsOf: engineJsonPath)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["heartbeat"] != nil)
        
        // 3. startMain with a valid model id launches via openScript fake and HandoffRecord appears after tick
        try engine.startMain(modelId: "m1", project: project)
        #expect(!openScriptUrls.isEmpty)
        #expect(engine.handoffs.count == 1)
        
        // 4. send writes an inbox message
        let rel = Relay(paths: paths, config: config, ctlPath: "/bin/ctl")
        let session = rel.touch("h1", "sid1", cwd: project, event: "start", model: "m1", pid: nil, now: Date())
        try engine.send(session: session, text: "hello", kind: .message)
        let pending = rel.pending("h1", "sid1")
        #expect(pending.count == 1)
        #expect(pending.first?.text == "hello")
        
        // 5. delegate then waiting results in verified job
        let job = Job(project: project, objective: "test", allowedFiles: ["file.txt"], checkArgv: ["echo", "ok"], size: .tiny, kind: .implement, privacy: .project, created: Date())
        let storedJob = try engine.delegate(job)
        
        let start = Date()
        var verified = false
        while Date().timeIntervalSince(start) < 5 {
            if let j = engine.jobs.first(where: { $0.id == storedJob.id }), j.state == .verified {
                verified = true
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(verified)
        #expect(engine.log.contains(where: { $0.contains("job verified:") }))
        
        // 6. rerun produces a new id with state queued or later and the same objective
        let rerunJob = try engine.rerun(jobId: storedJob.id)
        #expect(rerunJob.id != storedJob.id)
        #expect(rerunJob.objective == storedJob.objective)
        #expect(rerunJob.state == .queued || rerunJob.state == .running || rerunJob.state == .verified)
        
        // 7. cancel marks a queued job cancelled
        let job2 = Job(project: project, objective: "test2", allowedFiles: ["file.txt"], checkArgv: ["echo", "ok"], size: .tiny, kind: .implement, privacy: .project, created: Date())
        let storedJob2 = try engine.delegate(job2)
        engine.cancel(jobId: storedJob2.id)
        #expect(engine.jobs.first(where: { $0.id == storedJob2.id })?.state == .cancelled)
    }

    @Test
    func testStartMainUsesUUIDNotUnixTimestamp() async throws {
        let paths = createTempPaths()
        let project = createTempProject()

        var openScriptUrls: [URL] = []
        let openScript: @Sendable (URL) -> Bool = { url in
            openScriptUrls.append(url)
            return true
        }

        let engine = Engine(paths: paths, ctlPath: "/bin/ctl", openScript: openScript)

        let config = AppConfig(
            harnesses: [
                Harness(id: "h1", name: "H1", executable: "exe", accounts: [], trusted: true, usageSource: .none, hookStyle: .none, mainArgs: ["{prompt}"], workerArgs: ["{prompt}"])
            ],
            models: [
                ModelEntry(id: "m1", harness: "h1", name: "M1", intelligence: 100, isMain: true, isWorker: true)
            ],
            mainOrder: ["m1"]
        )
        try engine.saveConfig(config)

        // Call startMain twice in quick succession
        try engine.startMain(modelId: "m1", project: project)
        let filesAfterFirst = try FileManager.default.contentsOfDirectory(atPath: paths.handoffs.path)

        try engine.startMain(modelId: "m1", project: project)
        let filesAfterSecond = try FileManager.default.contentsOfDirectory(atPath: paths.handoffs.path)

        // Extract start file names
        let startFiles = filesAfterSecond.filter { $0.hasPrefix("start-") && $0.hasSuffix(".md") }
        #expect(startFiles.count >= 2, "Expected at least 2 start files, got \(startFiles.count)")

        // Verify the files have different names (UUIDs)
        if startFiles.count >= 2 {
            let names = Set(startFiles)
            #expect(names.count == startFiles.count, "Start file names should be unique; got duplicates in \(startFiles)")
        }
    }
}
