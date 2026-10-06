import Foundation

public struct Snapshot {
    public var config: AppConfig
    public var usage: [String: UsageReading]
    public var sessions: [MainSession] /*live, not handed off*/
    public var jobs: [Job] /*queued+running*/
    public var now: Date
    /// Active cooldowns (`model:`, `account:`, `harness:` keys) so routing never picks a cooled worker.
    public var cooldowns: [String: Date]
    
    public init(config: AppConfig, usage: [String: UsageReading], sessions: [MainSession], jobs: [Job], now: Date, cooldowns: [String: Date] = [:]) {
        self.config = config
        self.usage = usage
        self.sessions = sessions
        self.jobs = jobs
        self.now = now
        self.cooldowns = cooldowns
    }
}

public enum Band: Int, Comparable {
    case exhausted, wrapUp, single, reduced, healthy
    public static func < (lhs: Band, rhs: Band) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

public enum PolicyAction: Equatable {
    case wrapUp(session: MainSession, target: ModelEntry?, reason: String)
    case autoHandoff(session: MainSession, target: ModelEntry)
    case notify(String)
}

public enum PolicyEngine {
    private static func mainEntry(_ value: String?, in config: AppConfig, session: String? = nil) -> ModelEntry? {
        let preferred = session.flatMap { $0.split(separator: ":", maxSplits: 1).first.map(String.init) }
        return value.flatMap { config.model($0, harness: preferred) }
    }
    public static func left(_ s: Snapshot, _ harness: String) -> Double? {
        guard let reading = s.usage[harness] else { return nil }
        if let coolingUntil = reading.coolingUntil, coolingUntil > s.now { return 0.0 }
        return reading.left
    }
    
    public static func band(_ s: Snapshot, _ harness: String) -> Band {
        guard let L = left(s, harness) else { return .healthy }
        let lim = s.config.limits
        if L <= lim.exhaustedAtOrBelow { return .exhausted }
        if L < max(lim.wrapUpBelow, lim.wrapUpReserve) { return .wrapUp }
        if L < lim.singleSessionBelow { return .single }
        if L < lim.sameHarnessMinLeft { return .reduced }
        return .healthy
    }
    
    public static func sessionCap(_ s: Snapshot, _ harness: String) -> Int {
        switch band(s, harness) {
        case .healthy, .reduced: return s.config.limits.maxMainSessions
        case .single: return 1
        case .wrapUp, .exhausted: return 0
        }
    }
    
    public static func canStartMain(_ s: Snapshot, _ modelId: String, harness: String? = nil) -> (ok: Bool, reason: String) {
        guard let model = s.config.model(modelId, harness: harness) else {
            let matches = s.config.models.filter { $0.id == modelId }
            return (false, matches.count > 1 ? "Ambiguous model '\(modelId)'; choose \(matches.map(\.qualifiedID).sorted().joined(separator: ", "))" : "Model not found")
        }
        guard model.enabled else { return (false, "Model is disabled") }
        guard model.isMain else { return (false, "Model is not a main model") }
        if occupying(s).count >= s.config.limits.maxMainSessions { return (false, "Global maxMainSessions exceeded") }
        if s.sessions.filter({ $0.harness == model.harness }).count >= sessionCap(s, model.harness) {
            return (false, "Harness session cap reached")
        }
        return (true, "")
    }
    
    /// Sessions that hold a global main-session slot. A session whose harness is in wrap-up or
    /// exhausted is on its way out, so its slot is free for the session that takes over. A session
    /// idle for longer than `idleSlotGrace` spends no usage, so it does not hold a slot either.
    public static func occupying(_ s: Snapshot) -> [MainSession] {
        s.sessions.filter { band(s, $0.harness) > .wrapUp
            && !($0.status == .idle && s.now.timeIntervalSince($0.lastSeen) > idleSlotGrace) }
    }

    public static let idleSlotGrace: TimeInterval = 120

