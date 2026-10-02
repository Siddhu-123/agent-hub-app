import Foundation

public struct UsageMeter {
    public let paths: HubPaths
    public var codexSessionsDir: URL

    public init(paths: HubPaths, codexSessionsDir: URL? = nil) {
        self.paths = paths
        self.codexSessionsDir = codexSessionsDir ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    }

    public func read(_ c: AppConfig, now: Date) -> [String: UsageReading] {
        var readings: [String: UsageReading] = [:]
        for harness in c.harnesses {
            var reading: UsageReading
            switch harness.usageSource {
            case .codexSessions:
                reading = readCodexSessions(now: now)
            case .claudeStatusline:
                reading = readClaudeStatusline(now: now)
            case .manual:
                let left = harness.manualLeft.map { Self.round3($0) }
                reading = UsageReading(left: left, windows: [], source: "manual")
            case .none:
                reading = UsageReading(left: nil, windows: [], source: "none")
            }

            if let cooling = Cooldowns.until("harness:\(harness.id)", paths: paths, now: now), cooling > now {
                reading.left = 0.0
                reading.coolingUntil = cooling
                reading.source = "usage limit cooldown"
            }

            readings[harness.id] = reading
        }
        return readings
    }

    private func readCodexSessions(now: Date) -> UsageReading {
        guard FileManager.default.fileExists(atPath: codexSessionsDir.path) else {
            return UsageReading(left: nil, windows: [], source: "codexSessions")
        }

        var jsonlFiles: [(url: URL, modDate: Date)] = []
        if let enumerator = FileManager.default.enumerator(
            at: codexSessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                if fileURL.pathExtension == "jsonl" {
                    let modDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
                    jsonlFiles.append((url: fileURL, modDate: modDate))
                }
            }
        }

        jsonlFiles.sort { $0.modDate > $1.modDate }
        let newestFive = jsonlFiles.prefix(5)

        for item in newestFive {
            guard let handle = try? FileHandle(forReadingFrom: item.url) else { continue }
            defer { try? handle.close() }
            let fileSize = (try? handle.seekToEnd()) ?? 0
            let bytesToRead = min(fileSize, 400 * 1024)
            let offset = fileSize - bytesToRead
            try? handle.seek(toOffset: offset)
            let data = handle.readDataToEndOfFile()
            guard !data.isEmpty else { continue }
            let text = String(decoding: data, as: UTF8.self)

            // Newest occurrence that is an object (some events carry "rate_limits": null).
            var searchEnd = text.endIndex
            var found: String.Index? = nil
            while found == nil, let rlRange = text.range(of: "\"rate_limits\"", options: .backwards, range: text.startIndex..<searchEnd) {
                searchEnd = rlRange.lowerBound
                let rest = text[rlRange.upperBound...].drop { $0 == " " || $0 == "\t" }
                guard rest.first == ":" else { continue }
                let value = rest.dropFirst().drop { $0 == " " || $0 == "\t" || $0 == "\n" }
                if value.first == "{" { found = value.startIndex }
            }
            guard let openBraceIdx = found else { continue }

            var depth = 0
            var inString = false
            var isEscaped = false
            var closeBraceIdx: String.Index? = nil

            for idx in text.indices[openBraceIdx...] {
                let ch = text[idx]
                if inString {
                    if isEscaped {
                        isEscaped = false
                    } else if ch == "\\" {
                        isEscaped = true
                    } else if ch == "\"" {
                        inString = false
                    }
                } else {
                    if ch == "\"" {
                        inString = true
                    } else if ch == "{" {
                        depth += 1
                    } else if ch == "}" {
                        depth -= 1
                        if depth == 0 {
                            closeBraceIdx = idx
                            break
                        }
                    }
                }
            }

            guard let closeBraceIdx else { continue }
            let jsonSub = String(text[openBraceIdx...closeBraceIdx])
            guard let jsonData = jsonSub.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }

            var windows: [UsageWindow] = []
            if let primary = obj["primary"] as? [String: Any] {
                var used = (primary["used_percent"] as? NSNumber)?.doubleValue ?? 0.0
                let resetsAt = (primary["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                if let resetsAt, resetsAt <= now {
                    used = 0.0
                }
                windows.append(UsageWindow(name: "5h", usedPercent: used, resetsAt: resetsAt))
            }
            if let secondary = obj["secondary"] as? [String: Any] {
                var used = (secondary["used_percent"] as? NSNumber)?.doubleValue ?? 0.0
                let resetsAt = (secondary["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                if let resetsAt, resetsAt <= now {
                    used = 0.0
                }
                windows.append(UsageWindow(name: "7d", usedPercent: used, resetsAt: resetsAt))
            }

            guard !windows.isEmpty else { continue }

            let minRemaining = windows.map { 1.0 - ($0.usedPercent / 100.0) }.min() ?? 1.0
            let left = Self.round3(minRemaining)
            return UsageReading(left: left, windows: windows, source: "codexSessions", asOf: item.modDate)
        }

        return UsageReading(left: nil, windows: [], source: "codexSessions", asOf: nil)
    }

    private func readClaudeStatusline(now: Date) -> UsageReading {
        guard let data = try? Data(contentsOf: paths.claudeUsage),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return UsageReading(left: nil, windows: [], source: "claudeStatusline")
        }

