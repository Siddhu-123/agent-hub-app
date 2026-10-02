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
        
        #expect(throws: HubError.noCapacity("No capacity for handoff")) {
            _ = try relay.handoff(from: "claude", session: "sid1", project: projectPath.path, file: handoffFile.path, to: nil, launch: true, automatic: false, now: Date())
        }
    }
    
    @Test func applyAutoHandoffWritesMarkdownAndInterrupts() throws {
        let interruptedPid = Box<Int32?>(nil)
        let relay = Relay(paths: paths, config: config, ctlPath: "ctl", interrupt: { pid in
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
}
