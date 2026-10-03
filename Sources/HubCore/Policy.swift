import Foundation

public struct Snapshot {
    public var config: AppConfig
    public var usage: [String: UsageReading]
    public var sessions: [MainSession] /*live, not handed off*/
    public var jobs: [Job] /*queued+running*/
    public var now: Date
    
    public init(config: AppConfig, usage: [String: UsageReading], sessions: [MainSession], jobs: [Job], now: Date) {
        self.config = config
        self.usage = usage
        self.sessions = sessions
        self.jobs = jobs
        self.now = now
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
    public static func left(_ s: Snapshot, _ harness: String) -> Double? {
        guard let reading = s.usage[harness] else { return nil }
        if let coolingUntil = reading.coolingUntil, coolingUntil > s.now { return 0.0 }
        return reading.left
    }
    
    public static func band(_ s: Snapshot, _ harness: String) -> Band {
        guard let L = left(s, harness) else { return .healthy }
        let lim = s.config.limits
        if L <= lim.exhaustedAtOrBelow { return .exhausted }
        if L < lim.wrapUpBelow { return .wrapUp }
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
    
    public static func canStartMain(_ s: Snapshot, _ modelId: String) -> (ok: Bool, reason: String) {
        guard let model = s.config.model(modelId) else { return (false, "Model not found") }
        guard model.enabled else { return (false, "Model is disabled") }
        guard model.isMain else { return (false, "Model is not a main model") }
        if s.sessions.count >= s.config.limits.maxMainSessions { return (false, "Global maxMainSessions exceeded") }
        if s.sessions.filter({ $0.harness == model.harness }).count >= sessionCap(s, model.harness) {
            return (false, "Harness session cap reached")
        }
        return (true, "")
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
    
    public static func pickWorker(_ s: Snapshot, _ size: JobSize, _ kind: JobKind, _ privacy: Privacy, mainModel: String?) -> ModelEntry? {
        let running = s.jobs.filter { $0.state == .running }
        if running.count >= s.config.limits.maxJobs { return nil }
        let minInt = minIntelligence(size, kind, lim: s.config.limits)
        
        var candidates: [ModelEntry] = []
        for model in s.config.models {
            guard model.enabled && model.isWorker && model.intelligence >= minInt else { continue }
            guard let harness = s.config.harness(model.harness) else { continue }
            if privacy == .project && !harness.trusted { continue }
            if running.filter({ $0.harness == model.harness }).count >= workerCap(s, model.harness) { continue }
            
            var mainHarness: String? = nil
            if let mId = mainModel, let mm = s.config.model(mId) { mainHarness = mm.harness }
            if model.harness == mainHarness {
                if let L = left(s, model.harness), L < s.config.limits.sameHarnessMinLeft { continue }
            }
            candidates.append(model)
        }
        
        var mainHarness: String? = nil
        if let mId = mainModel, let mm = s.config.model(mId) { mainHarness = mm.harness }
        
        candidates.sort { a, b in
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
            return a.id < b.id
        }
        return candidates.first
    }
    
    public static func pickBroker(_ s: Snapshot, mainModel: String?) -> ModelEntry? {
        let running = s.jobs.filter { $0.state == .running }
        var candidates: [ModelEntry] = []
        for model in s.config.models {
            guard model.enabled && model.isWorker else { continue }
            guard model.intelligence >= s.config.limits.brokerMinIntelligence && model.intelligence <= s.config.limits.brokerMaxIntelligence else { continue }
            guard let harness = s.config.harness(model.harness) else { continue }
            guard harness.trusted else { continue }
            guard workerCap(s, model.harness) > 0 else { continue }
            let b = band(s, model.harness)
            guard b != .exhausted && b != .wrapUp else { continue }
            candidates.append(model)
        }
        
        var mainHarness: String? = nil
        if let mId = mainModel, let mm = s.config.model(mId) { mainHarness = mm.harness }
        
        candidates.sort { a, b in
            let aSame = a.harness == mainHarness
            let bSame = b.harness == mainHarness
            if aSame != bSame { return !aSame }
            if a.intelligence != b.intelligence { return a.intelligence > b.intelligence }
            let aLeft = left(s, a.harness) ?? 0.5
            let bLeft = left(s, b.harness) ?? 0.5
            if aLeft != bLeft { return aLeft > bLeft }
            return a.id < b.id
        }
        return candidates.first
    }

    public static func plan(_ s: Snapshot, _ job: Job) -> (worker: ModelEntry, broker: ModelEntry?)? {
        if job.privacy == .project && job.offload != false && (job.offload == true || s.config.limits.maskedOffloadSizes.contains(job.size.rawValue)) && job.kind == .implement {
            if let broker = pickBroker(s, mainModel: job.mainModel) {
                let running = s.jobs.filter { $0.state == .running }
                if running.count < s.config.limits.maxJobs {
                    var candidates: [ModelEntry] = []
                    for model in s.config.models {
                        guard model.enabled && model.isWorker && model.free else { continue }
                        guard let harness = s.config.harness(model.harness) else { continue }
                        guard !harness.trusted else { continue }
                        if running.filter({ $0.harness == model.harness }).count >= workerCap(s, model.harness) { continue }
                        candidates.append(model)
                    }
                    
                    var mainHarness: String? = nil
                    if let mId = job.mainModel, let mm = s.config.model(mId) { mainHarness = mm.harness }
                    
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
                        return a.id < b.id
                    }
                    
                    if let worker = candidates.first {
                        return (worker: worker, broker: broker)
                    }
                }
            }
        }
        if let worker = pickWorker(s, job.size, job.kind, job.privacy, mainModel: job.mainModel) {
            return (worker: worker, broker: nil)
        }
        return nil
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
            let aOrder = s.config.mainOrder.firstIndex(of: a.id) ?? Int.max
            let bOrder = s.config.mainOrder.firstIndex(of: b.id) ?? Int.max
            if aOrder != bOrder { return aOrder < bOrder }
            let aLeft = left(s, a.harness) ?? 0.5
            let bLeft = left(s, b.harness) ?? 0.5
            if aLeft != bLeft { return aLeft > bLeft }
            return a.id < b.id
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

