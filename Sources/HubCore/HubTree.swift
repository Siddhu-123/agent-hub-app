import Foundation

public struct HubNode: Identifiable, Equatable, Sendable {
    public enum Role: String, Sendable { case main, subagent, worker, broker, check }
    public var id: String
    public var role: Role
    public var title: String
    public var subtitle: String
    public var status: String
    public var activity: String
    public var active: Bool
    public var startedAt: Date?
    public var jobId: String?
    public var lines: [String]
    public var children: [HubNode]

    public init(id: String, role: Role, title: String, subtitle: String, status: String, activity: String,
                active: Bool, startedAt: Date? = nil, jobId: String? = nil, lines: [String] = [], children: [HubNode] = []) {
        self.id = id; self.role = role; self.title = title; self.subtitle = subtitle; self.status = status
        self.activity = activity; self.active = active; self.startedAt = startedAt; self.jobId = jobId
        self.lines = lines; self.children = children
    }
}

public enum HubTree {
    private static func date(_ value: Double?) -> Date? { value.map(Date.init(timeIntervalSince1970:)) }
    private static func clipped(_ value: String, _ limit: Int) -> String {
        value.count <= limit ? value : String(value.prefix(limit - 1)) + "…"
    }
    private static func path(_ value: String) -> String { URL(fileURLWithPath: value).standardizedFileURL.path }

    public static func build(sessions: [LiveSession], jobs: [Job], modelHarness: [String: String], now: Date) -> [HubNode] {
        let eligibleJobs = jobs.filter { job in
            job.state == .queued || job.state == .running || job.finished.map { let age = now.timeIntervalSince($0); return age >= 0 && age <= 1800 } == true
        }
        var owners: [String: String] = [:]
        for job in eligibleJobs {
            if let parent = job.parentSession,
               let session = sessions.first(where: { "\($0.platform):\($0.sessionId)" == parent }) {
                owners[job.id] = "s:\(session.platform):\(session.sessionId)"
            } else if let harness = job.mainModel.flatMap({ modelHarness[$0] }) {
                let candidates = sessions.filter { $0.platform == harness && !($0.cwd ?? "").isEmpty && path($0.cwd ?? "") == path(job.project) }
                if let newest = candidates.max(by: { $0.updatedAt < $1.updatedAt }) {
                    owners[job.id] = "s:\(newest.platform):\(newest.sessionId)"
                }
            }
        }
        let liveRoots = sessions.filter { session in
            let age = now.timeIntervalSince1970 - session.updatedAt
            let fresh = age >= 0 && age <= 1800
            let busy = ["working", "waiting"].contains(session.status)
            let activeJob = eligibleJobs.contains { ($0.state == .queued || $0.state == .running) && owners[$0.id] == "s:\(session.platform):\(session.sessionId)" }
            return busy || fresh || activeJob
        }.sorted { a, b in
            let aBusy = a.status == "working" || a.status == "waiting", bBusy = b.status == "working" || b.status == "waiting"
            if aBusy != bBusy { return aBusy }
            return a.updatedAt > b.updatedAt
        }
        func jobNode(_ job: Job) -> HubNode {
            var children: [HubNode] = []
            if let broker = job.broker {
                children.append(HubNode(id: "b:\(job.id)", role: .broker, title: broker, subtitle: "mask · decode", status: job.state.rawValue, activity: "", active: job.state == .running, startedAt: job.started))
            }
            let gateStatus = job.gate.map { $0.passed(for: job.kind) ? "passed" : "failed" } ?? "pending"
            children.append(HubNode(id: "c:\(job.id)", role: .check, title: job.checkArgv.joined(separator: " ").isEmpty ? "check" : clipped(job.checkArgv.joined(separator: " "), 60), subtitle: "", status: gateStatus, activity: "", active: false, startedAt: job.finished ?? job.started))
            return HubNode(id: "j:\(job.id)", role: .worker, title: job.model ?? "waiting for a worker", subtitle: clipped(job.objective, 160), status: job.state.rawValue, activity: job.note ?? "", active: job.state == .running, startedAt: job.started ?? job.created, jobId: job.id, children: children)
        }
        var roots = liveRoots.map { session -> HubNode in
            let id = "s:\(session.platform):\(session.sessionId)"
            let agents = (session.agents ?? []).sorted { $0.startedAt > $1.startedAt }.map { agent in
                HubNode(id: "a:\(agent.id)", role: .subagent, title: agent.type, subtitle: agent.description, status: agent.status, activity: agent.activity, active: agent.status == "running", startedAt: date(agent.startedAt), lines: (agent.recent ?? []).map(\.text))
            }
            let children = eligibleJobs.filter { owners[$0.id] == id }.sorted { $0.created > $1.created }.prefix(8).map(jobNode)
            return HubNode(id: id, role: .main, title: session.model ?? session.platform, subtitle: session.title,
                           status: session.status, activity: session.activity, active: session.status == "working",
                           startedAt: date(session.startedAt), lines: (session.recent ?? []).map(\.text),
                           children: agents + children)
        }
        let rootIds = Set(roots.map(\.id))
        let orphans = eligibleJobs.filter { owners[$0.id] == nil || !rootIds.contains(owners[$0.id]!) }.sorted { $0.created > $1.created }.prefix(8)
        if !orphans.isEmpty {
            roots.append(HubNode(id: "orphans", role: .main, title: "Unattached jobs", subtitle: "", status: "", activity: "", active: false,
                                 children: orphans.map(jobNode)))
        }
        return roots
    }
}
