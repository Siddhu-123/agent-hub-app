import Foundation
import Testing
@testable import HubCore

@Suite struct ConfigTests {
    @Test func defaultsValidate() throws {
        let config = ConfigStore.defaults()
        #expect(throws: Never.self) {
            try ConfigStore.validate(config)
        }
        #expect(config.harnesses.count == 4)
        #expect(config.models.count == 10)
        #expect(config.mainOrder == ["claude-opus-5-5", "gpt-6.1-sol"])
        #expect(config.harness("claude")?.usageSource == .claudeStatusline)
        #expect(config.harness("codex")?.usageSource == .codexSessions)
        #expect(config.harness("antigravity")?.usageSource == .manual)
        #expect(config.harness("opencode")?.trusted == false)
    }

    @Test func loadWritesDefaultsWhenMissing() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let paths = HubPaths(root: tempDir)

        let (loaded, warning) = ConfigStore.load(paths)
        #expect(warning == nil)
        #expect(loaded == ConfigStore.defaults())
        #expect(FileManager.default.fileExists(atPath: paths.config.path))

        let secondLoad = ConfigStore.load(paths)
        #expect(secondLoad.warning == nil)
        #expect(secondLoad.config == ConfigStore.defaults())
    }

    @Test func brokerEligibilityRoundTripsAndLegacyConfigsKeepRangeDefaults() throws {
        var config = ConfigStore.defaults()
        let lunaIndex = try #require(config.models.firstIndex { $0.id == "gpt-6-luna" })
        config.models[lunaIndex].brokerEligible = true
        let encoded = try JSONCoding.encoder.encode(config)
        let roundTripped = try JSONCoding.decoder.decode(AppConfig.self, from: encoded)
        #expect(roundTripped.model("gpt-6-luna")?.brokerEligible == true)

        // Simulate a config written before per-model broker eligibility existed.
        var legacyObject = try #require(JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(ConfigStore.defaults())) as? [String: Any])
        var legacyModels = try #require(legacyObject["models"] as? [[String: Any]])
        legacyModels = legacyModels.map { model in
            var oldModel = model
            oldModel.removeValue(forKey: "brokerEligible")
            return oldModel
        }
        legacyObject["models"] = legacyModels
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacy = try JSONCoding.decoder.decode(AppConfig.self, from: legacyData)
        #expect(legacy.models.allSatisfy { $0.brokerEligible == nil })
        #expect(legacy.limits.brokerMinIntelligence == 55)
        #expect(legacy.limits.brokerMaxIntelligence == 79)
        #expect((legacy.model("gpt-6-luna")?.brokerEligible ?? false) == false)
        #expect(legacy.model("claude-haiku-4-5-20251001")?.brokerEligible == nil)
    }

    @Test func sameRawIDCoexistsAcrossHarnessesAndRoundTrips() throws {
        var config = ConfigStore.defaults()
        let antigravity = ModelEntry(id: "claude-opus-5-5", harness: "antigravity", name: "Agy Opus", intelligence: 80,
                                     isMain: false, isWorker: true, enabled: false)
        ConfigStore.upsertModel(antigravity, in: &config)
        try ConfigStore.validate(config)

        let paths = HubPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try ConfigStore.save(config, paths)
        let (loaded, warning) = ConfigStore.load(paths)
        #expect(warning == nil)
        #expect(loaded.model("claude/claude-opus-5-5")?.harness == "claude")
        #expect(loaded.model("antigravity/claude-opus-5-5")?.enabled == false)
        #expect(loaded.models.filter { $0.id == "claude-opus-5-5" }.count == 2)
    }

    @Test func ambiguousRawModelNeedsQualificationAndOpenCodeSlashIsPreserved() throws {
        var config = ConfigStore.defaults()
        ConfigStore.upsertModel(ModelEntry(id: "claude-opus-5-5", harness: "antigravity", name: "Agy Opus", intelligence: 80,
                                           isMain: false, isWorker: true), in: &config)
        #expect(config.model("claude-opus-5-5") == nil)
        #expect(throws: HubError.self) { try config.resolveModel("claude-opus-5-5") }
        #expect(try config.resolveModel("claude-opus-5-5", preferredHarness: "claude").harness == "claude")
        #expect(config.model("opencode/big-pickle")?.id == "opencode/big-pickle")
        #expect(config.model("opencode/opencode/big-pickle")?.id == "opencode/big-pickle")
        #expect(ModelIdentity.parse("opencode/opencode/space-bunny-free", knownHarnesses: Set(config.harnesses.map(\.id)))?.id == "opencode/space-bunny-free")
    }

    @Test func loadRestoresMissingClaudeDefaultWithoutChangingAntigravityEntry() throws {
        var config = ConfigStore.defaults()
        config.models.removeAll { $0.harness == "claude" && $0.id == "claude-opus-5-5" }
        config.mainOrder.removeAll { $0 == "claude-opus-5-5" }
        let agy = ModelEntry(id: "claude-opus-5-5", harness: "antigravity", name: "Agy Opus", intelligence: 80,
                             isMain: false, isWorker: true, enabled: false)
        ConfigStore.upsertModel(agy, in: &config)
        let paths = HubPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try ConfigStore.save(config, paths)

        let (loaded, warning) = ConfigStore.load(paths)
        #expect(warning == nil)
        #expect(loaded.model("claude/claude-opus-5-5")?.isMain == true)
        #expect(loaded.model("antigravity/claude-opus-5-5")?.enabled == false)
    }

    @Test func undecodableFileIsBackedUpAndWarningReturned() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let paths = HubPaths(root: tempDir)

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try "corrupted json content".write(to: paths.config, atomically: true, encoding: .utf8)

        let (loaded, warning) = ConfigStore.load(paths)
        #expect(warning != nil)
        #expect(loaded == ConfigStore.defaults())

        let files = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        let backups = files.filter { $0.hasPrefix("config.invalid-") && $0.hasSuffix(".json") }
        #expect(backups.count == 1)
        if let backupName = backups.first {
            let backupContent = try String(contentsOf: tempDir.appendingPathComponent(backupName), encoding: .utf8)
            #expect(backupContent == "corrupted json content")
        }
    }

    @Test func eachValidateFailure() {
        // 1. Duplicate harness id
        var c1 = ConfigStore.defaults()
        c1.harnesses.append(c1.harnesses[0])
        #expect(throws: HubError.self) { try ConfigStore.validate(c1) }

        // 2. Duplicate model id
        var c2 = ConfigStore.defaults()
        c2.models.append(c2.models[0])
        #expect(throws: HubError.self) { try ConfigStore.validate(c2) }

        // 3. Model references unknown harness
        var c3 = ConfigStore.defaults()
        c3.models.append(ModelEntry(id: "alien-model", harness: "nonexistent-harness", name: "Alien", intelligence: 50, isMain: false, isWorker: true))
        #expect(throws: HubError.self) { try ConfigStore.validate(c3) }

        // 4. mainOrder id is missing from models
        var c4 = ConfigStore.defaults()
        c4.mainOrder.append("missing-model-id")
        #expect(throws: HubError.self) { try ConfigStore.validate(c4) }

        // 5. mainOrder id is not a main model
        var c5 = ConfigStore.defaults()
        c5.mainOrder.append("claude-sonnet-5-5") // isMain is false
        #expect(throws: HubError.self) { try ConfigStore.validate(c5) }

        // 6. maxMainSessions outside 1...12
        var c6 = ConfigStore.defaults()
        c6.limits.maxMainSessions = 0
        #expect(throws: HubError.self) { try ConfigStore.validate(c6) }
        c6.limits.maxMainSessions = 13
        #expect(throws: HubError.self) { try ConfigStore.validate(c6) }

        // 7. maxJobs outside 0...16
        var c7 = ConfigStore.defaults()
        c7.limits.maxJobs = -1
        #expect(throws: HubError.self) { try ConfigStore.validate(c7) }
        c7.limits.maxJobs = 17
        #expect(throws: HubError.self) { try ConfigStore.validate(c7) }

        // 8. Threshold ordering: 0 <= exhaustedAtOrBelow < wrapUpBelow <= singleSessionBelow <= sameHarnessMinLeft <= 1
        var c8a = ConfigStore.defaults()
        c8a.limits.exhaustedAtOrBelow = -0.01
        #expect(throws: HubError.self) { try ConfigStore.validate(c8a) }

        var c8b = ConfigStore.defaults()
        c8b.limits.exhaustedAtOrBelow = c8b.limits.wrapUpBelow // must be strictly less than
        #expect(throws: HubError.self) { try ConfigStore.validate(c8b) }

        var c8c = ConfigStore.defaults()
        c8c.limits.wrapUpBelow = 0.35
        c8c.limits.singleSessionBelow = 0.30
        #expect(throws: HubError.self) { try ConfigStore.validate(c8c) }

        var c8d = ConfigStore.defaults()
        c8d.limits.singleSessionBelow = 0.45
        c8d.limits.sameHarnessMinLeft = 0.40
        #expect(throws: HubError.self) { try ConfigStore.validate(c8d) }

        var c8e = ConfigStore.defaults()
        c8e.limits.sameHarnessMinLeft = 1.05
        #expect(throws: HubError.self) { try ConfigStore.validate(c8e) }

        // 9. Intelligence value outside 0...100
        var c9a = ConfigStore.defaults()
        c9a.models[0].intelligence = -5
        #expect(throws: HubError.self) { try ConfigStore.validate(c9a) }

        var c9b = ConfigStore.defaults()
        c9b.models[0].intelligence = 105
        #expect(throws: HubError.self) { try ConfigStore.validate(c9b) }

        var c9c = ConfigStore.defaults()
        c9c.limits.minIntelligence["tiny"] = -1
        #expect(throws: HubError.self) { try ConfigStore.validate(c9c) }

        var c9d = ConfigStore.defaults()
        c9d.limits.minIntelligence["tiny"] = 101
        #expect(throws: HubError.self) { try ConfigStore.validate(c9d) }
    }

    @Test func addMainModel() throws {
        var c = ConfigStore.defaults()

        // Add a brand new model
        let newModel = ModelEntry(
            id: "gemini-4-ultra",
            harness: "antigravity",
            name: "Gemini 4 Ultra",
            intelligence: 99,
            isMain: false,
            isWorker: true
        )
        ConfigStore.addMainModel(&c, model: newModel)
        let added = try #require(c.model("gemini-4-ultra"))
        #expect(added.isMain == true)
        #expect(c.mainOrder.last == "gemini-4-ultra")
        #expect(throws: Never.self) { try ConfigStore.validate(c) }

        // Update an existing model that was not main
        let existing = try #require(c.model("claude-sonnet-5-5"))
        #expect(existing.isMain == false)
        ConfigStore.addMainModel(&c, model: existing)
        let updated = try #require(c.model("claude-sonnet-5-5"))
        #expect(updated.isMain == true)
        #expect(c.mainOrder.last == "claude-sonnet-5-5")
        #expect(throws: Never.self) { try ConfigStore.validate(c) }

        let antigravityTwin = ModelEntry(id: "claude-sonnet-5-5", harness: "antigravity", name: "Agy Sonnet", intelligence: 50,
                                         isMain: false, isWorker: true, enabled: false)
        ConfigStore.upsertModel(antigravityTwin, in: &c)
        #expect(c.model("claude/claude-sonnet-5-5")?.isMain == true)
        #expect(c.model("antigravity/claude-sonnet-5-5")?.enabled == false)
    }

    @Test(arguments: [0.0, -1.0, Double.infinity, Double.nan])
    func rejectsInvalidTimeout(timeout: Double) {
        var config = ConfigStore.defaults()
        config.limits.jobTimeoutSeconds = timeout
        #expect(throws: HubError.self) { try ConfigStore.validate(config) }
    }

    @Test func removeModel() throws {
        var c = ConfigStore.defaults()
        #expect(c.model("claude-opus-5-5") != nil)
        #expect(c.mainOrder.contains("claude-opus-5-5"))

        ConfigStore.removeModel(id: "claude-opus-5-5", from: &c)
        #expect(c.model("claude-opus-5-5") == nil)
        #expect(!c.mainOrder.contains("claude-opus-5-5"))
        #expect(throws: Never.self) { try ConfigStore.validate(c) }

        // Removing non-main worker model
        #expect(c.model("gpt-6-sol") != nil)
        ConfigStore.removeModel(id: "gpt-6-sol", from: &c)
        #expect(c.model("gpt-6-sol") == nil)
        #expect(!c.mainOrder.contains("gpt-6-sol"))
        #expect(throws: Never.self) { try ConfigStore.validate(c) }
    }
}
