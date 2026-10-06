import Testing
import Foundation
@testable import HubCore

@Suite struct PolicyTests {
    func makeConfig() -> AppConfig {
        let harnesses = [
            Harness(id: "claude", name: "Claude", executable: "claude", trusted: true, usageSource: .claudeStatusline, hookStyle: .claude, mainArgs: [], workerArgs: []),
            Harness(id: "codex", name: "Codex", executable: "codex", trusted: true, usageSource: .codexSessions, hookStyle: .codex, mainArgs: [], workerArgs: []),
            Harness(id: "opencode", name: "OpenCode", executable: "opencode", trusted: false, usageSource: .none, hookStyle: .none, mainArgs: [], workerArgs: [])
        ]
        let models = [
            ModelEntry(id: "claude-opus-5-5", harness: "claude", name: "Opus", intelligence: 98, isMain: true, isWorker: false),
            ModelEntry(id: "claude-sonnet-5-5", harness: "claude", name: "Sonnet", intelligence: 88, isMain: false, isWorker: true),
            ModelEntry(id: "gpt-6.1-sol", harness: "codex", name: "GPT6.1", intelligence: 97, isMain: true, isWorker: true),
            ModelEntry(id: "gpt-6-luna", harness: "codex", name: "Luna", intelligence: 80, isMain: false, isWorker: true),
            ModelEntry(id: "opencode/big-pickle", harness: "opencode", name: "Big Pickle", intelligence: 50, isMain: false, isWorker: true, free: true),
            ModelEntry(id: "gemini-3.8-flash-low", harness: "claude", name: "Gemini", intelligence: 55, isMain: false, isWorker: true)
        ]
        let mainOrder = ["claude-opus-5-5", "gpt-6.1-sol"]
        var c = AppConfig(harnesses: harnesses, models: models, mainOrder: mainOrder)
        c.limits.exhaustedAtOrBelow = 0.02
        c.limits.wrapUpBelow = 0.15
        c.limits.singleSessionBelow = 0.30
        c.limits.sameHarnessMinLeft = 0.40
        c.limits.workerMinLeft = 0.15
        c.limits.maxMainSessions = 2
        c.limits.maxJobs = 4
        return c
    }
    
    @Test func freeWorkerBeatsCrossHarnessPaidWorkerForGenericJobs() {
        var c = makeConfig()
        c.models.append(ModelEntry(id: "opencode/free-60", harness: "opencode", name: "Free 60", intelligence: 60, isMain: false, isWorker: true, free: true))
        let s = Snapshot(config: c, usage: [:], sessions: [], jobs: [], now: Date())
        // Main is Claude: before, the Codex worker won on harness; a free OpenCode model now goes first.
        #expect(PolicyEngine.pickWorker(s, .routine, .implement, .generic, mainModel: "claude-opus-5-5")?.id == "opencode/free-60")
        // Project jobs still never go to an untrusted free model directly.
        #expect(PolicyEngine.pickWorker(s, .routine, .implement, .project, mainModel: "claude-opus-5-5")?.free != true)
    }

    @Test func bands() {
        var s = Snapshot(config: makeConfig(), usage: [:], sessions: [], jobs: [], now: Date())
        #expect(PolicyEngine.band(s, "claude") == .healthy) // unknown
        
        s.usage["claude"] = UsageReading(left: 0.41, source: "test")
        #expect(PolicyEngine.band(s, "claude") == .healthy)
        
        s.usage["claude"] = UsageReading(left: 0.40, source: "test")
        #expect(PolicyEngine.band(s, "claude") == .healthy)
        
        s.usage["claude"] = UsageReading(left: 0.39, source: "test")
        #expect(PolicyEngine.band(s, "claude") == .reduced)
        
        s.usage["claude"] = UsageReading(left: 0.30, source: "test")
        #expect(PolicyEngine.band(s, "claude") == .reduced)
        
        s.usage["claude"] = UsageReading(left: 0.29, source: "test")
        #expect(PolicyEngine.band(s, "claude") == .single)
        
        s.usage["claude"] = UsageReading(left: 0.15, source: "test")
        #expect(PolicyEngine.band(s, "claude") == .single)
        
        s.usage["claude"] = UsageReading(left: 0.14, source: "test")
        #expect(PolicyEngine.band(s, "claude") == .wrapUp)
        
        s.usage["claude"] = UsageReading(left: 0.02, source: "test")
        #expect(PolicyEngine.band(s, "claude") == .exhausted)
        
        s.usage["claude"] = UsageReading(left: 0.01, source: "test")
        #expect(PolicyEngine.band(s, "claude") == .exhausted)
        
        s.usage["claude"] = UsageReading(left: 0.50, source: "test", coolingUntil: s.now.addingTimeInterval(10))
        #expect(PolicyEngine.band(s, "claude") == .exhausted)
    }
    
