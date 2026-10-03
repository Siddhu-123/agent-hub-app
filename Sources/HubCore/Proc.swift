import Foundation

/// Process helpers shared by every module. Owned by the orchestrator: workers must not edit this file.
public enum Proc {
    /// Runs argv (no shell) with a time bound. argv[0] may be a bare name; it is resolved with `resolve`.
    /// Output is truncated to the last `keep` characters. Never throws: launch failures return exit code 127.
    /// `onStart` receives the child PID right after launch (used for cancellation).
    public static func run(_ argv: [String], cwd: String? = nil, env: [String: String]? = nil, stdin: String? = nil,
                           timeout: TimeInterval = 120, keep: Int = 200_000, onStart: ((Int32) -> Void)? = nil,
                           onOutput: ((Data) -> Void)? = nil) -> CheckResult {
        guard let first = argv.first, let exe = resolve(first) else {
            return CheckResult(argv: argv, exitCode: 127, timedOut: false, output: "executable not found: \(argv.first ?? "")")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = Array(argv.dropFirst())
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var environment = env ?? ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath(environment["PATH"])
        // Node/Bun CLIs resolve their working directory from PWD, which is inherited from the parent otherwise.
        if let cwd { environment["PWD"] = cwd }
        p.environment = environment
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        let input = Pipe()
        p.standardInput = stdin == nil ? FileHandle.nullDevice : input
        let buffer = OutputBuffer(keep: keep)
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            buffer.append(d)
            onOutput?(d)
        }
        do { try p.run() } catch {
            out.fileHandleForReading.readabilityHandler = nil
            return CheckResult(argv: argv, exitCode: 127, timedOut: false, output: "launch failed: \(error.localizedDescription)")
        }
        onStart?(p.processIdentifier)
        if let stdin {
            DispatchQueue.global().async {
                try? input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
                try? input.fileHandleForWriting.close()
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while p.isRunning {
            if Date() > deadline {
                timedOut = true
                p.interrupt()
                Thread.sleep(forTimeInterval: 2)
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        p.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        let drain = out.fileHandleForReading.readDataToEndOfFile()
        if !drain.isEmpty {
            buffer.append(drain)
            onOutput?(drain)
        }
        return CheckResult(argv: argv, exitCode: timedOut ? -1 : p.terminationStatus, timedOut: timedOut, output: buffer.text)
    }

    /// Absolute path for an executable name. GUI apps start with a minimal PATH, so common user bin folders are searched too.
    public static func resolve(_ name: String) -> String? {
        let expanded = (name as NSString).expandingTildeInPath
        if expanded.contains("/") { return FileManager.default.isExecutableFile(atPath: expanded) ? expanded : nil }
        for dir in searchPath(ProcessInfo.processInfo.environment["PATH"]).split(separator: ":") {
            let candidate = "\(dir)/\(expanded)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        // Some CLIs ship only inside an app bundle.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for app in ["/Applications", "\(home)/Applications"] {
            for inner in bundled[expanded] ?? [] where FileManager.default.isExecutableFile(atPath: app + inner) { return app + inner }
        }
        return nil
    }

    static let bundled: [String: [String]] = [
        "codex": ["/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", "/Codex.app/Contents/Resources/codex"],
    ]

    public static func searchPath(_ current: String?) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["\(home)/.local/bin", "\(home)/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin",
                     "\(home)/.bun/bin", "\(home)/.cargo/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        return ((current ?? "").split(separator: ":").map(String.init) + extra).filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    /// POSIX shell single-quoting.
    public static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }

    /// Replaces {placeholders} in each argument. Unknown placeholders are left as is.
    public static func fill(_ template: [String], _ values: [String: String]) -> [String] {
        template.map { arg in values.reduce(arg) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) } }
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private var data = Data()
    private let keep: Int
    private let lock = NSLock()
    init(keep: Int) { self.keep = keep }
    func append(_ d: Data) {
        guard !d.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        data.append(d)
        if data.count > keep * 2 { data = data.suffix(keep) }
    }
    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(String(decoding: data, as: UTF8.self).suffix(keep))
    }
}
