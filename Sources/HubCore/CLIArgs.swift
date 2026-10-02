import Foundation

public struct CLIArgs {
    public let subcommand: String
    public private(set) var flags: [String: [String]] = [:]
    public private(set) var booleans: Set<String> = []
    public private(set) var positionals: [String] = []

    public static let usage = """
    Usage: agenthubctl <command> [options]
      hook <harness> <event>
      statusline
      status [--json]
      monitor [--follow] [--json]
      stats [--json]
      delegate --main MODEL --project DIR --objective TEXT --allowed-file FILE ...
               --check '["command","arg"]' [--size tiny|routine|hard]
               [--kind implement|review|plan] [--privacy project|generic]
               [--worktree] [--wait] [--dry-run] [--offload auto|always|never]
      send --harness HARNESS --session ID --message TEXT [--kind message|task|wrap_up]
      handoff --from HARNESS --project DIR --file FILE [--session ID] [--to MODEL] [--no-launch]
      sessions [--all]
      tick
      install-hooks [--statusline] [--force]
      uninstall-hooks
      help
    """

    public init(_ arguments: [String]) throws {
        subcommand = arguments.first ?? "help"
        let values: Set<String> = ["main", "size", "kind", "privacy", "project", "objective", "allowed-file", "check", "harness", "session", "message", "from", "file", "to", "offload"]
        let switches: Set<String> = ["json", "wait", "dry-run", "worktree", "all", "statusline", "force", "no-launch", "follow"]
        var i = 1
        while i < arguments.count {
            let token = arguments[i]
            if token == "--" {
                positionals.append(contentsOf: arguments.dropFirst(i + 1))
                break
            }
            if token.hasPrefix("-") {
                guard token.hasPrefix("--") else { throw Self.invalid("Unknown flag: \(token)") }
                let key = String(token.dropFirst(2))
                if switches.contains(key) {
                    booleans.insert(key)
                } else if values.contains(key) {
                    guard i + 1 < arguments.count, !arguments[i + 1].hasPrefix("--"), !arguments[i + 1].isEmpty else {
                        throw Self.invalid("Missing value for \(token)")
                    }
                    i += 1
                    flags[key, default: []].append(arguments[i])
                } else {
                    throw Self.invalid("Unknown flag: \(token)")
                }
            } else {
                positionals.append(token)
            }
            i += 1
        }
    }

    public func value(_ key: String) -> String? { flags[key]?.last }
    public func has(_ key: String) -> Bool { booleans.contains(key) }
    public func required(_ key: String) throws -> String {
        guard let value = value(key), !value.isEmpty else { throw Self.invalid("Missing --\(key)") }
        return value
    }
    public static func invalid(_ message: String) -> HubError { .invalid(message + "\n" + usage) }

    public static func jobFromDelegateArgs(_ a: CLIArgs, now: Date) throws -> Job {
        guard let size = JobSize(rawValue: a.value("size") ?? "routine") else { throw invalid("Invalid --size") }
        guard let kind = JobKind(rawValue: a.value("kind") ?? "implement") else { throw invalid("Invalid --kind") }
        guard let privacy = Privacy(rawValue: a.value("privacy") ?? "project") else { throw invalid("Invalid --privacy") }
        let checkText = try a.required("check")
        guard let check = try? JSONDecoder().decode([String].self, from: Data(checkText.utf8)) else {
            throw invalid("--check must be a JSON array of strings")
        }
        let project = URL(fileURLWithPath: try a.required("project")).standardizedFileURL.path
        guard let files = a.flags["allowed-file"], !files.isEmpty else { throw invalid("Missing --allowed-file") }
        var job = Job(id: JobStore.newId(now: now), project: project, objective: try a.required("objective"),
                   allowedFiles: files, checkArgv: check, size: size, kind: kind, privacy: privacy,
                   isolation: a.has("worktree") ? .worktree : .checkout,
                   mainModel: try a.required("main"), created: now)
        if let offload = a.value("offload") {
            switch offload {
            case "auto": job.offload = nil
            case "always": job.offload = true
            case "never": job.offload = false
            default: throw invalid("Invalid --offload (auto|always|never)")
            }
        }
        return job
    }
}