    /// When the model can next run, if every account/model route for it is cooling down.
    public static func coolingUntil(_ s: Snapshot, _ model: ModelEntry) -> Date? {
        func active(_ key: String) -> Date? { s.cooldowns[key].flatMap { $0 > s.now ? $0 : nil } }
        if let h = active("harness:\(model.harness)") { return h }
        guard let harness = s.config.harness(model.harness) else { return nil }
        if harness.accounts.isEmpty { return active("model:\(model.qualifiedID)") }
        let until = harness.accounts.map { active("account:\($0)") }
        return until.contains { $0 == nil } ? nil : until.compactMap { $0 }.min()
    }

    /// Earliest time the harness's limiting usage window (or cooldown) resets.
    public static func resetsAt(_ s: Snapshot, _ harness: String) -> Date? {
        guard let reading = s.usage[harness] else { return nil }
        if let c = reading.coolingUntil, c > s.now { return c }
        let limiting = reading.windows.filter { $0.usedPercent >= 100 * (1 - (reading.left ?? 0)) - 0.5 }
        return limiting.compactMap(\.resetsAt).filter { $0 > s.now }.min()
    }

    /// Project jobs may use this worker without the masked pipeline.
    static func directProjectOK(_ s: Snapshot, _ model: ModelEntry) -> Bool {
        s.config.harness(model.harness)?.trusted == true || s.config.allowsZDRProjectJob(model)
    }

    public static func minIntelligence(_ size: JobSize, _ kind: JobKind, lim: Limits) -> Int {
        let sInt = lim.minIntelligence[size.rawValue] ?? 0
        let kInt = kind == .implement ? 0 : (lim.minIntelligence[kind.rawValue] ?? 0)
        return max(sInt, kInt)
    }
    
    public static func workerCap(_ s: Snapshot, _ harness: String) -> Int {
        switch band(s, harness) {
        case .healthy: return s.config.limits.maxJobs
        case .reduced:
            if let L = left(s, harness), L >= s.config.limits.workerMinLeft { return 1 }
            return 0
        default: return 0
        }
    }
    
    public static func pickWorker(_ s: Snapshot, _ size: JobSize, _ kind: JobKind, _ privacy: Privacy, mainModel: String?, requestedWorker: String? = nil, mainSession: String? = nil) -> ModelEntry? {
        let running = s.jobs.filter { $0.state == .running }
        if running.count >= s.config.limits.maxJobs { return nil }
        let minInt = minIntelligence(size, kind, lim: s.config.limits)
        
        var candidates: [ModelEntry] = []
        let requested = requestedWorker.flatMap { s.config.model($0) }
        for model in s.config.models {
            guard (model.enabled || model.qualifiedID == requested?.qualifiedID) && model.isWorker && model.intelligence >= minInt else { continue }
            if let requested, model.qualifiedID != requested.qualifiedID { continue }
            guard s.config.harness(model.harness) != nil else { continue }
            if privacy == .project && !directProjectOK(s, model) { continue }
            if running.filter({ $0.harness == model.harness }).count >= workerCap(s, model.harness) { continue }
            if coolingUntil(s, model) != nil { continue }
            
            var mainHarness: String? = nil
            if let mm = mainEntry(mainModel, in: s.config, session: mainSession) { mainHarness = mm.harness }
            if model.harness == mainHarness {
                if let L = left(s, model.harness), L < s.config.limits.sameHarnessMinLeft { continue }
            }
            candidates.append(model)
        }
        
        var mainHarness: String? = nil
        if let mm = mainEntry(mainModel, in: s.config, session: mainSession) { mainHarness = mm.harness }
        
        candidates.sort { a, b in
            // Free workers first: paid harnesses otherwise drain each other's quota on jobs a free model can do.
            if a.free != b.free { return a.free }
            let aSame = a.harness == mainHarness
            let bSame = b.harness == mainHarness
            if aSame != bSame { return !aSame }
            if a.intelligence != b.intelligence { return a.intelligence < b.intelligence }
            let aLeft = left(s, a.harness) ?? 0.5
            let bLeft = left(s, b.harness) ?? 0.5
            if aLeft != bLeft { return aLeft > bLeft }
            let aJobs = running.filter { $0.harness == a.harness }.count
            let bJobs = running.filter { $0.harness == b.harness }.count
            if aJobs != bJobs { return aJobs < bJobs }
            return a.qualifiedID < b.qualifiedID
        }
        return candidates.first
    }
    
