import Foundation

public enum ConfigStore {
    public static func defaults() -> AppConfig {
        let harnesses: [Harness] = [
            Harness(
                id: "claude",
                name: "Claude",
                executable: "claude",
                accounts: [],
                trusted: true,
                usageSource: .claudeStatusline,
                hookStyle: .claude,
                mainArgs: ["{exe}", "--model", "{model}", "--permission-mode", "acceptEdits", "{prompt}"],
                workerArgs: ["{exe}", "-p", "--model", "{model}", "--permission-mode", "acceptEdits", "--output-format", "json", "{prompt}"]
            ),
            Harness(
                id: "codex",
                name: "Codex",
                executable: "codex",
                accounts: [],
                trusted: true,
                usageSource: .codexSessions,
                hookStyle: .codex,
                mainArgs: ["{exe}", "-C", "{project}", "-m", "{model}", "-c", "model_reasoning_effort={effort}", "{prompt}"],
                workerArgs: ["{exe}", "exec", "--model", "{model}", "--config", "model_reasoning_effort={effort}", "--sandbox", "workspace-write", "--cd", "{project}", "--skip-git-repo-check", "--json", "-"],
                promptViaStdin: true,
                queueArgs: ["{exe}", "queue", "--thread", "{session}", "--message", "{text}"]
            ),
            Harness(
                id: "antigravity",
                name: "Antigravity",
                executable: "agy",
                accounts: [],
                trusted: true,
                usageSource: .manual,
                hookStyle: .none,
                mainArgs: ["{exe}", "--model", "{model}", "-i", "{prompt}"],
                workerArgs: ["{exe}", "--model", "{model}", "--dangerously-skip-permissions", "--print-timeout", "{timeout}s", "-p", "{prompt}"]
            ),
            Harness(
                id: "opencode",
                name: "OpenCode",
                executable: "opencode",
                accounts: [],
                trusted: false,
                usageSource: .none,
                hookStyle: .none,
                mainArgs: [],
                workerArgs: ["{exe}", "run", "--model", "{model}", "{prompt}"]
            )
        ]

        let models: [ModelEntry] = [
            ModelEntry(id: "claude-opus-5-5", harness: "claude", name: "Claude Opus 5.5", intelligence: 98, isMain: true, isWorker: false),
            ModelEntry(id: "gpt-6.1-sol", harness: "codex", name: "GPT-6.1 Sol", intelligence: 97, isMain: true, isWorker: true, effort: "xhigh"),
            ModelEntry(id: "claude-sonnet-5-5", harness: "claude", name: "Claude Sonnet 5.5", intelligence: 88, isMain: false, isWorker: true),
            ModelEntry(id: "gpt-6-sol", harness: "codex", name: "GPT-6 Sol", intelligence: 90, isMain: false, isWorker: true, effort: "high"),
            ModelEntry(id: "gpt-6-luna", harness: "codex", name: "GPT-6 Luna", intelligence: 80, isMain: false, isWorker: true, effort: "high"),
            ModelEntry(id: "claude-haiku-4-5-20251001", harness: "claude", name: "Claude Haiku 4.5", intelligence: 60, isMain: false, isWorker: true),
            ModelEntry(id: "gemini-3.1-pro-high", harness: "antigravity", name: "Gemini 3.1 Pro High", intelligence: 85, isMain: false, isWorker: true),
            ModelEntry(id: "gemini-3.8-flash-high", harness: "antigravity", name: "Gemini 3.8 Flash High", intelligence: 72, isMain: false, isWorker: true),
            ModelEntry(id: "gemini-3.8-flash-low", harness: "antigravity", name: "Gemini 3.8 Flash Low", intelligence: 55, isMain: false, isWorker: true),
            ModelEntry(id: "opencode/big-pickle", harness: "opencode", name: "Big Pickle", intelligence: 50, isMain: false, isWorker: true, free: true)
        ]

        let mainOrder = ["claude-opus-5-5", "gpt-6.1-sol"]

        return AppConfig(harnesses: harnesses, models: models, mainOrder: mainOrder)
    }

