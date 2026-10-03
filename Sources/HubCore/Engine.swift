import Foundation
import Combine

/// The app's state and control surface (SPEC §7). The public API below is fixed: the UI is built against it.
/// Bodies marked "ENGINE WORKER" are filled in once Relay and Runner are merged.
@MainActor public final class Engine: ObservableObject {
    @Published public private(set) var config: AppConfig
    @Published public private(set) var usage: [String: UsageReading] = [:]
    /// Live main sessions (not ended, not handed off, seen within activeSeconds).
    @Published public private(set) var sessions: [MainSession] = []
    /// All jobs, newest first.
    @Published public private(set) var jobs: [Job] = []
    /// Newest first.
    @Published public private(set) var handoffs: [HandoffRecord] = []
    /// Newest last, capped at 200 lines.
    @Published public private(set) var log: [String] = []
    @Published public private(set) var explain: [String] = []
    @Published public private(set) var configWarning: String?
    /// HookInstaller.status() result.
    @Published public private(set) var hookStatus: [String: Bool] = [:]
    @Published public private(set) var lastTick: Date?
    @Published public private(set) var liveSessions: [LiveSession] = []
    @Published public private(set) var liveRequests: [LiveRequest] = []

    public let live: LiveFeed

    /// Called with each batch of new log lines (already timestamped), e.g. for notifications.
    public var onLog: (([String]) -> Void)?

    public let paths: HubPaths
    /// Absolute path of the bundled agenthubctl.
    public let ctlPath: String
    private var timer: Timer?
    private var pulseTimer: Timer?

    private let exec: Runner.Exec?
    private let openScript: (@Sendable (URL) -> Bool)?
    private let push: (@Sendable ([String]) -> Bool)?
    private let interrupt: (@Sendable (Int32) -> Void)?

    private var inFlight: Set<String> = []

    private lazy var runner: Runner = {
        let r = Runner(paths: paths, config: config)
        if let e = exec { r.exec = e }
        return r
    }()

    public init(paths: HubPaths = HubPaths(), ctlPath: String, exec: Runner.Exec? = nil, openScript: (@Sendable (URL) -> Bool)? = nil, push: (@Sendable ([String]) -> Bool)? = nil, interrupt: (@Sendable (Int32) -> Void)? = nil) {
        self.paths = paths
        self.ctlPath = ctlPath
        self.live = LiveFeed(paths: paths)
        self.exec = exec
        self.openScript = openScript
        self.push = push
        self.interrupt = interrupt
        let loaded = ConfigStore.load(paths)
        self.config = loaded.config
        self.configWarning = loaded.warning
        self.hookStatus = HookInstaller(ctlPath: ctlPath).status()
    }

    public var installer: HookInstaller { HookInstaller(ctlPath: ctlPath) }

    private func relay(now: Date) -> Relay {
        let currentJobs = self.jobs
        return Relay(paths: paths, config: config, ctlPath: ctlPath, push: push, openScript: openScript, interrupt: interrupt, usageProvider: { [usage] in usage }, recentJobs: { project in
            return currentJobs.filter { $0.project == project }.prefix(5).map { "\($0.id) \($0.state.rawValue) \($0.objective.prefix(60))" }
        })
    }