    @Test func testSessionCap() {
        var s = Snapshot(config: makeConfig(), usage: [:], sessions: [], jobs: [], now: Date())
        #expect(PolicyEngine.sessionCap(s, "claude") == 2)
        
        s.usage["claude"] = UsageReading(left: 0.35, source: "")
        #expect(PolicyEngine.sessionCap(s, "claude") == 2)
        
        s.usage["claude"] = UsageReading(left: 0.25, source: "")
        #expect(PolicyEngine.sessionCap(s, "claude") == 1)
        
        s.usage["claude"] = UsageReading(left: 0.10, source: "")
        #expect(PolicyEngine.sessionCap(s, "claude") == 0)
        
        s.usage["claude"] = UsageReading(left: 0.01, source: "")
        #expect(PolicyEngine.sessionCap(s, "claude") == 0)
    }
    
    @Test func canStartMainTest() {
        var s = Snapshot(config: makeConfig(), usage: [:], sessions: [], jobs: [], now: Date())
        #expect(PolicyEngine.canStartMain(s, "fake").ok == false)
        
        #expect(PolicyEngine.canStartMain(s, "claude-sonnet-5-5").ok == false) // not main
        
        #expect(PolicyEngine.canStartMain(s, "claude-opus-5-5").ok == true)
        
        s.sessions.append(MainSession(harness: "claude", sessionId: "1", cwd: "", started: Date(), lastSeen: Date(), lastEvent: "", status: .working))
        #expect(PolicyEngine.canStartMain(s, "claude-opus-5-5").ok == true)
        
        s.sessions.append(MainSession(harness: "codex", sessionId: "2", cwd: "", started: Date(), lastSeen: Date(), lastEvent: "", status: .working))
        #expect(PolicyEngine.canStartMain(s, "claude-opus-5-5").ok == false) // total cap
        
        s.sessions.removeLast()
        s.usage["claude"] = UsageReading(left: 0.25, source: "")
        #expect(PolicyEngine.canStartMain(s, "claude-opus-5-5").ok == false) // harness cap (1) reached
        
        var cfg = makeConfig()
        let idx = cfg.models.firstIndex { $0.id == "claude-opus-5-5" }!
        cfg.models[idx].enabled = false
        s.config = cfg
        #expect(PolicyEngine.canStartMain(s, "claude-opus-5-5").ok == false) // disabled
    }
    
