import Testing
import Foundation
@testable import HubCore

final class Box<T: Sendable>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

@Suite struct RelayTests {
    let tmpDir: URL
    let paths: HubPaths
    let config: AppConfig
    
    init() {
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        paths = HubPaths(root: tmpDir)
        
        let claude = Harness(id: "claude", name: "Claude", executable: "claude", trusted: true, usageSource: .claudeStatusline, hookStyle: .claude, mainArgs: ["{exe}", "--model", "{model}", "{prompt}"], workerArgs: [])
        let codex = Harness(id: "codex", name: "Codex", executable: "codex", trusted: true, usageSource: .codexSessions, hookStyle: .codex, mainArgs: ["{exe}", "-C", "{project}", "-m", "{model}", "-c", "model_reasoning_effort={effort}", "{prompt}"], workerArgs: [], promptViaStdin: true, queueArgs: ["{exe}", "queue", "--thread", "{session}", "--message", "{text}"])
        
        let mClaude = ModelEntry(id: "claude-opus-5-5", harness: "claude", name: "Claude Opus", intelligence: 98, isMain: true, isWorker: false)
        let mCodex = ModelEntry(id: "gpt-6.1-sol", harness: "codex", name: "Codex Sol", intelligence: 97, isMain: true, isWorker: true, effort: "high")
        
        config = AppConfig(harnesses: [claude, codex], models: [mClaude, mCodex], mainOrder: ["claude-opus-5-5", "gpt-6.1-sol"])
    }
    
    @Test func hookRegistersSessionAndIgnoresWorkerEnv() {
        let relay = Relay(paths: paths, config: config, ctlPath: "ctl")
        let now = Date()
        
        // ignores worker env
        let out1 = relay.hook("claude", event: "UserPromptSubmit", payload: ["session_id": "sid1"], env: [HubPaths.workerEnv: "1"], now: now)
        #expect(out1 == nil)
        #expect(relay.sessions(activeOnly: true, now: now).isEmpty)
        
        // registers session
        let out2 = relay.hook("claude", event: "UserPromptSubmit", payload: ["session_id": "sid2"], env: [:], now: now)
        let s = relay.sessions(activeOnly: true, now: now)
        #expect(s.count == 1)
        #expect(s[0].sessionId == "sid2")
        #expect(s[0].status == .working)
    }
    
    @Test func sessionEndEndsIt() {
        let relay = Relay(paths: paths, config: config, ctlPath: "ctl")
        let now = Date()
        _ = relay.hook("claude", event: "SessionStart", payload: ["session_id": "sid1"], env: [:], now: now)
        
        let s1 = relay.sessions(activeOnly: false, now: now)
        #expect(s1.first?.status == .working)
        
        _ = relay.hook("claude", event: "SessionEnd", payload: ["session_id": "sid1"], env: [:], now: now)
        
        let s2 = relay.sessions(activeOnly: false, now: now)
        #expect(s2.first?.status == .ended)
    }
    
    @Test func messageDeliveredOnceAtUserPromptSubmitAndReassertedAtStop() {
        let relay = Relay(paths: paths, config: config, ctlPath: "ctl")
        let now = Date()
        
        _ = try? relay.send("claude", "sid1", "task 1", kind: .task, now: now)
        
        let out1 = relay.hook("claude", event: "UserPromptSubmit", payload: ["session_id": "sid1"], env: [:], now: now)
        if let o1 = out1, let hs = o1["hookSpecificOutput"] as? [String: Any], let text = hs["additionalContext"] as? String {
            #expect(text.contains("task 1"))
        } else {
            Issue.record("Failed to deliver message at UserPromptSubmit")
        }
        
        // Not repeated on later hooks
        let out2 = relay.hook("claude", event: "UserPromptSubmit", payload: ["session_id": "sid1"], env: [:], now: now)
        #expect(out2 == nil)
        
        // Re-asserted at Stop
        let out3 = relay.hook("claude", event: "Stop", payload: ["session_id": "sid1"], env: [:], now: now)
        if let o3 = out3, let dec = o3["decision"] as? String, let reason = o3["reason"] as? String {
            #expect(dec == "block")
            #expect(reason.contains("task 1"))
        } else {
            Issue.record("Failed to block Stop")
        }
        
        // Then done
        let out4 = relay.hook("claude", event: "Stop", payload: ["session_id": "sid1"], env: [:], now: now)
        #expect(out4 == nil) // message is done
    }
    