    /// Starts the 30-second tick timer, 2-second pulse timer and ticks/pulses once.
    public func start() {
        guard timer == nil else { return }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        pulse()
        let pTimer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pulse() }
        }
        RunLoop.current.add(pTimer, forMode: .common)
        pulseTimer = pTimer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        pulseTimer?.invalidate()
        pulseTimer = nil
        live.markStopped()
    }

    public func pulse() {
        let s = snapshot()
        var bands: [String: String] = [:]
        for h in config.harnesses {
            bands[h.id] = String(describing: PolicyEngine.band(s, h.id))
        }
        live.writeHeartbeat(jobs: s.jobs, usage: usage, bands: bands, hooks: hookStatus)

        let feed = live
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let newSessions = feed.sessions().sorted { ($0.startedAt, $0.sessionId) < ($1.startedAt, $1.sessionId) }
            let newRequests = feed.requests().sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if !self.sessionsEqual(self.liveSessions, newSessions) {
                    self.liveSessions = newSessions
                }
                if !self.requestsEqual(self.liveRequests, newRequests) {
                    self.liveRequests = newRequests
                }
            }
        }
    }

    private func sessionsEqual(_ a: [LiveSession], _ b: [LiveSession]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            if x.sessionId != y.sessionId || x.platform != y.platform || x.status != y.status ||
               x.activity != y.activity || x.steps != y.steps || x.title != y.title ||
               x.model != y.model || x.cwd != y.cwd || x.turnStartedAt != y.turnStartedAt ||
               x.updatedAt != y.updatedAt {
                return false
            }
        }
        return true
    }

    private func requestsEqual(_ a: [LiveRequest], _ b: [LiveRequest]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            if x.id != y.id || x.kind != y.kind || x.title != y.title || x.detail != y.detail ||
               x.canAnswer != y.canAnswer || x.options != y.options || x.choices != y.choices ||
               x.header != y.header || x.createdAt != y.createdAt {
                return false
            }
        }
        return true
    }

    public func respond(_ request: LiveRequest, decision: String) {
        live.respond(requestId: request.id, decision: decision)
        liveRequests.removeAll { $0.id == request.id }
    }

    public func snapshot(now: Date = Date()) -> Snapshot {
        Snapshot(config: config, usage: usage, sessions: sessions,
                 jobs: jobs.filter { $0.state == .queued || $0.state == .running }, now: now)
    }

    public func band(_ harness: String) -> Band { PolicyEngine.band(snapshot(), harness) }
    public func sessionCap(_ harness: String) -> Int { PolicyEngine.sessionCap(snapshot(), harness) }
    public func workerCap(_ harness: String) -> Int { PolicyEngine.workerCap(snapshot(), harness) }
    public func canStartMain(_ modelId: String) -> (ok: Bool, reason: String) { PolicyEngine.canStartMain(snapshot(), modelId) }

    /// One policy cycle (SPEC §7 tick). schedule: false skips starting queued jobs (used by `agenthubctl tick`). ENGINE WORKER.
    public func tick(now: Date = Date(), schedule: Bool = true) {
        usage = UsageMeter(paths: paths).read(config, now: now)
        Activity.usage(usage, paths: paths, now: now)

        let rel = relay(now: now)
        sessions = rel.sessions(activeOnly: true, now: now)
        jobs = JobStore(paths: paths).all()

        if let hFiles = try? FileManager.default.contentsOfDirectory(atPath: paths.handoffs.path) {
            handoffs = hFiles.filter { $0.hasSuffix(".json") }
                .compactMap { FileStore.read(HandoffRecord.self, from: paths.handoffs.appendingPathComponent($0)) }
                .sorted { $0.created > $1.created }
        } else {
            handoffs = []
        }

        let warnedSet = Set(sessions.compactMap { $0.warned != nil ? $0.id : nil })
        let actions = PolicyEngine.rebalance(snapshot(now: now), alreadyWarned: warnedSet)
        appendLog(rel.apply(actions, now: now), now: now)
        sessions = rel.sessions(activeOnly: true, now: now)

        if schedule {
            let queued = jobs.filter { $0.state == .queued }.sorted { $0.created < $1.created }
            for job in queued {
                if inFlight.contains(job.id) { continue }

                let snap = snapshot(now: now)
                let runningCount = jobs.filter { $0.state == .running || inFlight.contains($0.id) }.count
                if runningCount >= config.limits.maxJobs { break }

                guard let plan = PolicyEngine.plan(snap, job) else {
                    break
                }
                let worker = plan.worker

                inFlight.insert(job.id)
                // Count the job against its worker's harness for the rest of this pass.
                if let i = jobs.firstIndex(where: { $0.id == job.id }) {
                    jobs[i].state = .running
                    jobs[i].harness = worker.harness
                    jobs[i].model = worker.id
                    jobs[i].broker = plan.broker?.id
                }
                var startJob = job
                startJob.broker = plan.broker?.id
                let r = runner
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let finalJob = r.start(startJob, worker: worker, now: Date())
                    Task { @MainActor in
                        guard let self = self else { return }
                        self.inFlight.remove(finalJob.id)
                        var logLine = ""
                        switch finalJob.state {
                        case .verified:
                            logLine = "job verified: \(finalJob.id) \(finalJob.model ?? "")"
                        case .needsReview:
                            var reason = ""
                            if let gate = finalJob.gate {
                                if !gate.outsideAllowed.isEmpty {
                                    reason = "outsideAllowed: \(gate.outsideAllowed.joined(separator: ", "))"
                                } else if !gate.acceptance.passed {
                                    reason = "exit code \(gate.acceptance.exitCode)"
                                } else if finalJob.kind == .implement && gate.changedFiles.isEmpty {
                                    reason = "no files changed"
                                }
                            }
                            logLine = "job needs review: \(finalJob.id) (\(reason))"
                        case .failed:
                            let note = String((finalJob.note ?? finalJob.output ?? "").prefix(120))
                            logLine = "job failed: \(finalJob.id) \(note)"
                        case .queued:
                            logLine = "job requeued: \(finalJob.id)"
                        default:
                            break
                        }
                        if !logLine.isEmpty {
                            self.appendLog([logLine], now: Date())
                        }
                        self.jobs = JobStore(paths: self.paths).all()
                    }
                }
            }
        }

        explain = PolicyEngine.explain(snapshot(now: now))
        hookStatus = installer.status()
        lastTick = now

        let heartbeat: [String: Any] = [
            "heartbeat": ISO8601DateFormatter().string(from: now),
            "pid": getpid()
        ]
        if let data = try? JSONSerialization.data(withJSONObject: heartbeat) {
            try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
            let engineJson = paths.root.appendingPathComponent("engine.json")
            try? data.write(to: engineJson)
        }
    }

    /// Validates, enqueues and ticks. Returns the stored job. ENGINE WORKER.
    @discardableResult
    public func delegate(_ job: Job) throws -> Job {
        let stored = try JobStore(paths: paths).enqueue(job)
        Activity.queued(stored, paths: paths)
        appendLog(["job queued: \(stored.id)"])
        tick()
        return stored
    }

    /// Opens a new main session for modelId in project (Terminal launch script). ENGINE WORKER.
    public func startMain(modelId: String, project: String) throws {
        let check = canStartMain(modelId)
        if !check.ok { throw HubError.noCapacity(check.reason) }

        let id = UUID().uuidString.lowercased()
        let file = paths.handoffs.appendingPathComponent("start-\(id).md")
        let content = "# New main session\nProject: \(project)\nStart fresh; read the project's README/AGENTS.md first."
        try FileManager.default.createDirectory(at: paths.handoffs, withIntermediateDirectories: true)
        try content.write(to: file, atomically: true, encoding: .utf8)

        _ = try relay(now: Date()).handoff(from: "app", session: nil, project: project, file: file.path, to: modelId, launch: true, automatic: false, now: Date())
        appendLog(["started: \(modelId) in \(project)"])
        tick(schedule: false)
    }

    /// Sends a message to a live session's inbox. ENGINE WORKER.
    public func send(session: MainSession, text: String, kind: MessageKind = .message) throws {
        _ = try relay(now: Date()).send(session.harness, session.sessionId, text, kind: kind, now: Date())
        appendLog(["sent: \(kind.rawValue) to \(session.harness) \(session.sessionId.prefix(8))"])
    }

    /// Hands a session over now: writes the automatic handoff file and launches modelId (nil = policy's best main). ENGINE WORKER.
    @discardableResult
    public func handoff(session: MainSession, to modelId: String?) throws -> HandoffRecord {
        let rel = relay(now: Date())
        let text = rel.autoHandoffText(session, now: Date())
        let unix = Int(Date().timeIntervalSince1970)
        let fileName = "manual-\(FileStore.key(session.harness, session.sessionId))-\(unix).md"
        let file = paths.handoffs.appendingPathComponent(fileName)
        try FileManager.default.createDirectory(at: paths.handoffs, withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)

        let record = try rel.handoff(from: session.harness, session: session.sessionId, project: session.cwd, file: file.path, to: modelId, launch: true, automatic: false, now: Date())
        appendLog(["handoff: \(session.harness) session \(session.sessionId.prefix(8)) → \(record.toModel) (manual)"])
        tick(schedule: false)
        return record
    }

    /// Sends a wrap_up message to the session now. ENGINE WORKER.
    public func wrapUpNow(session: MainSession) throws {
        let snap = snapshot(now: Date())
        let target = PolicyEngine.bestMain(snap, excludingHarness: session.harness, planned: [:])
        let actions: [PolicyAction] = [.wrapUp(session: session, target: target, reason: "manual")]
        appendLog(relay(now: Date()).apply(actions, now: Date()), now: Date())
    }

    /// ENGINE WORKER.
    public func cancel(jobId: String) {
        runner.cancel(jobId)
        appendLog(["job cancelled: \(jobId)"])
        jobs = JobStore(paths: paths).all()
    }

    /// Merges a verified worktree job. ENGINE WORKER.
    public func merge(jobId: String) throws {
        guard let job = JobStore(paths: paths).get(jobId) else { throw HubError.invalid("job not found") }
        try runner.mergeWorktree(job)
        var j = job
        j.note = "merged"
        try JobStore(paths: paths).save(j)
        appendLog(["job merged: \(jobId)"])
        jobs = JobStore(paths: paths).all()
    }

    /// Enqueues a copy of the job with a new id and no worker. ENGINE WORKER.
    @discardableResult
    public func rerun(jobId: String) throws -> Job {
        guard let job = JobStore(paths: paths).get(jobId) else { throw HubError.invalid("job not found") }
        var j = job
        j.harness = nil
        j.model = nil
        j.started = nil
        j.finished = nil
        j.gate = nil
        j.output = nil
        j.attempts = []
        j.worktree = nil
        j.branch = nil
        j.note = nil
        return try delegate(j)
    }

    public func saveConfig(_ c: AppConfig) throws {
        try ConfigStore.save(c, paths)
        config = c
        configWarning = nil
        runner.config = c
        tick()
    }

    @discardableResult
    public func installHooks() throws -> [String] {
        defer { hookStatus = installer.status() }
        return try installer.install()
    }

    @discardableResult
    public func installStatusLine(force: Bool) throws -> String { try installer.installStatusLine(force: force) }

    public func installCLI() throws { try installer.installCLILink() }

    public func uninstallHooks() throws {
        defer { hookStatus = installer.status() }
        try installer.uninstall()
    }

    func appendLog(_ lines: [String], now: Date = Date()) {
        guard !lines.isEmpty else { return }
        let stamp = ISO8601DateFormatter().string(from: now)
        let stamped = lines.map { "\(stamp) \($0)" }
        log.append(contentsOf: stamped)
        onLog?(stamped)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}