    @Test func pickWorkerTest() {
        var s = Snapshot(config: makeConfig(), usage: [:], sessions: [], jobs: [], now: Date())
        // smallest capable first
        let w1 = PolicyEngine.pickWorker(s, .tiny, .implement, .generic, mainModel: nil)
        #expect(w1?.id == "opencode/big-pickle") // intelligence 50
        
        // project privacy excludes untrusted
        let w2 = PolicyEngine.pickWorker(s, .tiny, .implement, .project, mainModel: nil)
        #expect(w2?.id == "gemini-3.8-flash-low") // intelligence 55, next smallest trusted
        
        // same-harness rule at left 0.39 vs 0.41 and unknown
        s.usage["claude"] = UsageReading(left: 0.39, source: "")
        let w3 = PolicyEngine.pickWorker(s, .routine, .implement, .generic, mainModel: "claude-opus-5-5") // main is claude
        #expect(w3?.harness != "claude")
        
        s.usage["claude"] = UsageReading(left: 0.41, source: "")
        let w4 = PolicyEngine.pickWorker(s, .routine, .implement, .generic, mainModel: "claude-opus-5-5")
        // might pick claude if it's the smallest capable but 0.41 > sameHarnessMinLeft
        
        // workerCap reduced=1 and below workerMinLeft=0
        s.usage["codex"] = UsageReading(left: 0.20, source: "")
        s.jobs.append(Job(project: "", objective: "", allowedFiles: [], checkArgv: [], size: .tiny, kind: .implement, privacy: .generic, created: Date()))
        s.jobs[0].harness = "codex"
        s.jobs[0].state = .running
        
        let w5 = PolicyEngine.pickWorker(s, .hard, .implement, .generic, mainModel: nil) // needs int 75 -> gpt-6-luna (80) or similar
        // codex is at 0.20, so workerCap is 1. We have 1 codex job. So codex is excluded.
        #expect(w5?.harness != "codex")
        
        s.usage["codex"] = UsageReading(left: 0.14, source: "")
        // below workerMinLeft -> cap is 0
        s.jobs.removeAll()
        let w6 = PolicyEngine.pickWorker(s, .hard, .implement, .generic, mainModel: nil)
        #expect(w6?.harness != "codex")
        
        // maxJobs reached returns nil
        for _ in 0..<4 {
            s.jobs.append(Job(project: "", objective: "", allowedFiles: [], checkArgv: [], size: .tiny, kind: .implement, privacy: .generic, created: Date()))
        }
        #expect(PolicyEngine.pickWorker(s, .tiny, .implement, .generic, mainModel: nil) != nil) // queued jobs do not use slots
        for i in s.jobs.indices { s.jobs[i].state = .running }
        #expect(PolicyEngine.pickWorker(s, .tiny, .implement, .generic, mainModel: nil) == nil)
        
        s.jobs.removeAll()
        // cross-harness preferred over same harness
        // both claude-sonnet-5-5 (int 88) and gpt-6-luna (int 80) are available.
        // wait, we want them to have same intelligence so tie-breaker is harness.
        // Let's create a temporary config where two workers have the same intelligence.
        var s2 = s
        let sameIntModels = [
            ModelEntry(id: "m-claude", harness: "claude", name: "C", intelligence: 80, isMain: false, isWorker: true),
            ModelEntry(id: "m-codex", harness: "codex", name: "X", intelligence: 80, isMain: true, isWorker: true) // main model
        ]
        var cfg2 = s.config
        cfg2.models.append(contentsOf: sameIntModels)
        s2.config = cfg2
        
        let w7 = PolicyEngine.pickWorker(s2, .hard, .review, .generic, mainModel: "m-codex") 
        #expect(w7?.harness == "claude")
    }
    
    @Test func bestMainTest() {
        var s = Snapshot(config: makeConfig(), usage: [:], sessions: [], jobs: [], now: Date())
        // idle harness first
        s.sessions.append(MainSession(harness: "claude", sessionId: "1", cwd: "", started: Date(), lastSeen: Date(), lastEvent: "", status: .working))
        let m1 = PolicyEngine.bestMain(s, excludingHarness: nil, planned: [:])
        #expect(m1?.harness == "codex")
        
        // then intelligence, then mainOrder, planned load respected
        s.sessions.removeAll()
        s.usage["codex"] = UsageReading(left: 0.50, source: "")
        s.usage["claude"] = UsageReading(left: 0.60, source: "")
        
        let m2 = PolicyEngine.bestMain(s, excludingHarness: nil, planned: ["codex": 2])
        #expect(m2?.harness == "claude")
    }
    
