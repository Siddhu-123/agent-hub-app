import Foundation

/// Where Agent Hub keeps its state. Owned by the orchestrator: workers must not edit this file.
/// Override the root with AGENT_HUB_HOME (tests always do).
public struct HubPaths: Sendable {
    public let root: URL

    public init(root: URL? = nil) {
        if let root { self.root = root }
        else if let env = ProcessInfo.processInfo.environment["AGENT_HUB_HOME"], !env.isEmpty { self.root = URL(fileURLWithPath: env) }
        else { self.root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AgentHub") }
    }

    public var config: URL { root.appendingPathComponent("config.json") }
    public var sessions: URL { root.appendingPathComponent("sessions") }
    public var inbox: URL { root.appendingPathComponent("inbox") }
    public var handoffs: URL { root.appendingPathComponent("handoffs") }
    public var jobs: URL { root.appendingPathComponent("jobs") }
    public var logs: URL { root.appendingPathComponent("logs") }
    public var cooldowns: URL { root.appendingPathComponent("cooldowns.json") }
    public var claudeUsage: URL { root.appendingPathComponent("usage-claude.json") }
    public var locks: URL { root.appendingPathComponent("locks") }

    /// The process env marker that tells hooks a session was started by the hub as a worker (not a main session).
    public static let workerEnv = "AGENT_HUB_WORKER"
}

public enum FileStore {
    /// Atomic JSON write (temp file + rename), creating parent folders.
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.encoder.encode(value).write(to: url, options: .atomic)
    }

    public static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONCoding.decoder.decode(type, from: data)
    }

    /// Runs body while holding an exclusive flock on <locks>/<name>.lock (serializes concurrent hook processes).
    public static func withLock<T>(_ paths: HubPaths, _ name: String, _ body: () throws -> T) rethrows -> T {
        try? FileManager.default.createDirectory(at: paths.locks, withIntermediateDirectories: true)
        let fd = open(paths.locks.appendingPathComponent("\(name).lock").path, O_CREAT | O_RDWR, 0o600)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        return try body()
    }

    /// File-name-safe key for a harness/session pair.
    public static func key(_ harness: String, _ session: String) -> String {
        let raw = "\(harness)-\(session)"
        return String(raw.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "_" }.prefix(160))
    }
}