    public static func load(_ paths: HubPaths) -> (config: AppConfig, warning: String?) {
        guard FileManager.default.fileExists(atPath: paths.config.path) else {
            let def = defaults()
            try? save(def, paths)
            return (def, nil)
        }

        guard let data = try? Data(contentsOf: paths.config),
              let config = try? JSONCoding.decoder.decode(AppConfig.self, from: data) else {
            let unix = Int(Date().timeIntervalSince1970)
            let invalidURL = paths.root.appendingPathComponent("config.invalid-\(unix).json")
            try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: invalidURL)
            try? FileManager.default.copyItem(at: paths.config, to: invalidURL)
            let def = defaults()
            return (def, "Undecodable config file backed up to \(invalidURL.lastPathComponent)")
        }

        do {
            let migrated = migrate(config)
            try validate(migrated)
            if migrated != config { try? save(migrated, paths) }
            return (migrated, nil)
        } catch {
            let unix = Int(Date().timeIntervalSince1970)
            let invalidURL = paths.root.appendingPathComponent("config.invalid-\(unix).json")
            try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: invalidURL)
            try? FileManager.default.copyItem(at: paths.config, to: invalidURL)
            let def = defaults()
            return (def, "Invalid config backed up to \(invalidURL.lastPathComponent): \(error.localizedDescription)")
        }
    }

    public static func save(_ c: AppConfig, _ paths: HubPaths) throws {
        try validate(c)
        try FileStore.write(c, to: paths.config)
    }

    public static func validate(_ c: AppConfig) throws {
        var harnessIds = Set<String>()
        for h in c.harnesses {
            guard harnessIds.insert(h.id).inserted else {
                throw HubError.invalid("Duplicate harness id: '\(h.id)'")
            }
        }

        var modelIds = Set<String>()
        for m in c.models {
            guard modelIds.insert(m.qualifiedID).inserted else {
                throw HubError.invalid("Duplicate model id: '\(m.qualifiedID)'")
            }
        }

        for m in c.models {
            guard c.harness(m.harness) != nil else {
                throw HubError.invalid("Model '\(m.id)' references unknown harness '\(m.harness)'")
            }
        }

        var seenMainOrder = Set<String>()
        for id in c.mainOrder {
            let matches: [ModelEntry]
            if let (harness, rawID) = ModelIdentity.parse(id, knownHarnesses: Set(c.harnesses.map(\.id))) {
                let qualifiedMatches = c.models.filter { $0.harness == harness && $0.id == rawID }
                if !qualifiedMatches.isEmpty {
                    matches = qualifiedMatches
                } else {
                    let rawMatches = c.models.filter { $0.id == id }
                    matches = rawMatches.count > 1 ? rawMatches.filter(\.isMain) : rawMatches
                }
            } else {
                let all = c.models.filter { $0.id == id }
                matches = all.count > 1 ? all.filter(\.isMain) : all
            }
            guard matches.count == 1, let m = matches.first else {
                throw HubError.invalid("mainOrder model '\(id)' is missing")
            }
            guard seenMainOrder.insert(m.qualifiedID).inserted else {
                throw HubError.invalid("Duplicate id in mainOrder: '\(id)'")
            }
            guard m.isMain else {
                throw HubError.invalid("mainOrder model '\(id)' is not a main model")
            }
        }

        guard (1...12).contains(c.limits.maxMainSessions) else {
            throw HubError.invalid("maxMainSessions \(c.limits.maxMainSessions) outside 1...12")
        }

        guard c.limits.jobTimeoutSeconds > 0 && c.limits.jobTimeoutSeconds.isFinite else {
            throw HubError.invalid("jobTimeoutSeconds must be finite and positive")
        }

        guard (0...16).contains(c.limits.maxJobs) else {
            throw HubError.invalid("maxJobs \(c.limits.maxJobs) outside 0...16")
        }

        let lim = c.limits
        guard 0 <= lim.exhaustedAtOrBelow,
              lim.exhaustedAtOrBelow < lim.wrapUpBelow,
              lim.wrapUpBelow <= lim.singleSessionBelow,
              lim.singleSessionBelow <= lim.sameHarnessMinLeft,
              lim.sameHarnessMinLeft <= 1.0 else {
            throw HubError.invalid("Threshold ordering violated: 0 <= exhaustedAtOrBelow < wrapUpBelow <= singleSessionBelow <= sameHarnessMinLeft <= 1")
        }

        for m in c.models {
            guard (0...100).contains(m.intelligence) else {
                throw HubError.invalid("Model '\(m.id)' intelligence \(m.intelligence) outside 0...100")
            }
        }

        for (k, v) in c.limits.minIntelligence {
            guard (0...100).contains(v) else {
                throw HubError.invalid("minIntelligence '\(k)' value \(v) outside 0...100")
            }
        }
    }

    public static func addMainModel(_ c: inout AppConfig, model: ModelEntry) {
        var entry = model
        entry.isMain = true
        let oldMatches = c.models.filter { $0.id == entry.id }
        if let idx = c.models.firstIndex(where: { $0.harness == entry.harness && $0.id == entry.id }) {
            c.models[idx] = entry
        } else {
            c.models.append(entry)
        }
        c.mainOrder.removeAll { $0 == entry.qualifiedID || ($0 == entry.id && (oldMatches.count <= 1 || oldMatches.first?.harness == entry.harness)) }
        c.mainOrder.append(c.models.filter { $0.id == entry.id }.count > 1 ? entry.qualifiedID : entry.id)
    }

    public static func upsertModel(_ entry: ModelEntry, in c: inout AppConfig) {
        if let index = c.models.firstIndex(where: { $0.harness == entry.harness && $0.id == entry.id }) {
            c.models[index] = entry
        } else {
            c.models.append(entry)
        }
    }

    public static func removeModel(id: String, harness: String? = nil, from c: inout AppConfig) {
        let matches = c.models.filter { $0.id == id || $0.qualifiedID == id }
        let target = harness.flatMap { h in matches.first { $0.harness == h } } ?? (matches.count == 1 ? matches.first : nil)
        guard let target else { return }
        c.models.removeAll { $0.qualifiedID == target.qualifiedID }
        let remaining = c.models.filter { $0.id == target.id }
        c.mainOrder.removeAll { $0 == target.qualifiedID || ($0 == target.id && remaining.isEmpty) }
    }

    private static func migrate(_ input: AppConfig) -> AppConfig {
        var config = input
        let defaults = defaults()
        if !config.harnesses.contains(where: { $0.id == "claude" }),
           let defaultHarness = defaults.harness("claude") { config.harnesses.append(defaultHarness) }
        if !config.models.contains(where: { $0.harness == "claude" && $0.id == "claude-opus-5-5" }),
           let defaultMain = defaults.models.first(where: { $0.harness == "claude" && $0.id == "claude-opus-5-5" }) {
            config.mainOrder.removeAll { $0 == defaultMain.id }
            config.models.append(defaultMain)
            config.mainOrder.insert(defaultMain.qualifiedID, at: 0)
        }
        config.mainOrder = config.mainOrder.map { value in
            if ModelIdentity.parse(value, knownHarnesses: Set(config.harnesses.map(\.id))) != nil { return value }
            let matches = config.models.filter { $0.id == value }
            guard matches.count > 1 else { return value }
            let mainMatches = matches.filter(\.isMain)
            return mainMatches.count == 1 ? mainMatches[0].qualifiedID : value
        }
        return config
    }
}

extension AppConfig {
    public func isEligibleMainModel(harness: String, model: String?) -> Bool {
        guard let model = model, !model.isEmpty else {
            return models.contains { $0.harness == harness && $0.enabled && $0.isMain }
        }
        guard let entry = self.model(model, harness: harness) else { return false }
        return entry.harness == harness && entry.enabled && entry.isMain
    }
}
