import Foundation
import Testing
@testable import HubCore

struct DelegateWaitTests {
    private func createTempPaths() -> HubPaths {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return HubPaths(root: temp)
    }

    private func createTempProject() -> String {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try! FileManager.default.createDirectory(atPath: temp, withIntermediateDirectories: true)
        _ = Proc.run(["git", "init", "-q"], cwd: temp)
        _ = Proc.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "init"], cwd: temp)
        return temp
    }

    private func createFakeWorkerScript() -> String {
        let scriptPath = FileManager.default.temporaryDirectory.appendingPathComponent("fake-worker-\(UUID().uuidString).sh").path
        let script = """
        #!/bin/sh
        if [ -n "$AGENT_HUB_FAKE_MARKER" ]; then
            /usr/bin/touch "$AGENT_HUB_FAKE_MARKER"
        fi
        # Fake worker executable
        for arg in "$@"; do
            if [ "$arg" = "fail" ]; then
                exit 1
            fi
        done
        exit 0
        """
        try! script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        chmod(scriptPath, 0o755)
        return scriptPath
    }

    @Test
    func testDelegateWaitWhenAnotherOwnerClaimsAndCompletesJob() throws {
        let paths = createTempPaths()
        let project = createTempProject()
        defer {
            try? FileManager.default.removeItem(at: paths.root)
            try? FileManager.default.removeItem(atPath: project)
        }

        let fakeWorker = createFakeWorkerScript()
        defer { try? FileManager.default.removeItem(atPath: fakeWorker) }

        // Configure environment with fake worker
        let config = AppConfig(
            harnesses: [
                Harness(id: "fake-harness", name: "Fake Harness", executable: fakeWorker, accounts: [], trusted: true, usageSource: .none, hookStyle: .none, mainArgs: ["{prompt}"], workerArgs: ["{exe}", "{prompt}"])
            ],
            models: [
                ModelEntry(id: "fake-model", harness: "fake-harness", name: "Fake Model", intelligence: 90, isMain: true, isWorker: true)
            ],
            mainOrder: ["fake-model"]
        )
        try ConfigStore.save(config, paths)

        // The CLI enqueues before logging. Hold that log lock until the other owner
        // has claimed the job, so this test always exercises the wait path.
        try FileManager.default.createDirectory(at: paths.locks, withIntermediateDirectories: true)
        let activityFd = open(paths.locks.appendingPathComponent("activity.lock").path, O_CREAT | O_RDWR, 0o600)
        #expect(activityFd >= 0)
        flock(activityFd, LOCK_EX)
        defer { flock(activityFd, LOCK_UN); close(activityFd) }

        let executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/agenthubctl").path
        #expect(FileManager.default.isExecutableFile(atPath: executable))

        let store = JobStore(paths: paths)

        // Spin up a concurrent owner thread that watches the store for a queued job,
        // transitions it to running (simulating the app starting Runner.start),
        // and after a brief pause completes it to verified.
        let group = DispatchGroup()
        group.enter()

        let simulatedAllowedFile = URL(fileURLWithPath: project).appendingPathComponent("allowed.txt")

        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            let deadline = Date().addingTimeInterval(5)
            var claimedJobId: String?
            while Date() < deadline {
                if let queued = store.all().first(where: { $0.state == .queued }) {
                    claimedJobId = queued.id
                    var runningJob = queued
                    runningJob.state = .running
                    runningJob.started = Date()
                    runningJob.harness = "fake-harness"
                    runningJob.model = "fake-model"
                    try! store.save(runningJob)
                    flock(activityFd, LOCK_UN)
                    break
                }
                Thread.sleep(forTimeInterval: 0.02)
            }

            guard let jid = claimedJobId else { return }

            // Hold job in running state so delegate --wait sees running
            Thread.sleep(forTimeInterval: 0.2)

            // Make the allowed file modification and complete the job to verified
            try! "hello world".write(to: simulatedAllowedFile, atomically: true, encoding: .utf8)

            if var j = store.get(jid) {
                j.state = .verified
                j.finished = Date()
                j.gate = GateResult(
                    acceptance: CheckResult(argv: ["test"], exitCode: 0, timedOut: false, output: "ok"),
                    changedFiles: ["allowed.txt"],
                    outsideAllowed: []
                )
                try! store.save(j)
            }
        }

        let env: [String: String] = [
            "AGENT_HUB_HOME": paths.root.path,
            "AGENT_HUB_TEST": "1",
            "AGENT_HUB_FAKE_MARKER": paths.root.appendingPathComponent("unexpected-worker").path,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        ]

        let res = Proc.run([
            executable, "delegate",
            "--main", "fake-model",
            "--project", project,
            "--objective", "Test concurrent claim wait",
            "--allowed-file", "allowed.txt",
            "--check", "[\"echo\",\"ok\"]",
            "--wait"
        ], env: env, timeout: 10)

        group.wait()

        #expect(res.exitCode == 0)
        #expect(!FileManager.default.fileExists(atPath: env["AGENT_HUB_FAKE_MARKER"]!))
        let receiptData = res.output.data(using: .utf8) ?? Data()
        let receipt = (try? JSONSerialization.jsonObject(with: receiptData)) as? [String: Any]
        #expect(receipt?["state"] as? String == "verified")
    }

    @Test
    func testDelegateWaitPreservesExit3ForNoCapacity() throws {
        let paths = createTempPaths()
        let project = createTempProject()
        defer {
            try? FileManager.default.removeItem(at: paths.root)
            try? FileManager.default.removeItem(atPath: project)
        }

        // Config with NO models enabled or available
        let config = AppConfig(harnesses: [], models: [], mainOrder: [])
        try ConfigStore.save(config, paths)

        let executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/agenthubctl").path

        let env: [String: String] = [
            "AGENT_HUB_HOME": paths.root.path,
            "AGENT_HUB_TEST": "1",
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        ]

        let res = Proc.run([
            executable, "delegate",
            "--main", "unknown-model",
            "--project", project,
            "--objective", "Test no capacity exit 3",
            "--allowed-file", "file.txt",
            "--check", "[\"echo\",\"ok\"]",
            "--wait"
        ], env: env, timeout: 5)

        #expect(res.exitCode == 3)
        let receiptData = res.output.data(using: .utf8) ?? Data()
        let receipt = (try? JSONSerialization.jsonObject(with: receiptData)) as? [String: Any]
        #expect(receipt?["state"] as? String == "queued")
    }
}