    /// `explicit`: the caller asked for masking (`--offload always`); when no model is in the broker range,
    /// the least capable trusted worker not opted out (`brokerEligible: false`) brokers instead of skipping the pipeline.
    public static func pickBroker(_ s: Snapshot, mainModel: String?, mainSession: String? = nil, explicit: Bool = false) -> ModelEntry? {
        if let b = pickBroker(s, mainModel: mainModel, mainSession: mainSession, fallback: false) { return b }
        return explicit ? pickBroker(s, mainModel: mainModel, mainSession: mainSession, fallback: true) : nil
    }

    private static func pickBroker(_ s: Snapshot, mainModel: String?, mainSession: String?, fallback: Bool) -> ModelEntry? {
        var candidates: [ModelEntry] = []
        for model in s.config.models {
            guard model.enabled && model.isWorker else { continue }
            let eligible = fallback ? model.brokerEligible != false : (model.brokerEligible ??
                (model.intelligence >= s.config.limits.brokerMinIntelligence && model.intelligence <= s.config.limits.brokerMaxIntelligence))
            guard eligible else { continue }
            guard let harness = s.config.harness(model.harness) else { continue }
            guard harness.trusted else { continue }
            guard workerCap(s, model.harness) > 0 else { continue }
            let b = band(s, model.harness)
            guard b != .exhausted && b != .wrapUp else { continue }
            if coolingUntil(s, model) != nil { continue }
            candidates.append(model)
        }
        
        var mainHarness: String? = nil
        if let mm = mainEntry(mainModel, in: s.config, session: mainSession) { mainHarness = mm.harness }
        
        candidates.sort { a, b in
            let aSame = a.harness == mainHarness
            let bSame = b.harness == mainHarness
            if aSame != bSame { return !aSame }
            if a.intelligence != b.intelligence { return fallback ? a.intelligence < b.intelligence : a.intelligence > b.intelligence }
            let aLeft = left(s, a.harness) ?? 0.5
            let bLeft = left(s, b.harness) ?? 0.5
            if aLeft != bLeft { return aLeft > bLeft }
            return a.qualifiedID < b.qualifiedID
        }
        return candidates.first
    }

