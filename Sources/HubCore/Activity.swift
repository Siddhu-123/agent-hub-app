import Foundation

public struct ActivityEvent: Codable, Equatable, Sendable {
    public var ts: Date
    public var kind: String
    public var job: String?
    public var harness: String?
    public var model: String?
    public var detail: [String: String]

    public init(ts: Date, kind: String, job: String? = nil, harness: String? = nil, model: String? = nil, detail: [String: String] = [:]) {
        self.ts = ts; self.kind = kind; self.job = job; self.harness = harness; self.model = model; self.detail = detail
    }
}

public struct ActivityStats: Codable, Equatable, Sendable {
    public struct Model: Codable, Equatable, Sendable {
        public var started = 0
        public var verified = 0
        public var failed = 0
        public var queuedBack = 0
        public var avgSeconds = 0.0
    }
    public struct Masked: Codable, Equatable, Sendable {
        public var attempted = 0
        public var passed = 0
        public var fallbacks = 0
        public var fallbackReasons: [String: Int] = [:]
    }
    public var models: [String: Model] = [:]
    public var masked = Masked()
    public var handoffs = 0
    public var wrapUps = 0
    public var cooldowns = 0
}

public enum Activity {
    internal static var rotationThreshold = 10 * 1024 * 1024

    public static func record(_ e: ActivityEvent, paths: HubPaths) {
        FileStore.withLock(paths, "activity") {
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: paths.logs, withIntermediateDirectories: true)
                let file = paths.logs.appendingPathComponent("events.jsonl")
                let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
                if size > rotationThreshold {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.timeZone = TimeZone(secondsFromGMT: 0)
                    formatter.dateFormat = "yyyyMMdd-HHmmss"
                    var stamp = Date()
                    var rotated = paths.logs.appendingPathComponent("events-\(formatter.string(from: stamp)).jsonl")
                    while fm.fileExists(atPath: rotated.path) {
                        stamp.addTimeInterval(1)
                        rotated = paths.logs.appendingPathComponent("events-\(formatter.string(from: stamp)).jsonl")
                    }
                    try fm.moveItem(at: file, to: rotated)
                    let old = try fm.contentsOfDirectory(at: paths.logs, includingPropertiesForKeys: nil)
                        .filter { $0.lastPathComponent.hasPrefix("events-") && $0.pathExtension == "jsonl" }
                        .sorted { $0.lastPathComponent > $1.lastPathComponent }
                    for url in old.dropFirst(5) { try? fm.removeItem(at: url) }
                }
                var safe = e
                if let project = safe.detail["project"] { safe.detail["project"] = URL(fileURLWithPath: project).lastPathComponent }
                safe.detail = safe.detail.mapValues { String($0.prefix(300)) }
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                var data = try encoder.encode(safe)
                data.append(10)
                let fd = open(file.path, O_CREAT | O_WRONLY | O_APPEND, 0o600)
                guard fd >= 0 else { return }
                defer { close(fd) }
                data.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else { break }
                        offset += count
                    }
                }
            } catch { }
        }
    }

    public static func log(_ kind: String, job: String? = nil, harness: String? = nil, model: String? = nil, _ detail: [String: String] = [:], paths: HubPaths, now: Date = Date()) {
        record(ActivityEvent(ts: now, kind: kind, job: job, harness: harness, model: model, detail: detail), paths: paths)
    }

    public static func read(paths: HubPaths, since: Date? = nil, limit: Int = 500) -> [ActivityEvent] {
        guard limit > 0, let data = try? Data(contentsOf: paths.logs.appendingPathComponent("events.jsonl")) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return Array(data.split(separator: 10).compactMap { try? decoder.decode(ActivityEvent.self, from: Data($0)) }
            .filter { since == nil || $0.ts >= since! }.suffix(limit))
    }

    public static func stats(_ events: [ActivityEvent]) -> ActivityStats {
        var result = ActivityStats()
        var durations: [String: [Double]] = [:]
        for e in events {
            if let model = e.model, e.kind == "job.started" || e.kind == "job.finished" {
                var value = result.models[model] ?? ActivityStats.Model()
                if e.kind == "job.started" { value.started += 1 }
                else {
                    switch e.detail["state"] {
                    case "verified": value.verified += 1
                    case "failed", "needs_review": value.failed += 1
                    case "queued": value.queuedBack += 1
                    default: break
                    }
                    if let seconds = e.detail["seconds"].flatMap(Double.init) { durations[model, default: []].append(seconds) }
                }
                result.models[model] = value
            }
            switch e.kind {
            case "masked.mask": result.masked.attempted += 1
            case "masked.decode": if e.detail["result"] == "ok" { result.masked.passed += 1 }
            case "masked.fallback":
                result.masked.fallbacks += 1
                result.masked.fallbackReasons[String((e.detail["reason"] ?? "unknown").prefix(60)), default: 0] += 1
            case "policy.handoff": result.handoffs += 1
            case "policy.wrapup": result.wrapUps += 1
            case "cooldown": result.cooldowns += 1
            default: break
            }
        }
        for (model, seconds) in durations { result.models[model]?.avgSeconds = seconds.reduce(0, +) / Double(seconds.count) }
        return result
    }

    // Compare against the last emitted reading, across CLI processes and GUI ticks.
    static func usage(_ readings: [String: UsageReading], paths: HubPaths, now: Date) {
        FileStore.withLock(paths, "activity-usage") {
            let file = paths.logs.appendingPathComponent("activity-usage.json")
            var previous = FileStore.read([String: Double].self, from: file) ?? [:]
            for (harness, reading) in readings {
                guard let left = reading.left else { continue }
                let percent = left * 100
                if previous[harness] == nil || abs(percent - previous[harness]!) >= 5 {
                    log("usage", harness: harness, ["percentLeft": String(format: "%.1f", percent)], paths: paths, now: now)
                    previous[harness] = percent
                }
            }
            try? FileStore.write(previous, to: file)
        }
    }

    public static func queued(_ job: Job, paths: HubPaths) {
        log("job.queued", job: job.id, ["size": job.size.rawValue, "kind": job.kind.rawValue, "privacy": job.privacy.rawValue, "project": URL(fileURLWithPath: job.project).lastPathComponent], paths: paths, now: job.created)
    }
}
