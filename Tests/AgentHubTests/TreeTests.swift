import Foundation
import Testing
import HubCore
@testable import AgentHub

struct TreeTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func paths() -> HubPaths {
        HubPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }
    func save(_ session: LiveSession, paths: HubPaths) throws {
        let dir = paths.live.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(session).write(to: dir.appendingPathComponent(session.sessionId + ".json"))
    }
    func read(_ paths: HubPaths, after previous: TreeSnapshot? = nil, at date: Date? = nil) -> TreeSnapshot {
        TreeReader.read(paths: paths, modelHarness: [:], detailId: nil, cache: previous?.cache ?? TreeCache(),
                        flows: previous?.flows ?? [:], now: date ?? now)
    }
    func session(_ id: String, transcript: URL? = nil) -> LiveSession {
        LiveSession(platform: "claude", platformName: "Claude", sessionId: id, title: "Chat", status: "working",
                    activity: "Working", app: "", startedAt: now.timeIntervalSince1970 - 100,
                    updatedAt: now.timeIntervalSince1970, model: "model", transcript: transcript?.path)
    }
    func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    @Test func chatCachePersistsAndGrowthExpires() throws {
        let paths = paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let transcript = paths.root.appendingPathComponent("chat.jsonl")
        let user = "{\"type\":\"user\",\"message\":{\"content\":\"Exact user words\"}}\n"
        try user.write(to: transcript, atomically: true, encoding: .utf8)
        try save(session("chat", transcript: transcript), paths: paths)
        let first = read(paths)
        let id = "s:claude:chat"
        #expect(first.chats[id] == [ChatEntry(role: .user, text: "Exact user words")])
        #expect(first.flows.isEmpty)
        let unchanged = read(paths, after: first, at: now.addingTimeInterval(1))
        #expect(unchanged.chats == first.chats)
        #expect(unchanged.fullChats == first.fullChats)
        #expect(unchanged.flows.isEmpty)
        let reply = "Full reply\n" + String(repeating: "wrapped words ", count: 50) + "end"
        let data = try JSONSerialization.data(withJSONObject: ["type": "assistant", "message": ["content": [["type": "text", "text": reply]]]])
        try append(String(decoding: data, as: UTF8.self) + "\n", to: transcript)
        let growth = read(paths, after: unchanged, at: now.addingTimeInterval(2))
        #expect(growth.chats[id]?.last?.text == reply)
        #expect((growth.flows[id]?.count ?? 0) > 0)
        let expired = read(paths, after: growth, at: now.addingTimeInterval(6))
        #expect(expired.flows.isEmpty)
        #expect(expired.chats == growth.chats)
        try user.write(to: transcript, atomically: true, encoding: .utf8)
        let shrunk = read(paths, after: expired, at: now.addingTimeInterval(7))
        #expect(shrunk.flows.isEmpty)
        #expect(shrunk.chats[id]?.count == 1)
    }

    @Test func codexLiveModelRefreshesTheExistingSessionNode() throws {
        let paths = paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        var codex = session("model-switch")
        codex.platform = "codex"
        codex.platformName = "Codex"
        codex.model = "gpt-old"
        try save(codex, paths: paths)

        let first = read(paths)
        let id = "s:codex:model-switch"
        #expect(first.sessions[id]?.model == "gpt-old")
        #expect(first.roots.first?.title == "gpt-old")

        codex.model = "gpt-new"
        try save(codex, paths: paths)
        let refreshed = read(paths, after: first, at: now.addingTimeInterval(1))
        #expect(refreshed.sessions[id]?.model == "gpt-new")
        #expect(refreshed.roots.first?.title == "gpt-new")
    }

    @Test func completedJobIsHiddenFromTreeButRetainedInSnapshot() throws {
        let paths = paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try save(session("done"), paths: paths)
        var finished = Job(id: "finished", project: paths.root.path, objective: "Finished work", allowedFiles: ["a"],
                           checkArgv: ["echo", "ok"], size: .tiny, kind: .implement, privacy: .project, created: now)
        finished.parentSession = "claude:done"
        finished.state = .verified
        finished.finished = now
        try JobStore(paths: paths).save(finished)

        let snapshot = read(paths)
        #expect(snapshot.roots.first?.children.isEmpty == true)
        #expect(snapshot.jobs[finished.id]?.state == .verified)
    }

    @Test func logGrowthGoesOnlyToCurrentStage() throws {
        let paths = paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var job = Job(id: "stage", project: paths.root.path, objective: "test", allowedFiles: ["a"],
                      checkArgv: ["echo", "ok"], size: .tiny, kind: .implement, privacy: .project, created: now)
        job.state = .running
        job.broker = "broker-model"
        try JobStore(paths: paths).save(job)
        JobLog.mark(paths, job.id, "MASK broker")
        let first = read(paths)
        #expect(first.flows.isEmpty)
        JobLog.append(paths, job.id, Data("mask output\n".utf8))
        let mask = read(paths, after: first, at: now.addingTimeInterval(1))
        #expect(Set(mask.flows.keys) == ["b:stage"])
        #expect(mask.roots.first?.children.first?.active == false)
        JobLog.mark(paths, job.id, "HEAVY worker attempt 1")
        JobLog.append(paths, job.id, Data(String(repeating: "x", count: 4_000).utf8))
        let heavy = read(paths, after: mask, at: now.addingTimeInterval(4))
        #expect(Set(heavy.flows.keys) == ["j:stage"])
        #expect(heavy.flows["j:stage"]?.count == 6)
        JobLog.mark(paths, job.id, "check echo ok")
        let check = read(paths, after: heavy, at: now.addingTimeInterval(8))
        #expect(Set(check.flows.keys) == ["c:stage"])
        #expect(check.roots.first?.children.first?.children.last?.active == true)
        let idle = read(paths, after: check, at: now.addingTimeInterval(12))
        #expect(idle.flows.isEmpty)
    }

    @Test func missingTranscriptLocateIsThrottledAndIdleRuleIsShared() throws {
        let paths = paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var idle = session(UUID().uuidString)
        idle.status = "idle"
        idle.updatedAt = now.timeIntervalSince1970 - 121
        #expect(idle.isUnpromptedIdle(at: now))
        try save(idle, paths: paths)
        #expect(read(paths).roots.isEmpty)
        idle.lastPrompt = "Hello"
        #expect(!idle.isUnpromptedIdle(at: now))
        try save(idle, paths: paths)
        let first = read(paths)
        let id = "s:claude:" + idle.sessionId
        let second = read(paths, after: first, at: now.addingTimeInterval(1))
        #expect(second.cache.transcripts[id]?.located == first.cache.transcripts[id]?.located)
        let retry = read(paths, after: second, at: now.addingTimeInterval(11))
        #expect(retry.cache.transcripts[id]?.located == now.addingTimeInterval(11))
        idle.lastPrompt = nil
        idle.updatedAt = now.timeIntervalSince1970 - 120
        #expect(!idle.isUnpromptedIdle(at: now))
    }

    @Test func cardAndDrawerKeepTheirLimitsAndSubagentsReceiveGrowth() throws {
        let paths = paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let transcript = paths.root.appendingPathComponent("many.jsonl")
        let lines = (0..<450).map { "{\"type\":\"user\",\"message\":{\"content\":\"Message \($0)\"}}\n" }.joined()
        try lines.write(to: transcript, atomically: true, encoding: .utf8)
        var session = session("many", transcript: transcript)
        session.agents = [LiveAgent(id: "child", type: "researcher", description: "Research", status: "running", activity: "Working", startedAt: now.timeIntervalSince1970)]
        try save(session, paths: paths)
        let first = read(paths)
        #expect(first.chats["s:claude:many"]?.count == 40)
        #expect(first.fullChats["s:claude:many"]?.count == 400)
        #expect(first.fullChats["s:claude:many"]?.first?.text == "Message 50")
        try append("{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Output\"}]}}\n", to: transcript)
        let growth = read(paths, after: first, at: now.addingTimeInterval(1))
        #expect(Set(growth.flows.keys) == ["s:claude:many", "a:child"])
        #expect(growth.fullChats["s:claude:many"]?.last?.text == "Output")
    }
}