    public static func plan(_ s: Snapshot, _ job: Job) -> (worker: ModelEntry, broker: ModelEntry?)? {
        if let requestedWorker = job.requestedWorker {
            guard let worker = s.config.model(requestedWorker), worker.isWorker else { return nil }
            guard let harness = s.config.harness(worker.harness) else { return nil }
            let shouldMask = job.privacy == .project && job.kind == .implement &&
                (job.offload == true || (job.offload != false && s.config.limits.maskedOffloadSizes.contains(job.size.rawValue)))
            if shouldMask {
                let running = s.jobs.filter { $0.state == .running }
                guard !harness.trusted, worker.free,
                      worker.enabled || worker.qualifiedID == requestedWorker,
                      worker.intelligence >= minIntelligence(job.size, job.kind, lim: s.config.limits),
                      running.count < s.config.limits.maxJobs,
                      running.filter({ $0.harness == worker.harness }).count < workerCap(s, worker.harness),
                      coolingUntil(s, worker) == nil,
                      let broker = pickBroker(s, mainModel: job.mainModel, mainSession: job.parentSession, explicit: job.offload == true) else { return nil }
                return (worker, broker)
            }
            guard let selected = pickWorker(s, job.size, job.kind, job.privacy, mainModel: job.mainModel, requestedWorker: requestedWorker, mainSession: job.parentSession) else { return nil }
            return (selected, nil)
        }
        if job.privacy == .project && job.offload != false && (job.offload == true || s.config.limits.maskedOffloadSizes.contains(job.size.rawValue)) && job.kind == .implement {
            if let broker = pickBroker(s, mainModel: job.mainModel, mainSession: job.parentSession, explicit: job.offload == true) {
                let running = s.jobs.filter { $0.state == .running }
                if running.count < s.config.limits.maxJobs {
                    var candidates: [ModelEntry] = []
                    for model in s.config.models {
                        guard model.enabled && model.isWorker && model.free else { continue }
                        guard let harness = s.config.harness(model.harness) else { continue }
                        guard !harness.trusted else { continue }
                        if running.filter({ $0.harness == model.harness }).count >= workerCap(s, model.harness) { continue }
                        if coolingUntil(s, model) != nil { continue }
                        if job.maskedTried?.contains(model.qualifiedID) == true { continue }
                        candidates.append(model)
                    }
                    
                    var mainHarness: String? = nil
                    if let mm = mainEntry(job.mainModel, in: s.config, session: job.parentSession) { mainHarness = mm.harness }
                    
                    candidates.sort { a, b in
                        let aSame = a.harness == mainHarness
                        let bSame = b.harness == mainHarness
                        if aSame != bSame { return !aSame }
                        let aLeft = left(s, a.harness) ?? 0.5
                        let bLeft = left(s, b.harness) ?? 0.5
                        if aLeft != bLeft { return aLeft > bLeft }
                        let aJobs = running.filter { $0.harness == a.harness }.count
                        let bJobs = running.filter { $0.harness == b.harness }.count
                        if aJobs != bJobs { return aJobs < bJobs }
                        return a.qualifiedID < b.qualifiedID
                    }
                    
                    if let worker = candidates.first {
                        return (worker: worker, broker: broker)
                    }
                }
            }
        }
        if let worker = pickWorker(s, job.size, job.kind, job.privacy, mainModel: job.mainModel, requestedWorker: job.requestedWorker, mainSession: job.parentSession) {
            return (worker: worker, broker: nil)
        }
        return nil
    }
    
    /// Why `plan` returned nil for this job, and when the earliest blocked route frees up.
    /// Display state: exhausted (harness out of quota or handoff blocked) wins over waiting/running/idle.
    public static func state(_ s: Snapshot, _ session: MainSession) -> SessionState {
        if session.status == .ended { return .ended }
        if band(s, session.harness) == .exhausted || session.handoffBlocked != nil { return .exhausted }
        switch session.status {
        case .waiting: return .waiting
        case .working: return .running
        default: return .idle
        }
    }

    public static func whyQueued(_ s: Snapshot, _ job: Job) -> (reason: String, resetsAt: Date?) {
        let running = s.jobs.filter { $0.state == .running }
        if running.count >= s.config.limits.maxJobs {
            return ("all \(s.config.limits.maxJobs) job slots are busy", nil)
        }
        let minInt = minIntelligence(job.size, job.kind, lim: s.config.limits)
        let requested = job.requestedWorker.flatMap { s.config.model($0) }
        if job.requestedWorker != nil && requested == nil { return ("requested worker \(job.requestedWorker!) is not configured", nil) }
        let mainHarness = mainEntry(job.mainModel, in: s.config, session: job.parentSession)?.harness
        var reasons: [String] = []
        var resets: [Date] = []
        for model in s.config.models where model.isWorker {
            if let requested, model.qualifiedID != requested.qualifiedID { continue }
            if requested == nil && !model.enabled { continue }
            var why: String?
            if model.intelligence < minInt { why = "intelligence \(model.intelligence) < \(minInt)" }
            else if job.privacy == .project && !directProjectOK(s, model) && !(model.free && pickBroker(s, mainModel: job.mainModel, mainSession: job.parentSession, explicit: job.offload == true) != nil) {
                why = "untrusted and not an allowed ZDR worker"
            } else if let until = coolingUntil(s, model) {
                why = "cooling down"; resets.append(until)
            } else if workerCap(s, model.harness) == 0 {
                why = "\(band(s, model.harness)) (\(left(s, model.harness).map { "\(Int($0 * 100))% left" } ?? "usage unknown"))"
                if let r = resetsAt(s, model.harness) { resets.append(r) }
            } else if running.filter({ $0.harness == model.harness }).count >= workerCap(s, model.harness) {
                why = "harness job cap reached"
            } else if model.harness == mainHarness, let L = left(s, model.harness), L < s.config.limits.sameHarnessMinLeft {
                why = "same harness as main below \(Int(s.config.limits.sameHarnessMinLeft * 100))%"
            }
            if let why { reasons.append("\(model.qualifiedID): \(why)") }
        }
        if reasons.isEmpty { reasons.append("no enabled worker matches size \(job.size.rawValue)/\(job.kind.rawValue)") }
        let reset = resets.min()
        let resetText = reset.map { " · next reset \(ISO8601DateFormatter().string(from: $0))" } ?? ""
        return ("no worker available — " + reasons.joined(separator: "; ") + resetText, reset)
    }

