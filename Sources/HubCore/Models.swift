import Foundation

// Shared contract for every HubCore module. Owned by the orchestrator: workers must not edit this file.
// All persisted JSON uses these Codable types with JSONCoding.encoder/decoder (ISO-8601 dates, sorted keys).

public enum JobSize: String, Codable, CaseIterable, Sendable { case tiny, routine, hard }
public enum JobKind: String, Codable, CaseIterable, Sendable { case implement, review, plan }
/// project: the worker may read the private checkout (trusted harnesses only).
/// generic: a sanitized, self-contained brief (any enabled harness, including free external ones).
public enum Privacy: String, Codable, CaseIterable, Sendable { case project, generic }

public enum UsageSource: String, Codable, CaseIterable, Sendable { case codexSessions, claudeStatusline, manual, none }
public enum HookStyle: String, Codable, CaseIterable, Sendable { case claude, codex, none }

/// A CLI harness (Claude Code, Codex, Antigravity, OpenCode, or anything user-defined).
/// Argument templates use placeholders: {exe} {model} {effort} {project} {prompt} {session} {text}.
public struct Harness: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var executable: String
    /// Extra executables for the same harness (for example one per account). Tried in order after a quota error.
    public var accounts: [String]
    public var trusted: Bool
    public var usageSource: UsageSource
    public var hookStyle: HookStyle
    public var mainArgs: [String]
    public var workerArgs: [String]
    public var promptViaStdin: Bool
    /// Pushes a message into a live session (Codex: queue). nil when the harness has no such command.
    public var queueArgs: [String]?
    /// Manual usage-left value (0...1) for harnesses without a meter; nil means unknown.
    public var manualLeft: Double?

    public init(id: String, name: String, executable: String, accounts: [String] = [], trusted: Bool,
                usageSource: UsageSource, hookStyle: HookStyle, mainArgs: [String], workerArgs: [String],
                promptViaStdin: Bool = false, queueArgs: [String]? = nil, manualLeft: Double? = nil) {
        self.id = id; self.name = name; self.executable = executable; self.accounts = accounts; self.trusted = trusted
        self.usageSource = usageSource; self.hookStyle = hookStyle; self.mainArgs = mainArgs; self.workerArgs = workerArgs
        self.promptViaStdin = promptViaStdin; self.queueArgs = queueArgs; self.manualLeft = manualLeft
    }
}

public struct ModelEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var harness: String
    public var name: String
    /// 0...100. The hierarchy of intelligence used for size thresholds and for choosing the next main model.
    public var intelligence: Int
    public var isMain: Bool
    public var isWorker: Bool
    public var free: Bool
    public var effort: String?
    public var enabled: Bool

    public init(id: String, harness: String, name: String, intelligence: Int, isMain: Bool, isWorker: Bool,
                free: Bool = false, effort: String? = nil, enabled: Bool = true) {
        self.id = id; self.harness = harness; self.name = name; self.intelligence = intelligence
        self.isMain = isMain; self.isWorker = isWorker; self.free = free; self.effort = effort; self.enabled = enabled
    }
}