    @Test func wrapUpBlocksStopAndHandledCorrectly() {
        let usage: [String: UsageReading] = ["codex": UsageReading(left: 0.10, source: "codexSessions")]
        let relay = Relay(paths: paths, config: config, ctlPath: "ctl", usageProvider: { usage })
        let now = Date()
        
        // Start codex session and trigger wrap-up
        let out1 = relay.hook("codex", event: "UserPromptSubmit", payload: ["session_id": "sid1", "cwd": "/tmp"], env: [:], now: now)
        #expect(out1 != nil)
        
        let pMsgs1 = relay.pending("codex", "sid1")
        #expect(pMsgs1.count == 1)
        #expect(pMsgs1[0].kind == .wrapUp)
        #expect(pMsgs1[0].text.contains("Claude Opus"))
        #expect(pMsgs1[0].text.contains("ctl' handoff"))
        
        // Not repeated on later hooks
        let out2 = relay.hook("codex", event: "UserPromptSubmit", payload: ["session_id": "sid1"], env: [:], now: now)
        #expect(out2 == nil)
        
        // wrap_up blocks Stop at most maxStopBlocks times
        for _ in 0..<config.limits.maxStopBlocks {
            let outS = relay.hook("codex", event: "Stop", payload: ["session_id": "sid1"], env: [:], now: now)
            #expect(outS != nil)
        }
        
        // After maxStopBlocks, it doesn't block anymore
        let outSFinal = relay.hook("codex", event: "Stop", payload: ["session_id": "sid1"], env: [:], now: now)
        #expect(outSFinal == nil)
    }
    
    @Test func codexSendPushesQueueArgv() {
        let pushedArgv = Box<[String]?>(nil)
        let relay = Relay(paths: paths, config: config, ctlPath: "ctl", push: { argv in
            pushedArgv.value = argv
            return true
        })
        
        _ = try? relay.send("codex", "sid1", "hello", kind: .message, now: Date())
        #expect(pushedArgv.value == ["codex", "queue", "--thread", "sid1", "--message", "hello"])
    }
    