    public static func bestMain(_ s: Snapshot, excludingHarness: String?, planned: [String: Int]) -> ModelEntry? {
        var candidates = s.config.models.filter { $0.enabled && $0.isMain }
        if let ex = excludingHarness { candidates.removeAll { $0.harness == ex } }
        
        candidates.removeAll { m in
            let current = s.sessions.filter { $0.harness == m.harness }.count
            let p = planned[m.harness] ?? 0
            return (current + p) >= sessionCap(s, m.harness)
        }
        
        candidates.sort { a, b in
            let aTotal = s.sessions.filter({ $0.harness == a.harness }).count + (planned[a.harness] ?? 0)
            let bTotal = s.sessions.filter({ $0.harness == b.harness }).count + (planned[b.harness] ?? 0)
            if (aTotal == 0) != (bTotal == 0) { return aTotal == 0 }
            if a.intelligence != b.intelligence { return a.intelligence > b.intelligence }
            let aOrder = s.config.mainOrder.firstIndex(of: a.qualifiedID) ?? s.config.mainOrder.firstIndex(of: a.id) ?? Int.max
            let bOrder = s.config.mainOrder.firstIndex(of: b.qualifiedID) ?? s.config.mainOrder.firstIndex(of: b.id) ?? Int.max
            if aOrder != bOrder { return aOrder < bOrder }
            let aLeft = left(s, a.harness) ?? 0.5
            let bLeft = left(s, b.harness) ?? 0.5
            if aLeft != bLeft { return aLeft > bLeft }
            return a.qualifiedID < b.qualifiedID
        }
        return candidates.first
    }
    