    @Test func rebalanceTest() {
        let now = Date()
        var s = Snapshot(config: makeConfig(), usage: [:], sessions: [], jobs: [], now: now)
        
        // codex at 0.25 with two sessions keeps the earliest-started and wraps up the newer one targeting the claude main
        s.usage["codex"] = UsageReading(left: 0.25, source: "")
        s.sessions.append(MainSession(harness: "codex", sessionId: "old", cwd: "", started: now.addingTimeInterval(-100), lastSeen: now.addingTimeInterval(-100), lastEvent: "", status: .working))
        s.sessions.append(MainSession(harness: "codex", sessionId: "new", cwd: "", started: now.addingTimeInterval(-10), lastSeen: now.addingTimeInterval(-10), lastEvent: "", status: .working))
        
        let actions1 = PolicyEngine.rebalance(s, alreadyWarned: [])
        #expect(actions1.count == 1)
        if case .wrapUp(let session, let target, _) = actions1[0] {
            #expect(session.sessionId == "new")
            #expect(target?.harness == "claude")
        } else {
            Issue.record("Expected wrapUp")
        }
        
        // harness at 0.10 wraps up its last session
        s.usage["claude"] = UsageReading(left: 0.10, source: "")
        s.sessions.removeAll()
        s.sessions.append(MainSession(harness: "claude", sessionId: "c1", cwd: "", started: now, lastSeen: now, lastEvent: "", status: .working))
        let actions2 = PolicyEngine.rebalance(s, alreadyWarned: [])
        #expect(actions2.count == 1)
        if case .wrapUp(let session, _, _) = actions2[0] {
            #expect(session.sessionId == "c1")
        } else {
            Issue.record("Expected wrapUp")
        }
        
        // global maxMainSessions exceeded
        s.usage.removeAll()
        s.sessions.removeAll()
        s.sessions.append(MainSession(harness: "claude", sessionId: "c1", cwd: "", started: now.addingTimeInterval(-100), lastSeen: now.addingTimeInterval(-100), lastEvent: "", status: .working))
        s.sessions.append(MainSession(harness: "codex", sessionId: "cd1", cwd: "", started: now.addingTimeInterval(-50), lastSeen: now.addingTimeInterval(-50), lastEvent: "", status: .working))
        s.sessions.append(MainSession(harness: "claude", sessionId: "c2", cwd: "", started: now.addingTimeInterval(-10), lastSeen: now.addingTimeInterval(-10), lastEvent: "", status: .working))
        
        let actions3 = PolicyEngine.rebalance(s, alreadyWarned: [])
        #expect(actions3.count == 1)
        if case .wrapUp(let session, _, _) = actions3[0] {
            #expect(session.sessionId == "c2") // newest-started is over capacity
        } else {
            Issue.record("Expected wrapUp")
        }
        
        // already-warned sessions are not warned again
        let actions4 = PolicyEngine.rebalance(s, alreadyWarned: ["claude-c2"])
        #expect(actions4.isEmpty) // c2 is skipped, and only one session is over capacity

        // the victim stays the newest-started session even after the older one fires a hook
        s.sessions[0].lastSeen = now
        let stableActions = PolicyEngine.rebalance(s, alreadyWarned: [])
        #expect(stableActions.count == 1)
        if case .wrapUp(let session, _, _) = stableActions.first {
            #expect(session.sessionId == "c2")
        } else {
            Issue.record("Expected wrapUp")
        }
        
        // autoHandoff only when exhausted AND grace elapsed AND a target exists
        s.sessions.removeAll()
        var exhaustedSession = MainSession(harness: "claude", sessionId: "c1", cwd: "", started: now, lastSeen: now, lastEvent: "", status: .working)
        exhaustedSession.warned = now.addingTimeInterval(-601) // grace is 600
        s.sessions.append(exhaustedSession)
        s.usage["claude"] = UsageReading(left: 0.01, source: "")
        
        let actions5 = PolicyEngine.rebalance(s, alreadyWarned: ["claude-c1"])
        #expect(actions5.count == 1)
        if case .autoHandoff(let session, let target) = actions5[0] {
            #expect(session.sessionId == "c1")
            #expect(target.harness == "codex")
        } else {
            Issue.record("Expected autoHandoff")
        }
        
        // notify when exhausted with no target
        s.usage["codex"] = UsageReading(left: 0.01, source: "")
        let actions6 = PolicyEngine.rebalance(s, alreadyWarned: ["claude-c1"])
        // both exhausted. No target for claude.
        // It should produce autoHandoff? No target!
        var hasNotify = false
        for act in actions6 {
            if case .notify = act { hasNotify = true }
        }
        #expect(hasNotify)
    }
    
