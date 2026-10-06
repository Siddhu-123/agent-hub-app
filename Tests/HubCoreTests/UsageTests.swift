import Foundation
import Testing
@testable import HubCore

@Suite struct UsageTests {
    /// Regression (Notch Phase 6): a trailing `premium` record with null windows hid the
    /// exhausted `codex` record, so Codex read as "unknown" and was treated as healthy.
    @Test func codexPremiumNullRecordDoesNotHideExhaustedCodexLimit() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sessionsDir = tempDir.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let now = Date()
        let reset = Int(now.timeIntervalSince1970 + 4500)
        let lines = [
            #"{"type":"event_msg","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":100.0,"window_minutes":300,"resets_at":\#(reset)},"secondary":{"used_percent":42.0,"window_minutes":10080,"resets_at":\#(reset + 99999)}}}}"#,
            #"{"type":"event_msg","payload":{"rate_limits":{"limit_id":"premium","primary":null,"secondary":null}}}"#,
        ]
        try lines.joined(separator: "\n").write(to: sessionsDir.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)

        let reading = try #require(UsageMeter(paths: HubPaths(root: tempDir), codexSessionsDir: sessionsDir)
            .read(ConfigStore.defaults(), now: now)["codex"])
        #expect(reading.left == 0.0)
        #expect(reading.windows.first { $0.name == "5h" }?.resetsAt == Date(timeIntervalSince1970: TimeInterval(reset)))
    }

    @Test func codexJsonlParsing() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let paths = HubPaths(root: tempDir)
        let sessionsDir = tempDir.appendingPathComponent("sessions")

        let nested1 = sessionsDir.appendingPathComponent("sub1")
        let nested2 = sessionsDir.appendingPathComponent("nested/sub2")
        try FileManager.default.createDirectory(at: nested1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nested2, withIntermediateDirectories: true)

        let now = Date()

        // 1. Oldest file: has rate_limits with 80% used
        let file1 = nested1.appendingPathComponent("session1.jsonl")
        let file1Content = """
        {"type":"message","text":"hello"}
        {"rate_limits":{"primary":{"used_percent":80.0,"window_minutes":300,"resets_at":\(Int(now.timeIntervalSince1970 + 7200))}}}
        """
        try file1Content.write(to: file1, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: file1.path)

        // 2. Middle file: newer than file1, but without rate_limits (should be skipped)
        let file2 = nested2.appendingPathComponent("session2.jsonl")
        let file2Content = """
        {"type":"message","text":"working on code"}
        {"type":"tool_call","name":"view_file"}
        """
        try file2Content.write(to: file2, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-1800)], ofItemAtPath: file2.path)

        // 3. Newest file: has rate_limits; primary window is 20%, secondary window has expired reset date (should count as 0%)
        let file3 = nested2.appendingPathComponent("session3.jsonl")
        let file3Content = """
        {"rate_limits":{"primary":{"used_percent":20.0,"window_minutes":300,"resets_at":\(Int(now.timeIntervalSince1970 + 3600))},"secondary":{"used_percent":65.0,"window_minutes":10080,"resets_at":\(Int(now.timeIntervalSince1970 - 600))}}}
        """
        let file3Tail = "\n{\"type\":\"event\",\"rate_limits\": null}"
        try (file3Content + file3Tail).write(to: file3, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: file3.path)

        let meter = UsageMeter(paths: paths, codexSessionsDir: sessionsDir)
        let config = ConfigStore.defaults()
        let readings = meter.read(config, now: now)

        let reading = try #require(readings["codex"])
        #expect(reading.source == "codexSessions")
        #expect(reading.windows.count == 2)

        let primary = try #require(reading.windows.first { $0.name == "5h" })
        #expect(primary.usedPercent == 20.0)

        // Expired window counts as 0% used
        let secondary = try #require(reading.windows.first { $0.name == "7d" })
        #expect(secondary.usedPercent == 0.0)

        // left = min(1 - 0.20, 1 - 0.00) = 0.80
        #expect(reading.left == 0.80)
    }

    @Test func claudeStatuslineWriteReadRoundtrip() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let paths = HubPaths(root: tempDir)
        let now = Date(timeIntervalSince1970: 1700000000)

        let jsonInput = """
        {
          "model": {
            "display_name": "Claude 3.5 Sonnet"
          },
          "rate_limits": {
            "five_hour": {
              "used_percentage": 15.0,
              "resets_at": 1700018000
            },
            "seven_day": {
              "used_percentage": 40.0,
              "resets_at": 1700600000
            }
          }
        }
        """

        let statusText = UsageMeter.writeClaudeStatusline(stdinJSON: Data(jsonInput.utf8), paths: paths, now: now)
        #expect(statusText == "Claude 3.5 Sonnet · 5h 15% · 7d 40%")

        let meter = UsageMeter(paths: paths)
        let config = ConfigStore.defaults()
        let readings = meter.read(config, now: now)

        let reading = try #require(readings["claude"])
        #expect(reading.source == "claudeStatusline")
        #expect(reading.windows.count == 2)
        #expect(reading.asOf == now)

        let fiveHour = try #require(reading.windows.first { $0.name == "5h" })
        #expect(fiveHour.usedPercent == 15.0)

        let sevenDay = try #require(reading.windows.first { $0.name == "7d" })
        #expect(sevenDay.usedPercent == 40.0)

        // left = min(1 - 0.15, 1 - 0.40) = 0.60
        #expect(reading.left == 0.60)
    }

    @Test func badStatuslineInputWritesNothing() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let paths = HubPaths(root: tempDir)
        let now = Date()

        // 1. Non-JSON
        let res1 = UsageMeter.writeClaudeStatusline(stdinJSON: Data("not-valid-json".utf8), paths: paths, now: now)
        #expect(res1 == "")
        #expect(!FileManager.default.fileExists(atPath: paths.claudeUsage.path))

        // 2. Missing rate_limits
        let res2 = UsageMeter.writeClaudeStatusline(stdinJSON: Data("{\"model\": \"test\"}".utf8), paths: paths, now: now)
        #expect(res2 == "")
        #expect(!FileManager.default.fileExists(atPath: paths.claudeUsage.path))

        // 3. Empty rate_limits
        let res3 = UsageMeter.writeClaudeStatusline(stdinJSON: Data("{\"rate_limits\": {}}".utf8), paths: paths, now: now)
        #expect(res3 == "")
        #expect(!FileManager.default.fileExists(atPath: paths.claudeUsage.path))
    }

    @Test func manualAndNoneSources() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let paths = HubPaths(root: tempDir)
        let now = Date()

        var config = ConfigStore.defaults()
        // Antigravity is manual source
        if let idx = config.harnesses.firstIndex(where: { $0.id == "antigravity" }) {
            config.harnesses[idx].manualLeft = 0.65
        }

        let meter = UsageMeter(paths: paths)
        let readings = meter.read(config, now: now)

        let agyReading = readings["antigravity"]
        #expect(agyReading?.left == 0.65)
        #expect(agyReading?.source == "manual")
        #expect(agyReading?.windows.isEmpty == true)

        let openCodeReading = readings["opencode"]
        #expect(openCodeReading?.left == nil)
        #expect(openCodeReading?.source == "none")
        #expect(openCodeReading?.windows.isEmpty == true)
    }

    @Test func cooldownOverridesLeftAndPrunesExpired() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let paths = HubPaths(root: tempDir)
        let now = Date(timeIntervalSince1970: 1700000000)

        // Active cooldown on antigravity
        let future = now.addingTimeInterval(1800)
        Cooldowns.set("harness:antigravity", until: future, paths: paths)

        // Expired cooldown on codex
        let past = now.addingTimeInterval(-300)
        Cooldowns.set("harness:codex", until: past, paths: paths)

        var config = ConfigStore.defaults()
        if let idx = config.harnesses.firstIndex(where: { $0.id == "antigravity" }) {
            config.harnesses[idx].manualLeft = 0.90
        }

        let meter = UsageMeter(paths: paths)
        let readings = meter.read(config, now: now)

        // Active cooldown overrides left to 0 and updates source
        let agy = try #require(readings["antigravity"])
        #expect(agy.left == 0.0)
        #expect(agy.coolingUntil == future)
        #expect(agy.source == "usage limit cooldown")

        // Cooldowns.until prunes expired keys
        let codexUntil = Cooldowns.until("harness:codex", paths: paths, now: now)
        #expect(codexUntil == nil)

        let antigravityUntil = Cooldowns.until("harness:antigravity", paths: paths, now: now)
        #expect(antigravityUntil == future)

        // Verify stored cooldowns on disk: expired key was removed
        let stored = FileStore.read([String: Date].self, from: paths.cooldowns)
        #expect(stored?["harness:codex"] == nil)
        #expect(stored?["harness:antigravity"] != nil)
    }

    @Test func fromOutputParsing() {
        let now = Date()

        // Parses 'resets in 2h 5m' -> 2*3600 + 5*60 = 7500
        #expect(Cooldowns.fromOutput("Your plan resets in 2h 5m", now: now) == nil)
        #expect(Cooldowns.fromOutput("rate limit exceeded; resets in 2h 5m", now: now) == 7500)
        #expect(Cooldowns.fromOutput("RESOURCE_EXHAUSTED: resets in 1h 30m 15s", now: now) == 5415)

        // Defaults to 1800 when no reset time specified
        #expect(Cooldowns.fromOutput("429 Too Many Requests", now: now) == 1800)
        #expect(Cooldowns.fromOutput("rate limit reached", now: now) == 1800)
        #expect(Cooldowns.fromOutput("quota exceeded", now: now) == 1800)
        #expect(Cooldowns.fromOutput("Individual quota reached", now: now) == 1800)

        // Minimum of 60 seconds
        #expect(Cooldowns.fromOutput("rate limit: resets in 10s", now: now) == 60)

        // Returns nil for normal output
        #expect(Cooldowns.fromOutput("Build completed in 1.4s with 0 warnings", now: now) == nil)
        #expect(Cooldowns.fromOutput("All tests passed", now: now) == nil)
        #expect(Cooldowns.fromOutput("Executing git status", now: now) == nil)
    }
}