    public static func rebalance(_ s: Snapshot, alreadyWarned: Set<String>) -> [PolicyAction] {
        var actions: [PolicyAction] = []
        var planned: [String: Int] = [:]
        var sessionMap: [String: [MainSession]] = [:]
        for session in s.sessions { sessionMap[session.harness, default: []].append(session) }
        
        var keptSessions: [MainSession] = []
        var droppedSessions: [MainSession] = []
        for harness in sessionMap.keys.sorted() {
            let sessions = sessionMap[harness] ?? []
            // Keep the earliest-started sessions. `started` never changes on a hook, so the
            // victim is stable; ordering by lastSeen made each hooking session look newest.
            let sorted = sessions.sorted { ($0.started, $0.id) < ($1.started, $1.id) }
            let cap = sessionCap(s, harness)
            if cap > 0 {
                let keep = min(sorted.count, cap)
                keptSessions.append(contentsOf: sorted.prefix(keep))
                droppedSessions.append(contentsOf: sorted.dropFirst(keep))
            } else {
                droppedSessions.append(contentsOf: sorted)
            }
        }
        
        for session in droppedSessions {
            if alreadyWarned.contains(session.id) { continue }
            let target = bestMain(s, excludingHarness: session.harness, planned: planned)
            actions.append(.wrapUp(session: session, target: target, reason: "usage limit per harness"))
            if let t = target { planned[t.harness, default: 0] += 1 }
        }
        
        keptSessions.sort { a, b in
            let aBand = band(s, a.harness).rawValue
            let bBand = band(s, b.harness).rawValue
            if aBand != bBand { return aBand < bBand }
            return (a.started, a.id) > (b.started, b.id)
        }
        
        while keptSessions.count > s.config.limits.maxMainSessions {
            let session = keptSessions.removeFirst()
            if !alreadyWarned.contains(session.id) {
                let target = bestMain(s, excludingHarness: session.harness, planned: planned)
                actions.append(.wrapUp(session: session, target: target, reason: "global capacity exceeded"))
                if let t = target { planned[t.harness, default: 0] += 1 }
            }
        }
        
        for session in s.sessions {
            if alreadyWarned.contains(session.id) {
                if band(s, session.harness) == .exhausted {
                    // A blocked handoff is retried at most once per grace period, never every tick.
                    if let blockedAt = session.blockedAt, s.now.timeIntervalSince(blockedAt) < s.config.limits.graceSeconds { continue }
                    if let warned = session.warned, s.now.timeIntervalSince(warned) >= s.config.limits.graceSeconds {
                        if let target = bestMain(s, excludingHarness: session.harness, planned: planned) {
                            actions.append(.autoHandoff(session: session, target: target))
                            planned[target.harness, default: 0] += 1
                        }
                    }
                }
            }
        }
        
        var notifiedHarnesses = Set<String>()
        for harness in s.config.harnesses {
            if band(s, harness.id) == .exhausted && s.sessions.contains(where: { $0.harness == harness.id }) && bestMain(s, excludingHarness: harness.id, planned: planned) == nil {
                if !notifiedHarnesses.contains(harness.id) {
                    actions.append(.notify("\(harness.name) usage limit exhausted"))
                    notifiedHarnesses.insert(harness.id)
                }
            }
        }
        return actions
    }
    
    public static func explain(_ s: Snapshot) -> [String] {
        var lines: [String] = []
        for h in s.config.harnesses {
            let L = left(s, h.id)
            let lStr = L == nil ? "unknown" : String(format: "%d%%", Int(L! * 100))
            let b = band(s, h.id)
            let wCap = workerCap(s, h.id)
            
            var text = ""
            switch b {
            case .exhausted: text = "exhausted: 0 main sessions; 0 worker jobs"
            case .wrapUp: text = "wrapUp: 0 main sessions; 0 worker jobs"
            case .single: text = "single: 1 main session max; \(wCap) worker jobs"
            case .reduced: text = "reduced: no same-harness delegation; \(wCap) worker job max"
            case .healthy: text = "healthy: normal capacity"
            }
            lines.append("\(h.name) \(lStr) left → \(text)")
        }
        return lines
    }

    public static func isInternalBackgroundPath(_ cwd: String) -> Bool {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if trimmed == "~/.codex" || trimmed.hasPrefix("~/.codex/") ||
           trimmed == "~/.claude" || trimmed.hasPrefix("~/.claude/") {
            return true
        }

        let homePaths = [
            FileManager.default.homeDirectoryForCurrentUser.path,
            NSHomeDirectory()
        ]

        let expanded = (trimmed as NSString).expandingTildeInPath
        let std = (expanded as NSString).standardizingPath

        for home in homePaths {
            let stdHome = (home as NSString).standardizingPath
            let codexDir = (stdHome as NSString).appendingPathComponent(".codex")
            let claudeDir = (stdHome as NSString).appendingPathComponent(".claude")

            if std == codexDir || std.hasPrefix(codexDir + "/") { return true }
            if std == claudeDir || std.hasPrefix(claudeDir + "/") { return true }
        }
        return false
    }

    public static func isEligibleMainModel(config: AppConfig, harness: String, model: String?) -> Bool {
        config.isEligibleMainModel(harness: harness, model: model)
    }

    public static func isEligibleSession(config: AppConfig, harness: String, model: String?, cwd: String) -> Bool {
        if isInternalBackgroundPath(cwd) { return false }
        return isEligibleMainModel(config: config, harness: harness, model: model)
    }
}
