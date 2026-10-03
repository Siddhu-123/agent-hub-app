import Foundation
import Testing
@testable import HubCore

struct HubTreeTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    func session(_ id: String, platform: String = "claude", status: String = "working", updated: Double? = nil, cwd: String = "/work/p", model: String? = "model") -> LiveSession {
        LiveSession(platform: platform, platformName: platform, sessionId: id, title: "Session \(id)", status: status,
                    activity: "Working", app: "", startedAt: now.timeIntervalSince1970 - 100,
                    updatedAt: updated ?? now.timeIntervalSince1970, cwd: cwd, model: model)
    }
    func job(_ id: String, state: JobState = .queued, created: Date? = nil, project: String = "/work/p", parent: String? = nil, mainModel: String? = "model") -> Job {
        var job = Job(id: id, project: project, objective: "Objective \(id)", allowedFiles: ["main.swift"], checkArgv: ["sh", "check.sh"], size: .routine, kind: .implement, privacy: .project, mainModel: mainModel, created: created ?? now)
        job.parentSession = parent
        job.state = state
        if state == .verified || state == .failed { job.finished = created ?? now }
        return job
    }

    @Test func linksByParentSessionBeforeFallback() {
        var explicit = job("explicit", parent: "codex:c-2")
        explicit.project = "/somewhere/else"
        let roots = HubTree.build(sessions: [session("c-1"), session("c-2", platform: "codex", cwd: "/different")], jobs: [explicit], modelHarness: ["model": "claude"], now: now)
        #expect(roots.first { $0.id == "s:codex:c-2" }?.children.first?.id == "j:explicit")
    }

    @Test func fallbackRequiresCwdAndModelHarnessAndChoosesNewest() {
        let older = session("old", updated: now.timeIntervalSince1970 - 10)
        let newer = session("new", updated: now.timeIntervalSince1970 - 1)
        let root = HubTree.build(sessions: [older, newer], jobs: [job("fallback")], modelHarness: ["model": "claude"], now: now)
        #expect(root.first { $0.id == "s:claude:new" }?.children.first?.id == "j:fallback")
        #expect(root.first { $0.id == "s:claude:old" }?.children.isEmpty == true)
        let mismatch = HubTree.build(sessions: [newer], jobs: [job("mismatch")], modelHarness: ["model": "codex"], now: now)
        #expect(mismatch.last?.id == "orphans")
        #expect(mismatch.first { $0.id == "s:claude:new" }?.children.isEmpty == true)
    }

    @Test func orphansAndOldFinishedJobsAreHandled() {
        let recent = job("orphan", state: .verified, created: now.addingTimeInterval(-60), project: "/missing")
        let old = job("old", state: .verified, created: now.addingTimeInterval(-1801), project: "/missing")
        let roots = HubTree.build(sessions: [], jobs: [old, recent], modelHarness: [:], now: now)
        #expect(roots.map(\.id) == ["orphans"])
        #expect(roots.first?.children.map(\.id) == ["j:orphan"])
    }

    @Test func rootAndChildOrdering() {
        let idleNew = session("idle", status: "idle", updated: now.timeIntervalSince1970 - 1)
        let busyOld = session("busy", status: "working", updated: now.timeIntervalSince1970 - 20)
        var older = job("older", created: now.addingTimeInterval(-20), parent: "claude:busy")
        older.project = "/elsewhere"
        let newer = job("newer", created: now.addingTimeInterval(-1), parent: "claude:busy")
        let roots = HubTree.build(sessions: [idleNew, busyOld], jobs: [older, newer], modelHarness: [:], now: now)
        #expect(roots.map(\.id) == ["s:claude:busy", "s:claude:idle"])
        #expect(roots[0].children.map(\.id) == ["j:newer", "j:older"])
    }

    @Test func brokerAndCheckChildrenReflectGate() {
        var passed = job("passed")
        passed.parentSession = "claude:s"
        passed.broker = "broker-model"
        passed.gate = GateResult(acceptance: CheckResult(argv: ["sh", "check.sh"], exitCode: 0, timedOut: false, output: "ok"), changedFiles: ["main.swift"], outsideAllowed: [])
        var failed = job("failed")
        failed.parentSession = "claude:s"
        failed.gate = GateResult(acceptance: CheckResult(argv: ["sh", "check.sh"], exitCode: 1, timedOut: false, output: "no"), changedFiles: [], outsideAllowed: [])
        let root = HubTree.build(sessions: [session("s")], jobs: [passed, failed], modelHarness: [:], now: now).first
        let passedNode = try! #require(root?.children.first { $0.id == "j:passed" })
        #expect(passedNode.children.map(\.id) == ["b:passed", "c:passed"])
        #expect(passedNode.children[0].role == .broker)
        #expect(passedNode.children[1].status == "passed")
        #expect(root?.children.first { $0.id == "j:failed" }?.children.last?.status == "failed")
    }

    @Test func subagentsBecomeSessionChildren() {
        var main = session("s")
        main.agents = [LiveAgent(id: "a1", type: "researcher", description: "Find sources", status: "running", activity: "Reading", startedAt: now.timeIntervalSince1970)]
        let root = HubTree.build(sessions: [main], jobs: [], modelHarness: [:], now: now).first
        #expect(root?.children.map(\.id) == ["a:a1"])
        #expect(root?.children.first?.role == .subagent)
        #expect(root?.children.first?.subtitle == "Find sources")
        #expect(root?.children.first?.active == true)
    }
}
