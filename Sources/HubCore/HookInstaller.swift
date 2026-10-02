import Foundation

/// Installs and uninstalls Agent Hub lifecycle hooks and status line into Claude Code and Codex configs.
public struct HookInstaller: Sendable {
    public var claudeSettings: URL
    public var codexHooks: URL
    public var ctlPath: String

    public init(
        claudeSettings: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json"),
        codexHooks: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/hooks.json"),
        ctlPath: String
    ) {
        self.claudeSettings = claudeSettings
        self.codexHooks = codexHooks
        self.ctlPath = ctlPath
    }

    /// Adds one hook group per event to each file: SessionStart, UserPromptSubmit, PostToolUse (Claude matcher "*"), Stop and SessionEnd.
    /// The command is '<ctlPath>' hook <harnessId> <Event>, with timeout 10.
    /// Before the first change it backs each file up as <file>.bak-agenthub.
    /// Idempotent: groups whose command contains agenthubctl are replaced, never duplicated.
    /// All other keys and hook groups are preserved byte-for-byte as JSON values.
    @discardableResult
    public func install() throws -> [String] {
        let events = ["SessionStart", "UserPromptSubmit", "PostToolUse", "Stop", "SessionEnd"]

        // 1. Claude settings
        try backupIfNeeded(claudeSettings)
        var claudeRoot = (try readJSON(from: claudeSettings)) ?? [:]
        var claudeHooks = (claudeRoot["hooks"] as? [String: Any]) ?? [:]
        for event in events {
            let commandStr = "\(Proc.quote(ctlPath)) hook claude \(event)"
            let hookItem: [String: Any] = [
                "type": "command",
                "command": commandStr,
                "timeout": 10
            ]
            var group: [String: Any] = [
                "hooks": [hookItem]
            ]
            if event == "PostToolUse" {
                group["matcher"] = "*"
            }
            let existingGroups = (claudeHooks[event] as? [Any]) ?? []
            claudeHooks[event] = updateHookGroups(existing: existingGroups, replacement: group)
        }
        claudeRoot["hooks"] = claudeHooks
        try writeJSON(claudeRoot, to: claudeSettings)

        // 2. Codex hooks
        try backupIfNeeded(codexHooks)
        var codexRoot = (try readJSON(from: codexHooks)) ?? [:]
        var codexHooksDict = (codexRoot["hooks"] as? [String: Any]) ?? [:]
        for event in events {
            let commandStr = "\(Proc.quote(ctlPath)) hook codex \(event)"
            let hookItem: [String: Any] = [
                "type": "command",
                "command": commandStr,
                "timeout": 10
            ]
            let group: [String: Any] = [
                "hooks": [hookItem]
            ]
            let existingGroups = (codexHooksDict[event] as? [Any]) ?? []
            codexHooksDict[event] = updateHookGroups(existing: existingGroups, replacement: group)
        }
        codexRoot["hooks"] = codexHooksDict
        try writeJSON(codexRoot, to: codexHooks)

        return [
            "Installed hooks into \(claudeSettings.path)",
            "Installed hooks into \(codexHooks.path)"
        ]
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
    }

    /// Reports whether each file has our hooks.
    public func status() -> [String: Bool] {
        let claude = hasOurHooks(at: claudeSettings)
        let codex = hasOurHooks(at: codexHooks)
        return [
            "claude": claude,
            "codex": codex,
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
        let events = ["SessionStart", "UserPromptSubmit", "PostToolUse", "Stop", "SessionEnd"]
        return events.allSatisfy { event in
            guard let groups = hooks[event] as? [Any] else { return false }
            return groups.contains { isAgentHubGroup($0) }
        }
    }
}