public struct Limits: Codable, Equatable, Sendable {
    public var maxMainSessions = 2
    public var maxJobs = 4
    /// A main session may delegate to its own harness only while that harness has at least this much left.
    public var sameHarnessMinLeft = 0.40
    /// Below this a harness may host at most one main session; extra sessions move to another harness.
    public var singleSessionBelow = 0.30
    /// Below this the last session on the harness is told to wrap up and hand off.
    public var wrapUpBelow = 0.15
    /// At or below this (or while cooling) the harness is exhausted: the watchdog hands off automatically.
    public var exhaustedAtOrBelow = 0.02
    /// Worker jobs: a harness below this gets no jobs; between this and sameHarnessMinLeft it gets at most one.
    public var workerMinLeft = 0.15
    public var graceSeconds = 600.0
    public var activeSeconds = 900.0
    public var maxStopBlocks = 2
    public var jobTimeoutSeconds = 1200.0
    public var minIntelligence: [String: Int] = ["tiny": 0, "routine": 55, "hard": 75, "review": 80, "plan": 80]
    /// Send SIGINT to the old session's process after an automatic handoff.
    public var interruptOnAutoHandoff = true
    /// Project jobs of these sizes go to a free untrusted worker through the masked pipeline:
    /// a trusted tier-3 broker masks the task, the free worker runs on the masked stage only, the broker decodes the result.
    public var maskedOffloadSizes: [String] = ["hard"]
    public var maskedHeavyAttempts = 2
    /// Tier 3: trusted worker models in this intelligence range may act as the mask/decode broker.
    public var brokerMinIntelligence = 55
    public var brokerMaxIntelligence = 79

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case maxMainSessions, maxJobs, sameHarnessMinLeft, singleSessionBelow, wrapUpBelow, exhaustedAtOrBelow, workerMinLeft
        case graceSeconds, activeSeconds, maxStopBlocks, jobTimeoutSeconds, minIntelligence, interruptOnAutoHandoff
        case maskedOffloadSizes, maskedHeavyAttempts, brokerMinIntelligence, brokerMaxIntelligence
    }

    /// Keys missing from an older config keep their defaults instead of failing the whole file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T { try c.decodeIfPresent(T.self, forKey: key) ?? fallback }
        let d = Limits()
        maxMainSessions = try v(.maxMainSessions, d.maxMainSessions)
        maxJobs = try v(.maxJobs, d.maxJobs)
        sameHarnessMinLeft = try v(.sameHarnessMinLeft, d.sameHarnessMinLeft)
        singleSessionBelow = try v(.singleSessionBelow, d.singleSessionBelow)
        wrapUpBelow = try v(.wrapUpBelow, d.wrapUpBelow)
        exhaustedAtOrBelow = try v(.exhaustedAtOrBelow, d.exhaustedAtOrBelow)
        workerMinLeft = try v(.workerMinLeft, d.workerMinLeft)
        graceSeconds = try v(.graceSeconds, d.graceSeconds)
        activeSeconds = try v(.activeSeconds, d.activeSeconds)
        maxStopBlocks = try v(.maxStopBlocks, d.maxStopBlocks)
        jobTimeoutSeconds = try v(.jobTimeoutSeconds, d.jobTimeoutSeconds)
        minIntelligence = try v(.minIntelligence, d.minIntelligence)
        interruptOnAutoHandoff = try v(.interruptOnAutoHandoff, d.interruptOnAutoHandoff)
        maskedOffloadSizes = try v(.maskedOffloadSizes, d.maskedOffloadSizes)
        maskedHeavyAttempts = try v(.maskedHeavyAttempts, d.maskedHeavyAttempts)
        brokerMinIntelligence = try v(.brokerMinIntelligence, d.brokerMinIntelligence)
        brokerMaxIntelligence = try v(.brokerMaxIntelligence, d.brokerMaxIntelligence)
    }
}

public struct AppConfig: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var harnesses: [Harness]
    public var models: [ModelEntry]
    /// Main model ids in preference order (tie-breaker after intelligence).
    public var mainOrder: [String]
    public var limits = Limits()
    public var autoLaunch = true
    public var terminalApp = "Terminal"

    public init(harnesses: [Harness], models: [ModelEntry], mainOrder: [String], limits: Limits = Limits()) {
        self.harnesses = harnesses; self.models = models; self.mainOrder = mainOrder; self.limits = limits
    }

    public func harness(_ id: String) -> Harness? { harnesses.first { $0.id == id } }
    public func model(_ id: String) -> ModelEntry? { models.first { $0.id == id } }
}

// MARK: usage

public struct UsageWindow: Codable, Equatable, Sendable {
    public var name: String
    public var usedPercent: Double
    public var resetsAt: Date?
    public init(name: String, usedPercent: Double, resetsAt: Date?) { self.name = name; self.usedPercent = usedPercent; self.resetsAt = resetsAt }
}

public struct UsageReading: Codable, Equatable, Sendable {
    /// 0...1 for the tightest window; nil when unknown. 0 while cooling.
    public var left: Double?
    public var windows: [UsageWindow]
    public var source: String
    public var asOf: Date?
    public var coolingUntil: Date?
    public init(left: Double?, windows: [UsageWindow] = [], source: String, asOf: Date? = nil, coolingUntil: Date? = nil) {
        self.left = left; self.windows = windows; self.source = source; self.asOf = asOf; self.coolingUntil = coolingUntil
    }
}

// MARK: sessions and relay

public enum SessionStatus: String, Codable, Sendable { case working, idle, ended }

public struct MainSession: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(harness)-\(sessionId)" }
    public var harness: String
    public var sessionId: String
    public var model: String?
    public var cwd: String
    public var pid: Int32?
    public var started: Date
    public var lastSeen: Date
    public var lastEvent: String
    public var status: SessionStatus
    public var handedOff = false
    public var warned: Date?
    public init(harness: String, sessionId: String, model: String? = nil, cwd: String, pid: Int32? = nil, started: Date,
                lastSeen: Date, lastEvent: String, status: SessionStatus) {
        self.harness = harness; self.sessionId = sessionId; self.model = model; self.cwd = cwd; self.pid = pid
        self.started = started; self.lastSeen = lastSeen; self.lastEvent = lastEvent; self.status = status
    }
}

