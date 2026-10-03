import Foundation
import Darwin

public struct LiveLine: Codable, Equatable, Sendable {
    public var t: Double
    public var text: String
    public init(t: Double, text: String) { self.t = t; self.text = text }
}

public struct LiveAgent: Codable, Equatable, Sendable {
    public var id, type, description, status, activity: String
    public var startedAt: Double
    public var finishedAt: Double?
    public var recent: [LiveLine]?
    public init(id: String, type: String, description: String, status: String, activity: String, startedAt: Double, finishedAt: Double? = nil, recent: [LiveLine]? = nil) {
        self.id = id; self.type = type; self.description = description; self.status = status; self.activity = activity
        self.startedAt = startedAt; self.finishedAt = finishedAt; self.recent = recent
    }
}

public struct LiveSession: Codable, Equatable, Sendable {
    public var platform, platformName, sessionId, title, status, activity, app: String
    public var pid: Int?
    public var steps: Int
    public var startedAt, updatedAt: Double
    public var turnStartedAt, finishedAt: Double?
    public var cwd, project, model, lastPrompt, transcript: String?
    public var recent: [LiveLine]?
    public var agents: [LiveAgent]?
    public init(platform: String, platformName: String, sessionId: String, title: String, status: String, activity: String, app: String,
                pid: Int? = nil, steps: Int = 0, startedAt: Double, updatedAt: Double, turnStartedAt: Double? = nil,
                finishedAt: Double? = nil, cwd: String? = nil, project: String? = nil, model: String? = nil,
                lastPrompt: String? = nil, recent: [LiveLine]? = nil, agents: [LiveAgent]? = nil, transcript: String? = nil) {
        self.platform = platform; self.platformName = platformName; self.sessionId = sessionId; self.title = title
        self.status = status; self.activity = activity; self.app = app; self.pid = pid; self.steps = steps
        self.startedAt = startedAt; self.updatedAt = updatedAt; self.turnStartedAt = turnStartedAt; self.finishedAt = finishedAt
        self.cwd = cwd; self.project = project; self.model = model; self.lastPrompt = lastPrompt; self.recent = recent; self.agents = agents
        self.transcript = transcript
    }
}

public struct LiveRequest: Codable, Sendable {
    public var id, platform, platformName, sessionId, kind, title, detail, tool, app, cwd, header: String
    public var canAnswer: Bool
    public var options, choices: [String]
    public var holdUntil: Double?
    public var createdAt: Double
    public var externalId: String?
}

