import Foundation

/// Installs and uninstalls Agent Hub hooks for all four harnesses.
public struct HookInstaller: Sendable {
    public var claudeSettings: URL
    public var codexHooks: URL
    public var geminiDirs: [URL]
    public var opencodeConfigDir: URL
    public var livePath: URL
    public var ctlPath: String

    public init(
        claudeSettings: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json"),
        codexHooks: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/hooks.json"),
        ctlPath: String,
        geminiDirs: [URL]? = nil,
        opencodeConfigDir: URL? = nil,
        livePath: URL = HubPaths().live
    ) {
        self.claudeSettings = claudeSettings
        self.codexHooks = codexHooks
        self.ctlPath = ctlPath
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.geminiDirs = geminiDirs ?? ["antigravity", "antigravity-cli", "antigravity-ide"].map { home.appendingPathComponent(".gemini/" + $0) }
        self.opencodeConfigDir = opencodeConfigDir ?? home.appendingPathComponent(".config/opencode")
        self.livePath = livePath
    }

    /// Replaces our hooks and retired bridges while preserving unrelated configuration.
    /// Existing configuration files are backed up once before migration.
    @discardableResult
    public func install() throws -> [String] {
        var messages: [String] = []
        for (harness, file) in [("claude", claudeSettings), ("codex", codexHooks)] {
            try backupIfNeeded(file)
            var root = try readJSON(from: file) ?? [:]
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            for key in Array(hooks.keys) {
                if let groups = hooks[key] as? [Any] { hooks[key] = groups.filter { !isRetiredGroup($0) } }
            }
            for event in events(harness) {
                let item: [String: Any] = ["type": "command", "command": "\(Proc.quote(ctlPath)) hook \(harness) \(event)", "timeout": event == "PermissionRequest" ? 600 : 10]
                var group: [String: Any] = ["hooks": [item]]
                if ["PreToolUse", "PostToolUse", "PermissionRequest"].contains(event) { group["matcher"] = "*" }
                hooks[event] = updateHookGroups(existing: hooks[event] as? [Any] ?? [], replacement: group)
            }
            root["hooks"] = hooks
            try writeJSON(root, to: file)
            messages.append("Installed hooks into \(file.path)")
        }
        for dir in geminiDirs where FileManager.default.fileExists(atPath: dir.path) {
            let file = dir.appendingPathComponent("hooks.json")
            try backupIfNeeded(file)
            var root = try readJSON(from: file) ?? [:]
            root.removeValue(forKey: "notch-agents")
            func command(_ event: String) -> [String: Any] {
                ["type": "command", "command": "\(Proc.quote(ctlPath)) hook antigravity \(event)", "timeout": 5]
            }
            root["agent-hub"] = ["enabled": true, "PreInvocation": [command("PreInvocation")], "PostToolUse": [["matcher": "*", "hooks": [command("PostToolUse")]]], "Stop": [command("Stop")]]
            try writeJSON(root, to: file)
            messages.append("Installed hooks into \(file.path)")
        }
        if FileManager.default.fileExists(atPath: opencodeConfigDir.path) {
            let dir = opencodeConfigDir.appendingPathComponent("plugin")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let old = dir.appendingPathComponent("notch-agents.js")
            if FileManager.default.fileExists(atPath: old.path) {
                // Never overwrite an earlier migration backup.
                var backup = dir.appendingPathComponent("notch-agents.js.bak-agenthub")
                if FileManager.default.fileExists(atPath: backup.path) { backup = dir.appendingPathComponent("notch-agents.js.bak-agenthub-\(Int(Date().timeIntervalSince1970))") }
                try FileManager.default.moveItem(at: old, to: backup)
            }
            let plugin = dir.appendingPathComponent("agent-hub.js")
            try OpenCodePlugin.template(ctlPath: ctlPath, livePath: livePath.path).write(to: plugin, atomically: true, encoding: .utf8)
            messages.append("Installed plugin into \(plugin.path)")
        }
        return messages
    }

    private func events(_ harness: String) -> [String] {
        ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse"] + (harness == "claude" ? ["Notification"] : []) + ["Stop", "SessionEnd", "PermissionRequest"]
    }
    private func isRetiredGroup(_ value: Any) -> Bool {
        guard let group = value as? [String: Any] else { return false }
        let items = (group["hooks"] as? [[String: Any]] ?? []) + [group]
        return items.contains { item in
            let cmd = item["command"] as? String ?? ""
            return cmd.contains("notch-agent-bridge") || cmd.contains("agent-hub/startup/hub-hook.py")
        }
    }

    /// Sets statusLine = {"type":"command","command":"'<ctlPath>' statusline"} in Claude settings.
    /// Only does so when there is none or existing contains agenthubctl, or when force is set;
    /// otherwise returns a message explaining what is there without changing the file.
    @discardableResult
    public func installStatusLine(force: Bool = false) throws -> String {
        let commandStr = "\(Proc.quote(ctlPath)) statusline"
        let statusLineObj: [String: Any] = [
            "type": "command",
            "command": commandStr
        ]

        guard let existingClaude = try readJSON(from: claudeSettings) else {
            let root: [String: Any] = ["statusLine": statusLineObj]
            try writeJSON(root, to: claudeSettings)
            return "Installed statusLine into \(claudeSettings.path)"
        }

        var root = existingClaude
        if let existing = root["statusLine"] {
            let isOurs = isOurStatusLine(existing)
            if !isOurs && !force {
                let desc: String
                if let data = try? JSONSerialization.data(withJSONObject: existing, options: [.fragmentsAllowed]),
                   let str = String(data: data, encoding: .utf8) {
                    desc = str
                } else {
                    desc = "\(existing)"
                }
                return "Refused: existing statusLine is configured: \(desc). Use force: true to overwrite."
            }
        }

        try backupIfNeeded(claudeSettings)
        root["statusLine"] = statusLineObj
        try writeJSON(root, to: claudeSettings)
        return "Installed statusLine into \(claudeSettings.path)"
    }

