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

    /// Called with each batch of new log lines (already timestamped), e.g. for notifications.
    public var onLog: (([String]) -> Void)?

    public let paths: HubPaths
    /// Absolute path of the bundled agenthubctl.
    public let ctlPath: String
    private var timer: Timer?

    public init(paths: HubPaths = HubPaths(), ctlPath: String) {
        self.paths = paths
        self.ctlPath = ctlPath
        let loaded = ConfigStore.load(paths)
        self.config = loaded.config
        self.configWarning = loaded.warning
        self.hookStatus = installer.status()
    }

    public var installer: HookInstaller { HookInstaller(ctlPath: ctlPath) }

    /// Starts the 30-second tick timer and ticks once.
    public func start() {
        guard timer == nil else { return }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
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
        explain = PolicyEngine.explain(snapshot(now: now))
        hookStatus = installer.status()
        lastTick = now
    }

    /// Validates, enqueues and ticks. Returns the stored job. ENGINE WORKER.
    @discardableResult
    public func delegate(_ job: Job) throws -> Job {
        throw HubError.invalid("delegate is not implemented yet")
    }

    /// Opens a new main session for modelId in project (Terminal launch script). ENGINE WORKER.
    public func startMain(modelId: String, project: String) throws {
        throw HubError.invalid("startMain is not implemented yet")
    }

    /// Sends a message to a live session's inbox. ENGINE WORKER.
    public func send(session: MainSession, text: String, kind: MessageKind = .message) throws {
        throw HubError.invalid("send is not implemented yet")
    }

    /// Hands a session over now: writes the automatic handoff file and launches modelId (nil = policy's best main). ENGINE WORKER.
    @discardableResult
    public func handoff(session: MainSession, to modelId: String?) throws -> HandoffRecord {
        throw HubError.invalid("handoff is not implemented yet")
    }

    /// Sends a wrap_up message to the session now. ENGINE WORKER.
    public func wrapUpNow(session: MainSession) throws {
        throw HubError.invalid("wrapUpNow is not implemented yet")
    }

    /// ENGINE WORKER.
    public func cancel(jobId: String) {}

    /// Merges a verified worktree job. ENGINE WORKER.
    public func merge(jobId: String) throws {
        throw HubError.invalid("merge is not implemented yet")
    }

    /// Enqueues a copy of the job with a new id and no worker. ENGINE WORKER.
    @discardableResult
    public func rerun(jobId: String) throws -> Job {
        throw HubError.invalid("rerun is not implemented yet")
    }

    public func saveConfig(_ c: AppConfig) throws {
        try ConfigStore.save(c, paths)
        config = c
        configWarning = nil
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
