import Foundation
import Darwin
import HubCore

func printJSON(_ object: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    print(String(decoding: data, as: UTF8.self))
}

func jsonObject<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(value))
}

func agentPID() -> Int32? {
    var pid = getppid()
    let shells: Set<String> = ["sh", "zsh", "bash", "dash", "fish", "env", "login"]
    var visited: Set<Int32> = []
    while pid > 1, visited.insert(pid).inserted {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let capacity = MemoryLayout.size(ofValue: info.kp_proc.p_comm)
        let name = withUnsafePointer(to: &info.kp_proc.p_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
        if !shells.contains(name) { return pid }
        pid = info.kp_eproc.e_ppid
    }
    return nil
}

func appIsRunning(_ paths: HubPaths, now: Date) -> Bool {
    guard let data = try? Data(contentsOf: paths.root.appendingPathComponent("engine.json")),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let text = object["heartbeat"] as? String else { return false }
    let formatter = ISO8601DateFormatter()
    var date = formatter.date(from: text)
    if date == nil {
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        date = formatter.date(from: text)
    }
    guard let date else { return false }
    return now.timeIntervalSince(date) <= 90
}

func run() throws -> Int32 {
    let a = try CLIArgs(Array(CommandLine.arguments.dropFirst()))
    let allowed: [String: Set<String>] = [
        "help": [], "hook": [], "statusline": [], "status": ["json"],
        "delegate": ["main", "size", "kind", "privacy", "project", "objective", "allowed-file", "check", "worktree", "wait", "dry-run", "offload"],
        "send": ["harness", "session", "message", "kind"],
        "handoff": ["from", "project", "file", "session", "to", "no-launch"],
        "sessions": ["all"], "tick": [], "install-hooks": ["statusline", "force"], "uninstall-hooks": []
    ]
    guard let permitted = allowed[a.subcommand] else { throw CLIArgs.invalid("Unknown command: \(a.subcommand)") }
    for key in Set(a.flags.keys).union(a.booleans).subtracting(permitted).sorted() {
        throw CLIArgs.invalid("Unknown flag for \(a.subcommand): --\(key)")
    }
    guard a.positionals.count == (a.subcommand == "hook" ? 2 : 0) else { throw CLIArgs.invalid("Unexpected or missing positional arguments") }
    if a.subcommand == "help" { print(CLIArgs.usage); return 0 }

    let paths = HubPaths()
    let config = ConfigStore.load(paths).config
    let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let ctlPath: String
    if let resolved = realpath(executable, nil) {
        ctlPath = String(cString: resolved)
        free(resolved)
    } else {
        ctlPath = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
    }
    let store = JobStore(paths: paths)
    let relay = Relay(paths: paths, config: config, ctlPath: ctlPath,
                      usageProvider: { UsageMeter(paths: paths).read(config, now: Date()) },
                      recentJobs: { project in
                          store.all().filter { $0.project == project }.prefix(5).map {
                              "\($0.id) \($0.state.rawValue) \($0.objective.prefix(80))"
                          }
                      })
    let now = Date()
    func snapshot() -> Snapshot {
        Snapshot(config: config, usage: UsageMeter(paths: paths).read(config, now: now),
                 sessions: relay.sessions(now: now), jobs: store.active(), now: now)
    }
    func sessionTable(_ sessions: [MainSession]) {
        print("harness\tsession\tmodel\tstatus\tlast seen\tcwd")
        for s in sessions.sorted(by: { $0.id < $1.id }) {
            print("\(s.harness)\t\(s.sessionId)\t\(s.model ?? "—")\t\(s.status.rawValue)\t\(ISO8601DateFormatter().string(from: s.lastSeen))\t\(s.cwd)")
        }
    }
    switch a.subcommand {
    case "hook":
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard var payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any], !payload.isEmpty else { return 0 }
        if let pid = agentPID() { payload["agent_pid"] = Int(pid) }
        if let result = relay.hook(a.positionals[0], event: a.positionals[1], payload: payload,
                                   env: ProcessInfo.processInfo.environment, now: now) {
            try printJSON(result)
        }
    case "statusline":
        print(UsageMeter.writeClaudeStatusline(stdinJSON: FileHandle.standardInput.readDataToEndOfFile(), paths: paths, now: now))
    case "status":
        let s = snapshot()
        let explain = PolicyEngine.explain(s)
        if a.has("json") {
            var usage: [String: Any] = [:]
            for h in config.harnesses {
                var reading = (try jsonObject(s.usage[h.id] ?? UsageReading(left: nil, source: "unknown"))) as! [String: Any]
                reading["band"] = String(describing: PolicyEngine.band(s, h.id))
                usage[h.id] = reading
            }
            try printJSON(["usage": usage, "sessions": try jsonObject(s.sessions), "jobs": try jsonObject(s.jobs), "explain": explain])
        } else {
            for h in config.harnesses {
                let r = s.usage[h.id]
                let left = r?.left.map { String(format: "%.0f%%", $0 * 100) } ?? "unknown"
                let windows = (r?.windows ?? []).map { "\($0.name) \(String(format: "%.0f", $0.usedPercent))% used" }.joined(separator: ", ")
                print("\(h.name): \(left) left · \(PolicyEngine.band(s, h.id)) · \(windows)")
            }
            sessionTable(s.sessions)
            for j in s.jobs { print("\(j.id)\t\(j.state.rawValue)\t\(j.objective)") }
            explain.forEach { print($0) }
        }
    case "delegate":
        let job = try CLIArgs.jobFromDelegateArgs(a, now: now)
        if a.has("dry-run") {
            if let plan = PolicyEngine.plan(snapshot(), job) {
                if let broker = plan.broker {
                    print("\(plan.worker.id) \(plan.worker.harness) (broker: \(broker.id))")
                } else {
                    print("\(plan.worker.id) \(plan.worker.harness)")
                }
            } else { print("none: no eligible worker has capacity for this job") }
            return 0
        }
        let queued = try store.enqueue(job, now: now)
        if a.has("wait") || !appIsRunning(paths, now: now) {
            var final = queued
            // A masked offload that is skipped comes back queued with offload off; run it once more on a trusted worker.
            for _ in 0..<2 {
                guard let plan = PolicyEngine.plan(snapshot(), final) else { break }
                var q = final
                q.broker = plan.broker?.id
                final = Runner(paths: paths, config: config).start(q, worker: plan.worker, now: Date())
                if final.state != .queued { break }
            }
            if final.state == .queued { try printJSON(jsonObject(final)); return 3 }
            try printJSON(jsonObject(final))
            switch final.state {
            case .verified: return 0
            case .queued, .running: return 3
            default: return 1
            }
        }
        try printJSON(["id": queued.id, "state": "queued"])
    case "send":
        guard let kind = MessageKind(rawValue: a.value("kind") ?? "message") else { throw CLIArgs.invalid("Invalid --kind") }
        let message = try relay.send(a.required("harness"), a.required("session"), a.required("message"), kind: kind, now: now)
        try printJSON(jsonObject(message))
    case "handoff":
        let record = try relay.handoff(from: a.required("from"), session: a.value("session"),
                                      project: URL(fileURLWithPath: a.required("project")).standardizedFileURL.path,
                                      file: a.required("file"), to: a.value("to"), launch: !a.has("no-launch"), automatic: false, now: now)
        try printJSON(jsonObject(record))
    case "sessions": sessionTable(relay.sessions(activeOnly: !a.has("all"), now: now))
    case "tick":
        MainActor.assumeIsolated {
            let engine = Engine(paths: paths, ctlPath: ctlPath)
            engine.tick(schedule: false)
            engine.explain.forEach { print($0) }
        }
    case "install-hooks":
        let installer = HookInstaller(ctlPath: ctlPath)
        try installer.install().forEach { print($0) }
        if a.has("statusline") { print(try installer.installStatusLine(force: a.has("force"))) }
    case "uninstall-hooks": try HookInstaller(ctlPath: ctlPath).uninstall()
    default: break
    }
    return 0
}

do { exit(try run()) }
catch {
    if CommandLine.arguments.dropFirst().first == "hook" { exit(0) }
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(2)
}