    @Test func explainTest() {
        var s = Snapshot(config: makeConfig(), usage: [:], sessions: [], jobs: [], now: Date())
        s.usage["codex"] = UsageReading(left: 0.34, source: "")
        let lines = PolicyEngine.explain(s)
        #expect(lines.count == s.config.harnesses.count)
        #expect(lines.contains { $0.contains("Codex 34% left → reduced") })
    }

    @Test func sameHarnessRuleKeepsMainQuota() {
        var cfg = makeConfig()
        cfg.models = cfg.models.filter { $0.harness == "claude" }
        cfg.mainOrder = ["claude-opus-5-5"]
        var s = Snapshot(config: cfg, usage: [:], sessions: [], jobs: [], now: Date())
        #expect(PolicyEngine.pickWorker(s, .routine, .implement, .project, mainModel: "claude-opus-5-5")?.harness == "claude") // unknown usage
        s.usage["claude"] = UsageReading(left: 0.41, source: "")
        #expect(PolicyEngine.pickWorker(s, .routine, .implement, .project, mainModel: "claude-opus-5-5")?.harness == "claude")
        s.usage["claude"] = UsageReading(left: 0.39, source: "")
        #expect(PolicyEngine.pickWorker(s, .routine, .implement, .project, mainModel: "claude-opus-5-5") == nil)
        #expect(PolicyEngine.pickWorker(s, .routine, .implement, .project, mainModel: nil) != nil) // another harness's main may still use it
    }

    @Test func exhaustedHarnessWithoutSessionsIsQuiet() {
        var s = Snapshot(config: makeConfig(), usage: [:], sessions: [], jobs: [], now: Date())
        s.usage["antigravity"] = UsageReading(left: 0, source: "", coolingUntil: Date().addingTimeInterval(600))
        #expect(PolicyEngine.rebalance(s, alreadyWarned: []).isEmpty)
    }

    @Test func brokerEligibilityCanIncludeLunaButStillRequiresTrustedEnabledWorker() throws {
        var config = makeConfig()
        var state = Snapshot(config: config, usage: [:], sessions: [], jobs: [], now: Date())

        // A config without per-model values keeps the old 55...79 broker set.
        #expect(PolicyEngine.pickBroker(state, mainModel: "gpt-6.1-sol")?.id == "gemini-3.8-flash-low")

        let lunaIndex = try #require(config.models.firstIndex { $0.id == "gpt-6-luna" })
        config.models[lunaIndex].brokerEligible = true
        let legacyBrokerIndex = try #require(config.models.firstIndex { $0.id == "gemini-3.8-flash-low" })
        config.models[legacyBrokerIndex].brokerEligible = false
        state.config = config
        #expect(PolicyEngine.pickBroker(state, mainModel: "gpt-6.1-sol")?.id == "gpt-6-luna")

        // An explicit selection cannot make disabled models, non-workers, or untrusted workers eligible.
        let opusIndex = try #require(config.models.firstIndex { $0.id == "claude-opus-5-5" })
        config.models[opusIndex].brokerEligible = true
        let sonnetIndex = try #require(config.models.firstIndex { $0.id == "claude-sonnet-5-5" })
        config.models[sonnetIndex].brokerEligible = true
        config.models[sonnetIndex].enabled = false
        let openCodeIndex = try #require(config.models.firstIndex { $0.id == "opencode/big-pickle" })
        config.models[openCodeIndex].brokerEligible = true
        let lunaModelIndex = try #require(config.models.firstIndex { $0.id == "gpt-6-luna" })
        config.models[lunaModelIndex].enabled = false
        state.config = config
        #expect(PolicyEngine.pickBroker(state, mainModel: "gpt-6.1-sol") == nil)

        config.harnesses.append(Harness(id: "antigravity", name: "Antigravity", executable: "antigravity", trusted: true,
                                        usageSource: .manual, hookStyle: .none, mainArgs: [], workerArgs: []))
        config.models.append(ModelEntry(id: "disabled-gemini", harness: "antigravity", name: "Disabled Gemini", intelligence: 75,
                                        isMain: false, isWorker: true, enabled: false, brokerEligible: true))
        state.config = config
        #expect(PolicyEngine.pickBroker(state, mainModel: "gpt-6.1-sol") == nil)
    }