    /// Removes only the agenthubctl groups (and the status line if it is ours).
    public func uninstall() throws {
        // 1. Claude settings
        if let existingClaude = try readJSON(from: claudeSettings) {
            var root = existingClaude
            var modified = false

            if let st = root["statusLine"], isOurStatusLine(st) {
                root.removeValue(forKey: "statusLine")
                modified = true
            }

            if var hooks = root["hooks"] as? [String: Any] {
                for (event, val) in hooks {
                    if let groups = val as? [Any] {
                        let remaining = groups.filter { !isAgentHubGroup($0) }
                        if remaining.count != groups.count {
                            hooks[event] = remaining
                            modified = true
                        }
                    }
                }
                if modified {
                    root["hooks"] = hooks
                }
            }

            if modified {
                try writeJSON(root, to: claudeSettings)
            }
        }

        // 2. Codex hooks
        if let existingCodex = try readJSON(from: codexHooks) {
            var root = existingCodex
            var modified = false

            if var hooks = root["hooks"] as? [String: Any] {
                for (event, val) in hooks {
                    if let groups = val as? [Any] {
                        let remaining = groups.filter { !isAgentHubGroup($0) }
                        if remaining.count != groups.count {
                            hooks[event] = remaining
                            modified = true
                        }
                    }
                }
                if modified {
                    root["hooks"] = hooks
                }
            }

            if modified {
                try writeJSON(root, to: codexHooks)
            }
        }

        for dir in geminiDirs {
            let file = dir.appendingPathComponent("hooks.json")
            if var root = try readJSON(from: file), root.removeValue(forKey: "agent-hub") != nil { try writeJSON(root, to: file) }
        }
        let plugin = opencodeConfigDir.appendingPathComponent("plugin/agent-hub.js")
        if FileManager.default.fileExists(atPath: plugin.path) { try FileManager.default.removeItem(at: plugin) }
    }

    /// Reports whether each file has our hooks.
    public func status() -> [String: Bool] {
        let claude = hasOurHooks(at: claudeSettings)
        let codex = hasOurHooks(at: codexHooks)
        return [
            "claude": claude,
            "codex": codex,
            "antigravity": geminiDirs.contains { dir in
                guard let root = try? readJSON(from: dir.appendingPathComponent("hooks.json")) else { return false }
                return root["agent-hub"] != nil
            },
            "opencode": FileManager.default.fileExists(atPath: opencodeConfigDir.appendingPathComponent("plugin/agent-hub.js").path),
            claudeSettings.path: claude,
            codexHooks.path: codex
        ]
    }

    /// Creates or replaces a symlink to ctlPath.
    public func installCLILink(
        at destination: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/agenthubctl")
    ) throws {
        let dir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var sb = stat()
        if lstat(destination.path, &sb) == 0 {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.createSymbolicLink(atPath: destination.path, withDestinationPath: ctlPath)
    }

    // MARK: - Helpers

    private func backupIfNeeded(_ fileURL: URL) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let backupURL = URL(fileURLWithPath: fileURL.path + ".bak-agenthub")
        guard !FileManager.default.fileExists(atPath: backupURL.path) else { return }
        try FileManager.default.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fileURL, to: backupURL)
    }

    private func readJSON(from url: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [:] }
        let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed, .mutableContainers])
        guard let dict = obj as? [String: Any] else {
            throw HubError.invalid("Root of \(url.path) is not a JSON object")
        }
        return dict
    }

    private func writeJSON(_ dict: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    private func updateHookGroups(existing: [Any], replacement: [String: Any]) -> [Any] {
        var result: [Any] = []
        var replaced = false
        for g in existing {
            if isAgentHubGroup(g) {
                if !replaced {
                    result.append(replacement)
                    replaced = true
                }
            } else {
                result.append(g)
            }
        }
        if !replaced {
            result.append(replacement)
        }
        return result
    }

    private func isAgentHubGroup(_ group: Any) -> Bool {
        guard let dict = group as? [String: Any] else { return false }
        if let cmd = dict["command"] as? String, isOurCommand(cmd) {
            return true
        }
        if let hooks = dict["hooks"] as? [Any] {
            for h in hooks {
                if let hDict = h as? [String: Any], let cmd = hDict["command"] as? String, isOurCommand(cmd) {
                    return true
                }
            }
        }
        return false
    }

    private func isOurStatusLine(_ value: Any) -> Bool {
        if let dict = value as? [String: Any], let cmd = dict["command"] as? String {
            return isOurCommand(cmd)
        }
        if let s = value as? String {
            return isOurCommand(s)
        }
        return false
    }

    private func isOurCommand(_ cmd: String) -> Bool {
        if cmd.contains("agenthubctl") { return true }
        if !ctlPath.isEmpty && cmd.contains(ctlPath) { return true }
        return false
    }

    private func hasOurHooks(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any]
        else {
            return false
        }
        let events = events(url == claudeSettings ? "claude" : "codex")
        return events.allSatisfy { event in
            guard let groups = hooks[event] as? [Any] else { return false }
            return groups.contains { isAgentHubGroup($0) }
        }
    }
}