public struct LiveFeed: Sendable {
    public let paths: HubPaths
    public let pollInterval: TimeInterval
    public init(paths: HubPaths, pollInterval: TimeInterval = 0.15) {
        self.paths = paths; self.pollInterval = max(0.001, pollInterval)
    }
    static let names = ["claude": "Claude Code", "codex": "Codex", "antigravity": "Antigravity", "opencode": "OpenCode"]
    public static func hostApp(env: [String: String], platform: String) -> String {
        if let b = env["__CFBundleIdentifier"], !b.isEmpty, !["com.apple.python3", "org.python.python"].contains(b) { return b }
        let terms = ["Apple_Terminal": "com.apple.Terminal", "iTerm.app": "com.googlecode.iterm2", "WarpTerminal": "dev.warp.Warp-Stable", "ghostty": "com.mitchellh.ghostty", "WezTerm": "com.github.wez.wezterm", "vscode": "com.microsoft.VSCode"]
        return terms[env["TERM_PROGRAM"] ?? ""] ?? ["claude": "com.anthropic.claudefordesktop", "codex": "com.openai.codex", "antigravity": "com.google.antigravity", "opencode": "com.apple.Terminal"][platform] ?? ""
    }
    static func clip(_ value: Any?, _ limit: Int = 160) -> String {
        let s = text(value).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return s.count <= limit ? s : String(s.prefix(limit - 1)) + "…"
    }
    static func text(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if let a = value as? [Any] { return a.map { text($0) }.joined(separator: " ") }
        return String(describing: value)
    }
    static func shortPath(_ value: String) -> String {
        let s = String(value.reversed().drop(while: { $0 == "/" }).reversed())
        return s.split(separator: "/").last.map(String.init) ?? value
    }
    static func first(_ args: [String: Any], _ keys: [String]) -> Any? {
        keys.compactMap { args[$0] }.first { !text($0).isEmpty }
    }
    static func describeTool(_ tool: String, _ args: [String: Any]) -> String {
        let t = tool.lowercased(), cmd = first(args, ["command", "cmd", "CommandLine", "commandLine"])
        let path = text(first(args, ["file_path", "filePath", "path", "TargetFile", "AbsolutePath"]))
        if let cmd, ["bash", "shell", "exec_command", "local_shell", "run_command", "unified_exec", ""].contains(t) || t.contains("command") { return "Running \(clip(cmd, 90))" }
        if ["edit", "multiedit", "write", "apply_patch", "write_to_file", "replace_file_content", "multi_replace_file_content", "patch"].contains(t) { return path.isEmpty ? "Editing files" : "Editing \(shortPath(path))" }
        if ["read", "view_file", "view_file_outline", "notebookread"].contains(t) { return path.isEmpty ? "Reading files" : "Reading \(shortPath(path))" }
        if ["grep", "glob", "grep_search", "find_by_name", "list_dir", "codebase_search", "list", "search"].contains(t) {
            let q = clip(first(args, ["pattern", "Query", "query"]), 60)
            return q.isEmpty ? "Searching the codebase" : "Searching \(q)"
        }
        if ["webfetch", "websearch", "read_url_content", "search_web", "web_search"].contains(t) { return "Browsing \(clip(first(args, ["url", "query", "Url"]), 60))".trimmingCharacters(in: .whitespaces) }
        if ["task", "agent", "spawn_agent"].contains(t) { return "Delegating: \(clip(first(args, ["description", "prompt"]) ?? "subagent", 70))" }
        if ["todowrite", "update_plan", "task_boundary"].contains(t) { return "Updating plan" }
        if t.hasPrefix("mcp__") { let p = t.components(separatedBy: "__"); return "Using \(p[1]) · \(p.last!)" }
        if t.hasPrefix("browser_") { return "Using the browser" }
        return tool.isEmpty ? "Working" : "Using \(tool)"
    }
    static func verbFor(_ tool: String) -> String {
        let t = tool.lowercased()
        if ["bash", "shell", "exec_command", "local_shell", "run_command", "unified_exec"].contains(t) { return "run a command" }
        if ["edit", "multiedit", "write", "apply_patch", "write_to_file", "patch"].contains(t) { return "edit a file" }
        if ["webfetch", "websearch", "read_url_content"].contains(t) { return "use the web" }
        if t.hasPrefix("mcp__") { return "use \(t.components(separatedBy: "__")[1])" }
        return tool.isEmpty ? "continue" : "use \(tool)"
    }
    static func readableArgs(_ args: [String: Any]) -> String {
        args.keys.sorted().compactMap { key -> String? in
            let v = args[key]!
            guard v is String || v is NSNumber, !text(v).trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let value = (v as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() ? ($0.boolValue ? "True" : "False") : text(v) } ?? text(v)
            return "\(key.replacingOccurrences(of: "_", with: " ")): \(value)"
        }.prefix(3).joined(separator: " · ")
    }
    static func requestSummary(_ platform: String, _ tool: String, _ args: [String: Any]) -> (String, String) {
        let detail = first(args, ["command", "cmd", "CommandLine", "file_path", "filePath", "url", "pattern"]) ?? readableArgs(args)
        return ("\(names[platform] ?? platform) wants to \(verbFor(tool))", clip(detail, 400))
    }
    static func questionFromArgs(_ args: [String: Any]) -> (String, String, [String]) {
        let qs = args["questions"] as? [[String: Any]] ?? [], q = qs.first ?? [:]
        var header = clip(q["header"], 40)
        if qs.count > 1 { header = header.isEmpty ? "+\(qs.count - 1) more question\(qs.count > 2 ? "s" : "")" : "\(header) · +\(qs.count - 1) more" }
        let choices = (q["options"] as? [Any] ?? []).compactMap { o -> String? in
            let s = text((o as? [String: Any])?["label"] ?? (o is String ? o : nil))
            return s.isEmpty ? nil : clip(s, 40)
        }
        return (clip(first(q, ["question", "header"]) ?? "Has a question for you", 300), header, Array(choices.prefix(6)))
    }
    private func url(_ part: String) -> URL { paths.live.appendingPathComponent(part) }
    private func ensure() throws {
        for d in ["", "sessions", "requests", "responses", "platforms"] {
            try FileManager.default.createDirectory(at: url(d), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url(d).path)
        }
    }
    private func write(_ object: [String: Any], _ file: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        let tmp = file.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw HubError.invalid("Cannot write live feed") }
        guard rename(tmp.path, file.path) == 0 else { throw HubError.invalid("Cannot replace live feed") }
    }
    private func read(_ file: URL) -> [String: Any] {
        guard let d = try? Data(contentsOf: file), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }
    private func files(_ dir: String) -> [URL] { (try? FileManager.default.contentsOfDirectory(at: url(dir), includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "json" } ?? [] }
    private func sessionFile(_ p: String, _ sid: String) -> URL {
        let safe = String(sid.map { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) ? $0 : "_" }.prefix(120))
        return url("sessions/\(p)-\(safe.isEmpty ? "unknown" : safe).json")
    }
    private func clear(_ p: String, _ sid: String, passive: Bool = true, kinds: [String]? = nil) {
        for f in files("requests") { let r = read(f)
            if r["platform"] as? String == p && r["sessionId"] as? String == sid && (!passive || r["canAnswer"] as? Bool != true) && (kinds == nil || kinds!.contains(r["kind"] as? String ?? "")) { try? FileManager.default.removeItem(at: f) }
        }
    }
    public func hubAlive(now: Date = Date()) -> Bool { now.timeIntervalSince1970 - (read(url("hub.json"))["alive_at"] as? Double ?? 0) < 6 }
    public func notchState(now: Date = Date()) -> (alive: Bool, hold: Bool, holdSeconds: Double) {
        let s = read(url("notch.json"))
        return (now.timeIntervalSince1970 - (s["alive_at"] as? Double ?? 0) < 6, s["hold_permissions"] as? Bool ?? true, max(5, min(540, s["hold_seconds"] as? Double ?? 45)))
    }
    public func respond(requestId: String, decision: String) {
        guard ["allow", "always", "deny", "app"].contains(decision), requestId.range(of: "^[a-z]+-[a-f0-9]{12}$", options: .regularExpression) != nil else { return }
        try? ensure(); try? write(["decision": decision], url("responses/\(requestId).json"))
    }
    public func writeHeartbeat(jobs: [Job], usage: [String: UsageReading], bands: [String: String], hooks: [String: Bool], now: Date = Date()) {
        let js: [[String: Any]] = jobs.map { ["id": $0.id, "harness": $0.harness ?? "", "model": $0.model ?? "", "objective": Self.clip($0.objective, 160), "project": Self.shortPath($0.project), "started": ($0.started ?? $0.created).timeIntervalSince1970] }
        var us: [String: Any] = [:]
        for h in Set(usage.keys).union(bands.keys) { us[h] = ["left": usage[h]?.left as Any? ?? NSNull(), "band": bands[h] ?? "unknown"] }
        try? ensure(); try? write(["alive_at": now.timeIntervalSince1970, "jobs": js, "usage": us, "hooks": Dictionary(uniqueKeysWithValues: Self.names.keys.map { ($0, hooks[$0] ?? false) })], url("hub.json"))
    }
    public func markStopped() { var s = read(url("hub.json")); s["alive_at"] = 0; try? ensure(); try? write(s, url("hub.json")) }
    public func shouldLaunchHub(now: Date = Date()) -> Bool {
        FileStore.withLock(paths, "live-launch") {
            guard !hubAlive(now: now) else { return false }
            let file = url("launch-attempt"), last = read(file)["at"] as? Double
            if let last, now.timeIntervalSince1970 - last < 15 { return false }
            do { try ensure(); try write(["at": now.timeIntervalSince1970], file); return true } catch { return false }
        }
    }
    public func sessions(now: Date = Date()) -> [LiveSession] {
        return files("sessions").compactMap { f in
            guard let d = try? Data(contentsOf: f), let s = try? JSONDecoder().decode(LiveSession.self, from: d) else { return nil }
            if PolicyEngine.isInternalBackgroundPath(s.cwd ?? "") {
                try? FileManager.default.removeItem(at: f)
                clear(s.platform, s.sessionId, passive: false)
                return nil
            }
            let age = now.timeIntervalSince1970 - s.updatedAt
            let dead = s.pid.map { $0 > 0 && kill(Int32(clamping: $0), 0) != 0 && errno == ESRCH } ?? false
            if dead || age > 86400 || (["done", "error"].contains(s.status) && age > 300) { try? FileManager.default.removeItem(at: f); clear(s.platform, s.sessionId, passive: false); return nil }
            return s
        }
    }
    public func requests(now: Date = Date()) -> [LiveRequest] {
        files("requests").compactMap { f in
            guard let d = try? Data(contentsOf: f), let r = try? JSONDecoder().decode(LiveRequest.self, from: d) else { return nil }
            if now.timeIntervalSince1970 - r.createdAt > 1800 { try? FileManager.default.removeItem(at: f); return nil }
            return r
        }
    }
    public func handle(platform p: String, event: String, payload d: [String: Any], env: [String: String], pid: Int32?, now: Date = Date()) -> [String: Any]? {
        guard env[HubPaths.workerEnv] == nil else { return nil }
        guard Self.names[p] != nil else { return nil }
        do { return try process(p, event, d, env, pid, now) } catch { return p == "antigravity" ? [:] : nil }
    }
    private func process(_ p: String, _ e: String, _ d: [String: Any], _ env: [String: String], _ pid: Int32?, _ now: Date) throws -> [String: Any]? {
        try ensure()
        let time = now.timeIntervalSince1970, app = Self.hostApp(env: env, platform: p)
        try write(["platform": p, "lastEventAt": time, "lastEvent": e], url("platforms/\(p).json"))
        let sid = Self.text(Self.first(d, p == "opencode" ? ["sessionID"] : p == "antigravity" ? ["conversationId"] : ["session_id", "thread_id"]) ?? "default")
        let cwd = p == "antigravity" ? (d["workspacePaths"] as? [String])?.first ?? "" : Self.text(d[p == "opencode" ? "directory" : "cwd"])
        let file = sessionFile(p, sid)
        let existing = read(file)

        let effectiveCwd = !cwd.isEmpty ? cwd : (existing["cwd"] as? String ?? "")
        let payloadModel = p == "antigravity" ? (d["modelName"] as? String) : (d["model"] as? String)
        let effectiveModel = (payloadModel != nil && !payloadModel!.isEmpty) ? payloadModel : (existing["model"] as? String)

        if PolicyEngine.isInternalBackgroundPath(effectiveCwd) {
            return p == "antigravity" ? [:] : nil
        }

        let project = Self.shortPath(!effectiveCwd.isEmpty ? effectiveCwd : cwd)
        func update(_ fields: [String: Any]) throws {
            var s = read(file)
            if s.isEmpty {
                s = ["platform": p, "platformName": Self.names[p]!, "sessionId": sid, "startedAt": time, "title": "", "status": "idle", "activity": "", "app": app, "pid": pid.map { Int($0) } ?? 0, "steps": 0]
                if !effectiveCwd.isEmpty { s["cwd"] = effectiveCwd; s["project"] = project }
                if let em = effectiveModel, !em.isEmpty { s["model"] = em }
                Activity.log("live.session", harness: p, ["event": "start", "project": project], paths: paths, now: now)
            }
            for (k, v) in fields where !(v is NSNull) && (v as? String != "") { s[k] = v }
            if !effectiveCwd.isEmpty && (s["cwd"] == nil || s["cwd"] as? String == "") { s["cwd"] = effectiveCwd; s["project"] = project }
            if let em = effectiveModel, !em.isEmpty && (s["model"] == nil || s["model"] as? String == "") { s["model"] = em }
            if p == "claude" || p == "codex", let activity = fields["activity"] as? String {
                var recent = (s["recent"] as? [[String: Any]] ?? []).compactMap { line -> LiveLine? in
                    guard let t = line["t"] as? Double, let text = line["text"] as? String else { return nil }
                    return LiveLine(t: t, text: text)
                }
                if recent.last?.text != activity { recent.append(LiveLine(t: time, text: activity)) }
                s["recent"] = Array(recent.suffix(12)).map { ["t": $0.t, "text": $0.text] }
            }
            if fields["status"] as? String == "working", s["turnStartedAt"] == nil || s["turnStartedAt"] is NSNull { s["turnStartedAt"] = time }
            if ["idle", "done", "error"].contains(fields["status"] as? String ?? "") { s["turnStartedAt"] = NSNull() }
            s["updatedAt"] = time; try write(s, file)
        }
        func request(_ kind: String, _ title: String, _ detail: String, tool: String = "", answer: Bool = false, options: [String] = [], until: Double? = nil, choices: [String] = [], header: String = "") throws -> [String: Any] {
            if p != "opencode" { clear(p, sid, passive: false) }
            let id = "\(p)-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))"
            let r: [String: Any] = ["id": id, "platform": p, "platformName": Self.names[p]!, "sessionId": sid, "kind": kind, "title": title, "detail": detail, "tool": tool, "canAnswer": answer, "options": options, "holdUntil": until as Any? ?? NSNull(), "createdAt": time, "app": app, "cwd": cwd, "choices": choices, "header": header]
            try write(r, url("requests/\(id).json")); return r
        }
        func has(_ kind: String) -> Bool { files("requests").contains { let r = read($0); return r["platform"] as? String == p && r["sessionId"] as? String == sid && r["kind"] as? String == kind } }
        func question(_ args: [String: Any]) throws {
            let (q, h, choices) = Self.questionFromArgs(args)
            _ = try request("question", q, h, choices: choices, header: h)
            try update(["status": "waiting", "activity": "Waiting for your answer"])
        }
        func permissionLog(_ tool: String, _ outcome: String) { Activity.log("live.permission", harness: p, ["tool": tool, "outcome": outcome], paths: paths, now: now) }
        let context: [String: Any] = ["cwd": effectiveCwd.isEmpty ? cwd : effectiveCwd, "project": project, "model": effectiveModel ?? d["model"] ?? "", "transcript": d["transcript_path"] ?? ""]
        if p == "claude" || p == "codex" {
            let tool = Self.text(d["tool_name"]), args = d["tool_input"] as? [String: Any] ?? [:]
            func saveAgents(_ agents: [LiveAgent]) throws {
                let encoded = try JSONEncoder().encode(agents)
                let value = try JSONSerialization.jsonObject(with: encoded) as? [[String: Any]] ?? []
                try update(["agents": value])
            }
            func prunedAgents(_ raw: Any?) -> [LiveAgent] {
                let encoded = (try? JSONSerialization.data(withJSONObject: raw ?? [])) ?? Data("[]".utf8)
                let agents = (try? JSONDecoder().decode([LiveAgent].self, from: encoded)) ?? []
                return Array(agents.filter { $0.status != "done" || time - ($0.finishedAt ?? time) <= 600 }.suffix(12))
            }
            if let existingAgents = read(file)["agents"] { try saveAgents(prunedAgents(existingAgents)) }
            let agentPayload = e == "PreToolUse" && !Self.text(d["agent_id"]).isEmpty
            if agentPayload {
                let agents = prunedAgents(read(file)["agents"])
                let agentType = Self.text(d["agent_type"])
                let index = agents.indices.reversed().first { agents[$0].status == "running" && (agentType.isEmpty || agents[$0].type == agentType) }
                    ?? agents.indices.reversed().first { agents[$0].status == "running" }
                if let index {
                    var updated = agents
                    let activity = Self.describeTool(tool, args)
                    updated[index].activity = activity
                    var recent = updated[index].recent ?? []
                    if recent.last?.text != activity { recent.append(LiveLine(t: time, text: activity)) }
                    updated[index].recent = Array(recent.suffix(12))
                    try saveAgents(updated)
                }
                try update(["steps": (read(file)["steps"] as? Int ?? 0) + 1])
                return nil
            }
            switch e {
            case "SessionStart": try update(context.merging(["status": "idle", "activity": "Session started"]) { _, n in n })
            case "UserPromptSubmit":
                clear(p, sid)
                let title = Self.text(read(file)["title"])
                try update(context.merging(["status": "working", "activity": "Thinking…", "title": title.isEmpty ? Self.clip(Self.text(d["prompt"]).components(separatedBy: .newlines).first, 80) : title, "lastPrompt": Self.clip(d["prompt"], 200)]) { _, n in n })
            case "PreToolUse":
                if ["Task", "Agent"].contains(tool) {
                    let description = Self.clip(args["description"] ?? args["prompt"], 80)
                    let agent = LiveAgent(id: Self.text(d["tool_use_id"]), type: Self.text(args["subagent_type"]).isEmpty ? "general-purpose" : Self.text(args["subagent_type"]), description: description, status: "running", activity: "Starting", startedAt: time)
                    var agents = prunedAgents(read(file)["agents"]); agents.append(agent)
                    try saveAgents(Array(agents.suffix(12)))
                    try update(context.merging(["status": "working", "activity": Self.describeTool(tool, args), "steps": (read(file)["steps"] as? Int ?? 0) + 1]) { _, n in n })
                } else {
                    try update(context.merging(["status": "working", "activity": Self.describeTool(tool, args), "steps": (read(file)["steps"] as? Int ?? 0) + 1]) { _, n in n })
                }
                if tool == "AskUserQuestion" { try question(args) }
            case "PostToolUse":
                if ["Task", "Agent"].contains(tool) {
                    var agents = prunedAgents(read(file)["agents"])
                    if let index = agents.indices.last(where: { agents[$0].id == Self.text(d["tool_use_id"]) }) { agents[index].status = "done"; agents[index].finishedAt = time }
                    try saveAgents(agents)
                }
                clear(p, sid); try update(["status": "working", "cwd": cwd, "project": project])
            case "Notification":
                let kind = Self.text(d["notification_type"]), msg = Self.clip(d["message"], 300)
                if has("question") { break }
                if kind == "permission_prompt" || msg.lowercased().contains("permission") {
                    if !has("permission") { _ = try request("permission", "\(Self.names[p]!) needs permission", msg); permissionLog("", "passive") }
                    try update(["status": "waiting", "activity": "Waiting for permission"])
                } else if kind == "elicitation_dialog" {
                    _ = try request("question", "\(Self.names[p]!) is asking", msg); try update(["status": "waiting", "activity": "Waiting for your answer"])
                } else if kind == "idle_prompt" {
                    clear(p, sid, kinds: ["attention"])
                    _ = try request("attention", "\(Self.names[p]!) is waiting for you", msg.isEmpty ? "Ready for your next message" : msg)
                    try update(["status": "idle", "activity": "Waiting for your input"])
                }
            case "Stop":
                clear(p, sid); let msg = Self.clip(d["last_assistant_message"])
                try update(["status": "done", "activity": msg.isEmpty ? "Finished" : msg, "finishedAt": time])
            case "SessionEnd":
                if FileManager.default.fileExists(atPath: file.path) {
                    let old = read(file); try FileManager.default.removeItem(at: file)
                    Activity.log("live.session", harness: p, ["event": "end", "project": old["project"] as? String ?? project], paths: paths, now: now)
                }
                clear(p, sid, passive: false)
            case "PermissionRequest":
                if tool == "AskUserQuestion" { if !has("question") { try question(args) }; return nil }
                let state = notchState(now: now), hold = state.alive && state.hold && hubAlive(now: now)
                let suggestions = d["permission_suggestions"] as? [Any] ?? []
                let (title, detail) = Self.requestSummary(p, tool, args)
                var r = try request("permission", title, detail, tool: tool, answer: hold, options: hold ? (suggestions.isEmpty ? ["allow", "deny"] : ["allow", "always", "deny"]) : [], until: hold ? time + state.holdSeconds : nil)
                try update(["status": "waiting", "activity": "Waiting: \(Self.verbFor(tool))"])
                guard hold else { permissionLog(tool, "passive"); return nil }
                let id = r["id"] as! String, rf = url("requests/\(id).json"), response = url("responses/\(id).json")
                let deadline = Date().addingTimeInterval(state.holdSeconds)
                var decision = ""
                while Date() < deadline {
                    let a = read(response)
                    if !a.isEmpty { try? FileManager.default.removeItem(at: response); decision = Self.text(a["decision"]); break }
                    if !notchState().alive || !hubAlive() || !FileManager.default.fileExists(atPath: rf.path) { break }
                    Thread.sleep(forTimeInterval: pollInterval)
                }
                if ["allow", "always", "deny"].contains(decision) {
                    try? FileManager.default.removeItem(at: rf)
                    try update(["status": "working", "activity": decision == "deny" ? "Permission denied in Notch" : Self.describeTool(tool, args)])
                    var body: [String: Any] = ["behavior": decision == "deny" ? "deny" : "allow"]
                    if decision == "deny" { body["message"] = "Denied from Notch." }
                    if decision == "always", !suggestions.isEmpty { body["updatedPermissions"] = suggestions }
                    permissionLog(tool, decision)
                    return ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": body]]
                }
                if FileManager.default.fileExists(atPath: rf.path) { r["canAnswer"] = false; r["options"] = [String](); r["holdUntil"] = NSNull(); try write(r, rf) }
                permissionLog(tool, "released")
            default: break
            }
        } else if p == "antigravity" {
            let tp = Self.text(d["transcriptPath"])
            let name = tp.contains("antigravity-cli") ? "Antigravity CLI" : tp.contains("antigravity-ide") ? "Antigravity IDE" : ""
            switch e {
            case "PreInvocation": try update(["status": "working", "activity": "Thinking…", "cwd": cwd, "project": project, "model": d["modelName"] ?? "", "platformName": name])
            case "PostToolUse":
                let call = d["toolCall"] as? [String: Any] ?? [:]
                let activity = call.isEmpty ? "Step \(Self.text(d["stepIdx"]))".trimmingCharacters(in: .whitespaces) : Self.describeTool(Self.text(call["name"]), call["args"] as? [String: Any] ?? [:])
                try update(["status": "working", "activity": activity, "cwd": cwd, "project": project, "platformName": name, "steps": (read(file)["steps"] as? Int ?? 0) + 1])
            case "Stop": let err = Self.clip(d["error"], 120); try update(["status": err.isEmpty && Self.text(d["terminationReason"]) != "error" ? "done" : "error", "activity": err.isEmpty ? "Finished" : err, "finishedAt": time, "platformName": name])
            default: break
            }
            return [:]
        } else {
            switch e {
            case "busy": try update(["status": "working", "activity": Self.first(d, ["activity"]) ?? "Thinking…", "cwd": cwd, "project": project, "title": Self.clip(d["title"], 80)])
            case "tool": try update(["status": "working", "activity": Self.describeTool(Self.text(d["tool"]), d["args"] as? [String: Any] ?? [:]), "cwd": cwd, "project": project, "steps": (read(file)["steps"] as? Int ?? 0) + 1])
            case "title": try update(["title": Self.clip(d["title"], 80)])
            case "idle": clear(p, sid, passive: false); try update(["status": "done", "activity": "Finished", "finishedAt": time])
            case "error": try update(["status": "error", "activity": Self.first(d, ["message"]).map { Self.clip($0, 120) } ?? "Error"])
            case "permission":
                let alive = notchState(now: now).alive && hubAlive(now: now), tool = Self.text(d["permission"])
                var r = try request("permission", Self.clip("OpenCode wants to \(tool.isEmpty ? "continue" : tool)", 90), Self.clip(d["detail"], 400), tool: tool, answer: alive, options: alive ? ["allow", "always", "deny"] : [])
                r["externalId"] = d["id"] ?? NSNull(); try write(r, url("requests/\(r["id"]!).json"))
                try update(["status": "waiting", "activity": "Waiting for permission", "cwd": cwd, "project": project]); permissionLog(tool, "passive")
                return ["requestId": r["id"]!]
            case "permission-replied":
                for f in files("requests") { let r = read(f); if r["platform"] as? String == p && Self.text(r["externalId"]) == Self.text(d["id"]) { try? FileManager.default.removeItem(at: f) } }
                try update(["status": "working", "activity": "Continuing"])
            case "question":
                let q = Self.clip(d["detail"], 300), h = Self.clip(d["header"], 40)
                _ = try request("question", q.isEmpty ? "OpenCode is asking" : q, h, choices: Array((d["choices"] as? [String] ?? []).filter { !$0.isEmpty }.prefix(6).map { Self.clip($0, 40) }), header: h)
                try update(["status": "waiting", "activity": "Waiting for your answer"])
            default: break
            }
        }
        return nil
    }
}