    @Test func explicitlyRequestedWorkerResolvesByQualifiedIdentity() throws {
        var config = makeConfig()
        let agy = Harness(id: "antigravity", name: "Antigravity", executable: "agy", trusted: true,
                          usageSource: .manual, hookStyle: .none, mainArgs: [], workerArgs: [])
        config.harnesses.append(agy)
        config.models.append(ModelEntry(id: "gpt-6-luna", harness: "antigravity", name: "Agy Luna", intelligence: 80,
                                        isMain: false, isWorker: true, enabled: false))
        let snapshot = Snapshot(config: config, usage: [:], sessions: [], jobs: [], now: Date())
        let job = Job(project: "/tmp", objective: "pin worker", allowedFiles: ["a"], checkArgv: ["true"], size: .tiny,
                      kind: .implement, privacy: .project, mainModel: "codex/gpt-6.1-sol",
                      requestedWorker: "antigravity/gpt-6-luna", created: Date())
        let plan = try #require(PolicyEngine.plan(snapshot, job))
        #expect(plan.worker.harness == "antigravity")
        #expect(plan.worker.id == "gpt-6-luna")
    }

    @Test func disabledClaudeModelsNeverRoute() throws {
        var config = ConfigStore.defaults()
        for i in config.models.indices where config.models[i].harness == "claude" {
            config.models[i].enabled = false
        }
        config.mainOrder = ["gpt-6.1-sol"]
        let now = Date()
        var state = Snapshot(config: config, usage: [:], sessions: [], jobs: [], now: now)
        #expect(PolicyEngine.bestMain(state, excludingHarness: nil, planned: [:])?.id == "gpt-6.1-sol")
        #expect(PolicyEngine.bestMain(state, excludingHarness: "codex", planned: [:]) == nil)
        #expect(PolicyEngine.canStartMain(state, "gpt-6.1-sol").ok)
        for model in config.models where model.harness == "claude" {
            #expect(!PolicyEngine.canStartMain(state, model.id).ok)
        }
        let broker = try #require(PolicyEngine.pickBroker(state, mainModel: "gpt-6.1-sol"))
        #expect(broker.enabled && broker.harness != "claude")
        for size in [JobSize.tiny, .routine, .hard] {
            for kind in [JobKind.implement, .review, .plan] {
                for privacy in [Privacy.project, .generic] {
                    let job = Job(project: "/tmp/test", objective: "Task", allowedFiles: ["main.swift"],
                                  checkArgv: ["true"], size: size, kind: kind, privacy: privacy,
                                  mainModel: "gpt-6.1-sol", created: now)
                    let plan = try #require(PolicyEngine.plan(state, job))
                    #expect(plan.worker.enabled && plan.worker.harness != "claude")
                    if let broker = plan.broker { #expect(broker.enabled && broker.harness != "claude") }
                    if size == .hard && kind == .implement && privacy == .project {
                        #expect(plan.broker != nil)
                    }
                }
            }
        }
        for id in ["s1", "s2"] {
            state.sessions.append(MainSession(harness: "codex", sessionId: id, cwd: "/tmp/test",
                                              started: now.addingTimeInterval(-100), lastSeen: now,
                                              lastEvent: "", status: .working))
        }
        state.usage["codex"] = UsageReading(left: 0.25, source: "test")
        let actions = PolicyEngine.rebalance(state, alreadyWarned: [])
        #expect(!actions.isEmpty)
        for action in actions {
            switch action {
            case .wrapUp(_, let target, _):
                #expect(target == nil || (target!.enabled && target!.harness != "claude"))
            case .autoHandoff(_, let target):
                #expect(target.enabled && target.harness != "claude")
            default: break
            }
        }
    }
}