        let asOfDate = (obj["as_of"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        var windows: [UsageWindow] = []

        if let fh = obj["five_hour"] as? [String: Any] {
            var used = (fh["used_percentage"] as? NSNumber)?.doubleValue ?? 0.0
            let resetsAt = (fh["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            if let resetsAt, resetsAt <= now {
                used = 0.0
            }
            windows.append(UsageWindow(name: "5h", usedPercent: used, resetsAt: resetsAt))
        }

        if let sd = obj["seven_day"] as? [String: Any] {
            var used = (sd["used_percentage"] as? NSNumber)?.doubleValue ?? 0.0
            let resetsAt = (sd["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            if let resetsAt, resetsAt <= now {
                used = 0.0
            }
            windows.append(UsageWindow(name: "7d", usedPercent: used, resetsAt: resetsAt))
        }

        let left: Double?
        if windows.isEmpty {
            left = nil
        } else {
            let minRemaining = windows.map { 1.0 - ($0.usedPercent / 100.0) }.min() ?? 1.0
            left = Self.round3(minRemaining)
        }

        return UsageReading(left: left, windows: windows, source: "claudeStatusline", asOf: asOfDate)
    }

    public static func writeClaudeStatusline(stdinJSON: Data, paths: HubPaths, now: Date) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: stdinJSON) as? [String: Any],
              let rateLimits = json["rate_limits"] as? [String: Any] else {
            return ""
        }

        let fh = rateLimits["five_hour"] as? [String: Any]
        let sd = rateLimits["seven_day"] as? [String: Any]
        guard fh != nil || sd != nil else {
            return ""
        }

        var toSave: [String: Any] = ["as_of": Int(now.timeIntervalSince1970)]
        if let fh { toSave["five_hour"] = fh }
        if let sd { toSave["seven_day"] = sd }

        do {
            try FileManager.default.createDirectory(at: paths.claudeUsage.deletingLastPathComponent(), withIntermediateDirectories: true)
            let outData = try JSONSerialization.data(withJSONObject: toSave, options: [.prettyPrinted, .sortedKeys])
            try outData.write(to: paths.claudeUsage, options: .atomic)
        } catch {
            return ""
        }

        var displayName: String? = nil
        if let m = json["model"] as? [String: Any] {
            displayName = m["display_name"] as? String ?? m["name"] as? String
        } else if let m = json["model"] as? String {
            displayName = m
        } else if let d = json["display_name"] as? String {
            displayName = d
        }

        var parts: [String] = []
        if let displayName, !displayName.isEmpty {
            parts.append(displayName)
        }
        if let fh, let p = (fh["used_percentage"] as? NSNumber)?.doubleValue {
            parts.append("5h \(Int(round(p)))%")
        }
        if let sd, let p = (sd["used_percentage"] as? NSNumber)?.doubleValue {
            parts.append("7d \(Int(round(p)))%")
        }

        return parts.joined(separator: " · ")
    }

    private static func round3(_ val: Double) -> Double {
        let clamped = max(0.0, min(1.0, val))
        return (clamped * 1000.0).rounded() / 1000.0
    }
}

public enum Cooldowns {
    public static func set(_ key: String, until: Date, paths: HubPaths) {
        FileStore.withLock(paths, "cooldowns") {
            var map = FileStore.read([String: Date].self, from: paths.cooldowns) ?? [:]
            map[key] = until
            try? FileStore.write(map, to: paths.cooldowns)
        }
    }

    public static func set(key: String, until: Date, paths: HubPaths) {
        set(key, until: until, paths: paths)
    }

    public static func until(_ key: String, paths: HubPaths, now: Date) -> Date? {
        FileStore.withLock(paths, "cooldowns") {
            guard var map = FileStore.read([String: Date].self, from: paths.cooldowns) else { return nil }
            let originalCount = map.count
            map = map.filter { $0.value > now }
            if map.count != originalCount {
                try? FileStore.write(map, to: paths.cooldowns)
            }
            return map[key]
        }
    }

    public static func until(key: String, paths: HubPaths, now: Date) -> Date? {
        until(key, paths: paths, now: now)
    }

    public static func until(harness id: String, paths: HubPaths, now: Date) -> Date? {
        until("harness:\(id)", paths: paths, now: now)
    }

    public static func until(model id: String, paths: HubPaths, now: Date) -> Date? {
        until("model:\(id)", paths: paths, now: now)
    }

    public static func until(account exe: String, paths: HubPaths, now: Date) -> Date? {
        until("account:\(exe)", paths: paths, now: now)
    }

    private static let limitRegex = try! NSRegularExpression(
        pattern: #"(?i)\b429\b|RESOURCE_EXHAUSTED|usage limit|rate limit|quota (?:reached|exceeded|exhausted)|Individual quota"#
    )

    private static let resetRegex = try! NSRegularExpression(
        pattern: #"(?i)resets?\s+in\s*(?:(\d+)\s*h)?\s*(?:(\d+)\s*m)?\s*(?:(\d+)\s*s)?"#
    )

    public static func fromOutput(_ text: String, now: Date = Date()) -> TimeInterval? {
        let fullRange = NSRange(text.startIndex..., in: text)
        guard limitRegex.firstMatch(in: text, range: fullRange) != nil else {
            return nil
        }
        guard let match = resetRegex.firstMatch(in: text, range: fullRange) else {
            return 1800
        }
        var foundAny = false
        var totalSeconds: Double = 0

        if match.range(at: 1).location != NSNotFound,
           let r = Range(match.range(at: 1), in: text),
           let h = Double(text[r]) {
            totalSeconds += h * 3600
            foundAny = true
        }
        if match.range(at: 2).location != NSNotFound,
           let r = Range(match.range(at: 2), in: text),
           let m = Double(text[r]) {
            totalSeconds += m * 60
            foundAny = true
        }
        if match.range(at: 3).location != NSNotFound,
           let r = Range(match.range(at: 3), in: text),
           let s = Double(text[r]) {
            totalSeconds += s
            foundAny = true
        }

        if !foundAny {
            return 1800
        }
        return max(60, totalSeconds)
    }
}