public enum MessageKind: String, Codable, Sendable { case message, task, wrapUp = "wrap_up" }

public struct InboxMessage: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: MessageKind
    public var text: String
    public var created: Date
    public var delivered: Date?
    public var stopBlocks = 0
    public var done: Date?
    public var pushed = false
    public init(id: String = String(UUID().uuidString.prefix(8)).lowercased(), kind: MessageKind, text: String, created: Date) {
        self.id = id; self.kind = kind; self.text = text; self.created = created
    }
}

public struct HandoffRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var fromHarness: String
    public var fromSession: String?
    public var toModel: String
    public var project: String
    public var file: String
    public var script: String
    public var launched: Bool
    public var automatic: Bool
    public var created: Date
    public init(id: String, fromHarness: String, fromSession: String?, toModel: String, project: String, file: String,
                script: String, launched: Bool, automatic: Bool, created: Date) {
        self.id = id; self.fromHarness = fromHarness; self.fromSession = fromSession; self.toModel = toModel; self.project = project
        self.file = file; self.script = script; self.launched = launched; self.automatic = automatic; self.created = created
    }
}

// MARK: jobs

public enum JobState: String, Codable, Sendable { case queued, running, verified, needsReview = "needs_review", failed, cancelled, blocked }
public enum Isolation: String, Codable, Sendable { case checkout, worktree }

public struct JobAttempt: Codable, Equatable, Sendable {
    public var harness: String
    public var model: String
    public var account: String?
    public var result: String
    public var coolingUntil: Date?
    public init(harness: String, model: String, account: String? = nil, result: String, coolingUntil: Date? = nil) {
        self.harness = harness; self.model = model; self.account = account; self.result = result; self.coolingUntil = coolingUntil
    }
}

public struct CheckResult: Codable, Equatable, Sendable {
    public var argv: [String]
    public var exitCode: Int32
    public var timedOut: Bool
    public var output: String
    public var passed: Bool { exitCode == 0 && !timedOut }
    public init(argv: [String], exitCode: Int32, timedOut: Bool, output: String) {
        self.argv = argv; self.exitCode = exitCode; self.timedOut = timedOut; self.output = output
    }
}

public struct GateResult: Codable, Equatable, Sendable {
    public var acceptance: CheckResult
    public var changedFiles: [String]
    public var outsideAllowed: [String]
    public var passed: Bool { acceptance.passed && outsideAllowed.isEmpty && !changedFiles.isEmpty }
    public init(acceptance: CheckResult, changedFiles: [String], outsideAllowed: [String]) {
        self.acceptance = acceptance; self.changedFiles = changedFiles; self.outsideAllowed = outsideAllowed
    }
}

public struct Job: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var project: String
    public var objective: String
    public var allowedFiles: [String]
    public var checkArgv: [String]
    public var size: JobSize
    public var kind: JobKind
    public var privacy: Privacy
    public var isolation: Isolation
    /// The main model that delegated this job (model id), used for the same-harness rule.
    public var mainModel: String?
    /// Harness-qualified session id of the main session that delegated this job.
    public var parentSession: String?
    public var harness: String?
    public var model: String?
    public var state: JobState
    public var created: Date
    public var started: Date?
    public var finished: Date?
    public var attempts: [JobAttempt] = []
    public var output: String?
    public var gate: GateResult?
    /// Worktree path and branch when isolation == .worktree.
    public var worktree: String?
    public var branch: String?
    public var note: String?
    /// nil: policy decides; true: always use the masked pipeline for a project job; false: never offload.
    public var offload: Bool?
    /// Trusted tier-3 model that masks and decodes a masked-pipeline job (set when the job is scheduled).
    public var broker: String?

    public init(id: String = UUID().uuidString.lowercased(), project: String, objective: String, allowedFiles: [String],
                checkArgv: [String], size: JobSize, kind: JobKind, privacy: Privacy, isolation: Isolation = .checkout,
                mainModel: String? = nil, created: Date) {
        self.id = id; self.project = project; self.objective = objective; self.allowedFiles = allowedFiles
        self.checkArgv = checkArgv; self.size = size; self.kind = kind; self.privacy = privacy; self.isolation = isolation
        self.mainModel = mainModel; self.state = .queued; self.created = created
    }
}

// MARK: JSON

public enum JSONCoding {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }
    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