    @Test func secretsRejected() {
        let relay = Relay(paths: paths, config: config, ctlPath: "ctl")
        #expect(throws: HubError.secret) {
            _ = try relay.send("claude", "sid1", "bearer token: Bearer abcdefghijklmnopqrstuvwxyz", kind: .message, now: Date())
        }
    }
    
    @Test func handoffValidatesFileAndWritesLaunchScript() throws {
        let openedScript = Box<URL?>(nil)
        let relay = Relay(paths: paths, config: config, ctlPath: "ctl", openScript: { url in
            openedScript.value = url
            return true
        })
        
        let projectPath = tmpDir.appendingPathComponent("proj' with spaces")
        try FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)
        
        let handoffFile = projectPath.appendingPathComponent("handoff.md")
        try "handoff content".write(to: handoffFile, atomically: true, encoding: .utf8)
        
        // start session
        _ = relay.hook("claude", event: "SessionStart", payload: ["session_id": "sid1"], env: [:], now: Date())
        
        let record = try relay.handoff(from: "claude", session: "sid1", project: projectPath.path, file: handoffFile.path, to: "gpt-6.1-sol", launch: true, automatic: false, now: Date())
        
        #expect(openedScript.value != nil)
        #expect(record.toModel == "gpt-6.1-sol")
        
        // Check session marked handedOff
        let s = relay.sessions(activeOnly: false, now: Date()).first { $0.sessionId == "sid1" }
        #expect(s?.handedOff == true)
        
        // Validate script
        if let scriptUrl = openedScript.value {
            let scriptText = try String(contentsOf: scriptUrl, encoding: .utf8)
            #expect(scriptText.contains("cd '"))
            #expect(scriptText.contains("proj'\"'\"' with spaces'"))
            #expect(scriptText.contains("exec '") && scriptText.contains("codex' '-C' '")) // bare or resolved executable
            #expect(scriptText.contains("\"$(cat ")) // prompt is double quoted
            
            // Should pass zsh -n
            let res = Proc.run(["zsh", "-n", scriptUrl.path])
            #expect(res.passed)
        }
    }
    
    @Test func handoffNoCapacityThrows() {
        let usage: [String: UsageReading] = ["codex": UsageReading(left: 0.0, source: "codexSessions"),
                                             "claude": UsageReading(left: 0.0, source: "claudeStatusline")]
        let relay = Relay(paths: paths, config: config, ctlPath: "ctl", usageProvider: { usage })
        
        let projectPath = tmpDir.appendingPathComponent("proj2")
        try? FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)
        let handoffFile = projectPath.appendingPathComponent("handoff.md")
        try? "content".write(to: handoffFile, atomically: true, encoding: .utf8)
        
        #expect(throws: HubError.noCapacity("No other main model has capacity (codex: exhausted)")) {
            _ = try relay.handoff(from: "claude", session: "sid1", project: projectPath.path, file: handoffFile.path, to: nil, launch: true, automatic: false, now: Date())
        }
    }
    
    @Test func applyAutoHandoffWritesMarkdownAndInterrupts() throws {
        let interruptedPid = Box<Int32?>(nil)
        let relay = Relay(paths: paths, config: config, ctlPath: "ctl", openScript: { _ in true }, interrupt: { pid in
            interruptedPid.value = pid
        })
        let now = Date()
        
        let projectPath = tmpDir.appendingPathComponent("proj3")
        _ = try? FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)
        _ = Proc.run(["git", "init"], cwd: projectPath.path)
        _ = try? "test".write(to: projectPath.appendingPathComponent("test.txt"), atomically: true, encoding: .utf8)
        
        let s = relay.touch("claude", "sid1", cwd: projectPath.path, event: "UserPromptSubmit", model: nil, pid: 12345, now: now)
        
        let actions: [PolicyAction] = [.autoHandoff(session: s, target: config.model("gpt-6.1-sol")!)]
        _ = relay.apply(actions, now: now)
        
        #expect(interruptedPid.value == 12345)
        
        let handoffFile = paths.handoffs.appendingPathComponent("auto-\(FileStore.key("claude", "sid1")).md")
        let md = try String(contentsOf: handoffFile, encoding: .utf8)
        #expect(md.contains("Automatic handoff"))
        #expect(md.contains("## Git Status"))
    }
    
    @Test func hookNeverThrowsOnGarbagePayloads() {
        let relay = Relay(paths: paths, config: config, ctlPath: "ctl")
        let out = relay.hook("claude", event: "UserPromptSubmit", payload: ["garbage": true], env: [:], now: Date())
        #expect(out == nil)
    }

    @Test func handoffFailsIfOpenScriptFails() throws {
        let openScriptFailed = Box<Bool>(false)
        let relay = Relay(paths: paths, config: config, ctlPath: "ctl", openScript: { _ in
            openScriptFailed.value = true
            return false
        })

        let projectPath = tmpDir.appendingPathComponent("proj_openscript_fail")
        try FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)

        let handoffFile = projectPath.appendingPathComponent("handoff.md")
        try "handoff content".write(to: handoffFile, atomically: true, encoding: .utf8)

        // start session
        _ = relay.hook("claude", event: "SessionStart", payload: ["session_id": "sid_openscript"], env: [:], now: Date())

        #expect(throws: HubError.self) {
            _ = try relay.handoff(from: "claude", session: "sid_openscript", project: projectPath.path, file: handoffFile.path, to: "gpt-6.1-sol", launch: true, automatic: false, now: Date())
        }

        // Verify session is not marked handed off
        let s = relay.sessions(activeOnly: false, now: Date()).first { $0.sessionId == "sid_openscript" }
        #expect(s?.handedOff == false)

        // Verify openScript was called
        #expect(openScriptFailed.value)
    }

    @Test func handoffRejectsNonMainModel() throws {
        let relay = Relay(paths: paths, config: config, ctlPath: "ctl")

        let projectPath = tmpDir.appendingPathComponent("proj_nonmain")
        try FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)

        let handoffFile = projectPath.appendingPathComponent("handoff.md")
        try "handoff content".write(to: handoffFile, atomically: true, encoding: .utf8)

        // Try to handoff to a worker-only model
        let workerOnlyModel = ModelEntry(id: "worker-only", harness: "claude", name: "Worker Only", intelligence: 50, isMain: false, isWorker: true)
        let configWithWorker = AppConfig(harnesses: config.harnesses, models: config.models + [workerOnlyModel], mainOrder: config.mainOrder)
        let relayWithWorker = Relay(paths: paths, config: configWithWorker, ctlPath: "ctl")

        #expect(throws: HubError.self) {
            _ = try relayWithWorker.handoff(from: "claude", session: nil, project: projectPath.path, file: handoffFile.path, to: "worker-only", launch: false, automatic: false, now: Date())
        }
    }

    @Test func handoffRejectsDisabledModel() throws {
        let relay = Relay(paths: paths, config: config, ctlPath: "ctl")

        let projectPath = tmpDir.appendingPathComponent("proj_disabled")
        try FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)

        let handoffFile = projectPath.appendingPathComponent("handoff.md")
        try "handoff content".write(to: handoffFile, atomically: true, encoding: .utf8)

        // Create a config with a disabled main model
        let disabledModel = ModelEntry(id: "disabled-main", harness: "claude", name: "Disabled Main", intelligence: 99, isMain: true, isWorker: false, enabled: false)
        let configWithDisabled = AppConfig(harnesses: config.harnesses, models: config.models + [disabledModel], mainOrder: config.mainOrder)
        let relayWithDisabled = Relay(paths: paths, config: configWithDisabled, ctlPath: "ctl")

        #expect(throws: HubError.self) {
            _ = try relayWithDisabled.handoff(from: "claude", session: nil, project: projectPath.path, file: handoffFile.path, to: "disabled-main", launch: false, automatic: false, now: Date())
        }
    }

    @Test func testBackgroundPathAndModelNotCreatingSession() throws {
        let relay = Relay(paths: paths, config: config, ctlPath: "ctl")
        let now = Date()

        // 1. Hook with cwd under ~/.codex/memories does not create a MainSession
        let out1 = relay.hook("codex", event: "UserPromptSubmit", payload: [
            "session_id": "sid_bg1",
            "cwd": "~/.codex/memories",
            "model": "gpt-6.1-sol"
        ], env: [:], now: now)
        #expect(out1 == nil)
        #expect(relay.sessions(activeOnly: false, now: now).first { $0.sessionId == "sid_bg1" } == nil)
        #expect(!FileManager.default.fileExists(atPath: paths.sessions.appendingPathComponent("\(FileStore.key("codex", "sid_bg1")).json").path))

        // 2. Hook with model not in config does not create a MainSession
        let out2 = relay.hook("codex", event: "UserPromptSubmit", payload: [
            "session_id": "sid_bg2",
            "cwd": tmpDir.path,
            "model": "gpt-5.6-terra"
        ], env: [:], now: now)
        #expect(out2 == nil)
        #expect(relay.sessions(activeOnly: false, now: now).first { $0.sessionId == "sid_bg2" } == nil)
        #expect(!FileManager.default.fileExists(atPath: paths.sessions.appendingPathComponent("\(FileStore.key("codex", "sid_bg2")).json").path))

        // 3. Relay.sessions() skips such persisted files if they exist on disk
        let badPathSession = MainSession(harness: "codex", sessionId: "sid_disk1", model: "gpt-6.1-sol", cwd: "~/.codex/memories", started: now, lastSeen: now, lastEvent: "UserPromptSubmit", status: .working)
        let file1 = paths.sessions.appendingPathComponent("\(FileStore.key("codex", "sid_disk1")).json")
        try FileStore.write(badPathSession, to: file1)

        let badModelSession = MainSession(harness: "codex", sessionId: "sid_disk2", model: "gpt-5.6-terra", cwd: tmpDir.path, started: now, lastSeen: now, lastEvent: "UserPromptSubmit", status: .working)
        let file2 = paths.sessions.appendingPathComponent("\(FileStore.key("codex", "sid_disk2")).json")
        try FileStore.write(badModelSession, to: file2)

        let sessions = relay.sessions(activeOnly: false, now: now)
        #expect(sessions.first { $0.sessionId == "sid_disk1" } == nil)
        #expect(sessions.first { $0.sessionId == "sid_disk2" } == nil)
    }

    @Test func testOverLimitDeliversWrapUpExactlyOnce() throws {
        var limits = config.limits
        limits.maxMainSessions = 1
        let customConfig = AppConfig(harnesses: config.harnesses, models: config.models, mainOrder: config.mainOrder, limits: limits)
        let relay = Relay(paths: paths, config: customConfig, ctlPath: "ctl")
        let now = Date()

        // Session 1 is active
        _ = relay.hook("claude", event: "UserPromptSubmit", payload: ["session_id": "sid1", "cwd": "/proj1"], env: [:], now: now)

        // Session 2 is active and over the limit
        _ = relay.hook("codex", event: "UserPromptSubmit", payload: ["session_id": "sid2", "cwd": "/proj2", "model": "gpt-6.1-sol"], env: [:], now: now.addingTimeInterval(1))

        // First Stop hook on Session 2: delivers the wrap-up
        let out1 = relay.hook("codex", event: "Stop", payload: ["session_id": "sid2"], env: [:], now: now.addingTimeInterval(2))
        #expect(out1?["decision"] as? String == "block")
        let reason1 = out1?["reason"] as? String ?? ""
        #expect(reason1.contains("More than 1 main sessions are open") || reason1.contains("moves to"))

        // Check warned is set on Session 2
        let s2 = relay.sessions(activeOnly: false, now: now.addingTimeInterval(2)).first { $0.sessionId == "sid2" }
        #expect(s2?.warned != nil)

        // Mark the delivered message done
        relay.markDone("codex", "sid2", kind: .wrapUp, now: now.addingTimeInterval(3))

        // Repeated Stop hook on Session 2: does NOT deliver another wrap-up
        let out2 = relay.hook("codex", event: "Stop", payload: ["session_id": "sid2"], env: [:], now: now.addingTimeInterval(4))
        #expect(out2 == nil)

        // Check that inbox has only 1 wrapUp message and it is marked done
        let inboxFile = paths.inbox.appendingPathComponent("\(FileStore.key("codex", "sid2")).json")
        let msgs = FileStore.read([InboxMessage].self, from: inboxFile) ?? []
        let wrapUps = msgs.filter { $0.kind == .wrapUp }
        #expect(wrapUps.count == 1)
        #expect(wrapUps.first?.done != nil)

        // A third Stop hook also receives nothing
        let out3 = relay.hook("codex", event: "Stop", payload: ["session_id": "sid2"], env: [:], now: now.addingTimeInterval(5))
        #expect(out3 == nil)
    }

    @Test func testHandedOffOrEndedSessionReceivesNoWrapUp() throws {
        var limits = config.limits
        limits.maxMainSessions = 1
        let customConfig = AppConfig(harnesses: config.harnesses, models: config.models, mainOrder: config.mainOrder, limits: limits)
        let relay = Relay(paths: paths, config: customConfig, ctlPath: "ctl")
        let now = Date()

        // Session 1 is active
        _ = relay.hook("claude", event: "UserPromptSubmit", payload: ["session_id": "sid1", "cwd": "/proj1"], env: [:], now: now)

        // Session 2 is created, but already handedOff
        _ = relay.hook("codex", event: "SessionStart", payload: ["session_id": "sid2", "cwd": "/proj2", "model": "gpt-6.1-sol"], env: [:], now: now.addingTimeInterval(1))
        let sKey2 = FileStore.key("codex", "sid2")
        let sFile2 = paths.sessions.appendingPathComponent("\(sKey2).json")
        FileStore.withLock(paths, "session-" + sKey2) {
            var s = FileStore.read(MainSession.self, from: sFile2)!
            s.handedOff = true
            try? FileStore.write(s, to: sFile2)
        }

        // The wrap-up that led to the handoff is still pending; it must not re-block after the handoff
        _ = try relay.send("codex", "sid2", "move to claude", kind: .wrapUp, now: now.addingTimeInterval(1))
        let outPending = relay.hook("codex", event: "Stop", payload: ["session_id": "sid2"], env: [:], now: now.addingTimeInterval(2))
        #expect(outPending == nil)
        relay.markDone("codex", "sid2", kind: .wrapUp, now: now.addingTimeInterval(2))

        // Hook on handedOff session 2 receives no wrap-up and returns nil
        let outHandedOff = relay.hook("codex", event: "Stop", payload: ["session_id": "sid2"], env: [:], now: now.addingTimeInterval(2))
        #expect(outHandedOff == nil)
        #expect(relay.pending("codex", "sid2").isEmpty)
        let s2 = relay.sessions(activeOnly: false, now: now).first { $0.sessionId == "sid2" }
        #expect(s2?.warned == nil)

        // Session 3 is created, then ended
        _ = relay.hook("codex", event: "SessionStart", payload: ["session_id": "sid3", "cwd": "/proj3", "model": "gpt-6.1-sol"], env: [:], now: now.addingTimeInterval(3))
        _ = relay.hook("codex", event: "SessionEnd", payload: ["session_id": "sid3"], env: [:], now: now.addingTimeInterval(4))

        let outEnded = relay.hook("codex", event: "Stop", payload: ["session_id": "sid3"], env: [:], now: now.addingTimeInterval(5))
        #expect(outEnded == nil)
        #expect(relay.pending("codex", "sid3").isEmpty)
        let s3 = relay.sessions(activeOnly: false, now: now).first { $0.sessionId == "sid3" }
        #expect(s3?.warned == nil)
    }

    @Test func testRecoveryClearsWarnedAndNewestIsWarned() throws {
        var limits = config.limits
        limits.maxMainSessions = 1
        let customConfig = AppConfig(harnesses: config.harnesses, models: config.models, mainOrder: config.mainOrder, limits: limits)
        let relay = Relay(paths: paths, config: customConfig, ctlPath: "ctl")
        let now = Date()

        // Session 1 starts on claude
        _ = relay.hook("claude", event: "UserPromptSubmit", payload: ["session_id": "sid1", "cwd": "/proj1"], env: [:], now: now)

        // Session 2 starts on codex and is over the limit
        _ = relay.hook("codex", event: "UserPromptSubmit", payload: ["session_id": "sid2", "cwd": "/proj2", "model": "gpt-6.1-sol"], env: [:], now: now.addingTimeInterval(1))

        // Stop hook warns Session 2
        let out1 = relay.hook("codex", event: "Stop", payload: ["session_id": "sid2"], env: [:], now: now.addingTimeInterval(2))
        #expect(out1?["decision"] as? String == "block")

        var s2 = relay.sessions(activeOnly: false, now: now.addingTimeInterval(2)).first { $0.sessionId == "sid2" }
        #expect(s2?.warned != nil)

        // Now Session 1 ends -> Session 2 is now the only session, so it is NO LONGER over the limit!
        _ = relay.hook("claude", event: "SessionEnd", payload: ["session_id": "sid1"], env: [:], now: now.addingTimeInterval(3))

        // Hook on Session 2 triggers action-based recovery: warned is cleared
        _ = relay.hook("codex", event: "PostToolUse", payload: ["session_id": "sid2"], env: [:], now: now.addingTimeInterval(4))

        s2 = relay.sessions(activeOnly: false, now: now.addingTimeInterval(4)).first { $0.sessionId == "sid2" }
        #expect(s2?.warned == nil)

        // A new session 3 starts on claude: it is the newest, so it (not Session 2) is over the limit
        _ = relay.hook("claude", event: "UserPromptSubmit", payload: ["session_id": "sid3", "cwd": "/proj3"], env: [:], now: now.addingTimeInterval(5))

        let out2 = relay.hook("codex", event: "Stop", payload: ["session_id": "sid2"], env: [:], now: now.addingTimeInterval(6))
        #expect(out2 == nil)
        s2 = relay.sessions(activeOnly: false, now: now.addingTimeInterval(6)).first { $0.sessionId == "sid2" }
        #expect(s2?.warned == nil)

        let out3 = relay.hook("claude", event: "Stop", payload: ["session_id": "sid3"], env: [:], now: now.addingTimeInterval(7))
        #expect(out3?["decision"] as? String == "block")
        let s3 = relay.sessions(activeOnly: false, now: now.addingTimeInterval(7)).first { $0.sessionId == "sid3" }
        #expect(s3?.warned != nil)
    }

    @Test func testEngineWrapUpSurvivesVictimHook() throws {
        var limits = config.limits
        limits.maxMainSessions = 1
        let customConfig = AppConfig(harnesses: config.harnesses, models: config.models, mainOrder: config.mainOrder, limits: limits)
        let relay = Relay(paths: paths, config: customConfig, ctlPath: "ctl")
        let now = Date()

        _ = relay.hook("claude", event: "UserPromptSubmit", payload: ["session_id": "sid1", "cwd": "/proj1"], env: [:], now: now)
        _ = relay.hook("codex", event: "UserPromptSubmit", payload: ["session_id": "sid2", "cwd": "/proj2", "model": "gpt-6.1-sol"], env: [:], now: now.addingTimeInterval(1))
        // The older session keeps working; it must not take over or cancel the newer one's wrap-up
        _ = relay.hook("claude", event: "PostToolUse", payload: ["session_id": "sid1"], env: [:], now: now.addingTimeInterval(2))
        #expect(relay.pending("claude", "sid1").isEmpty)
        #expect(relay.pending("codex", "sid2").contains { $0.kind == .wrapUp })

        let out = relay.hook("codex", event: "Stop", payload: ["session_id": "sid2"], env: [:], now: now.addingTimeInterval(3))
        #expect((out?["reason"] as? String ?? "").contains("[agent-hub wrap_up]"))
    }

    @Test func testHandoffSourceVacancyAndSpecificReason() throws {
        var limits = config.limits
        limits.maxMainSessions = 1
        let customConfig = AppConfig(harnesses: config.harnesses, models: config.models, mainOrder: config.mainOrder, limits: limits)
        let openedScript = Box<URL?>(nil)
        let relay = Relay(paths: paths, config: customConfig, ctlPath: "ctl", openScript: { url in
            openedScript.value = url
            return true
        })
        let now = Date()

        let projectPath = tmpDir.appendingPathComponent("proj_handoff")
        try FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)
        let handoffFile = projectPath.appendingPathComponent("handoff.md")
        try "handoff content".write(to: handoffFile, atomically: true, encoding: .utf8)

        // Register 1 active session: sid1
        _ = relay.hook("claude", event: "UserPromptSubmit", payload: ["session_id": "sid1", "cwd": projectPath.path], env: [:], now: now)
        #expect(relay.sessions(activeOnly: true, now: now).count == 1)

        // Handoff from sid1: since maxMainSessions == 1, sid1 leaving frees the slot! Handoff succeeds!
        let record = try relay.handoff(from: "claude", session: "sid1", project: projectPath.path, file: handoffFile.path, to: "gpt-6.1-sol", launch: true, automatic: false, now: now.addingTimeInterval(1))
        #expect(record.toModel == "gpt-6.1-sol")
        #expect(openedScript.value != nil)

        // Now register 2 active sessions (sid_a and sid_b) with maxMainSessions = 1
        _ = relay.hook("claude", event: "UserPromptSubmit", payload: ["session_id": "sid_a", "cwd": projectPath.path], env: [:], now: now.addingTimeInterval(2))
        _ = relay.hook("codex", event: "UserPromptSubmit", payload: ["session_id": "sid_b", "cwd": projectPath.path, "model": "gpt-6.1-sol"], env: [:], now: now.addingTimeInterval(3))
        #expect(relay.sessions(activeOnly: true, now: now.addingTimeInterval(3)).count == 2)

        // When sid_a hands off, 1 session (sid_b) remains, so activeSessions.count (1) >= maxMainSessions (1).
        // It must fail with a specific reason that names the limit and the active session.
        #expect {
            try relay.handoff(from: "claude", session: "sid_a", project: projectPath.path, file: handoffFile.path, to: "gpt-6.1-sol", launch: true, automatic: false, now: now.addingTimeInterval(4))
        } throws: { error in
            guard case let HubError.noCapacity(reason) = error else { return false }
            return reason.contains("Global limit of 1 main sessions reached") &&
                   reason.contains("1 active:") &&
                   reason.contains("codex/gpt-6.1-sol@proj_handoff")
        }
    }

    @Test func testGlobalLimitWrapUpTextPhrasing() throws {
        var limits = config.limits
        limits.maxMainSessions = 1
        let customConfig = AppConfig(harnesses: config.harnesses, models: config.models, mainOrder: config.mainOrder, limits: limits)
        let relay = Relay(paths: paths, config: customConfig, ctlPath: "ctl")
        let now = Date()

        // Session 1 active
        _ = relay.hook("claude", event: "UserPromptSubmit", payload: ["session_id": "sid1", "cwd": "/proj1"], env: [:], now: now)

        // Session 2 active -> causes global capacity exceeded
        _ = relay.hook("codex", event: "UserPromptSubmit", payload: ["session_id": "sid2", "cwd": "/proj2", "model": "gpt-6.1-sol"], env: [:], now: now.addingTimeInterval(1))

        // Trigger Stop hook to deliver wrap-up
        let out = relay.hook("codex", event: "Stop", payload: ["session_id": "sid2"], env: [:], now: now.addingTimeInterval(2))
        let reason = out?["reason"] as? String ?? ""

        #expect(!reason.isEmpty)
        #expect(!reason.contains("usage is low"))
        #expect(reason.contains("More than 1 main sessions are open"))
    }
}
