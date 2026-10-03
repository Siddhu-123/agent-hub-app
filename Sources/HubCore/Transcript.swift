import Foundation

public struct ChatEntry: Equatable, Sendable {
    public enum Role: String, Sendable { case user, assistant, tool }
    public var role: Role
    public var text: String
    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

public enum Transcript {
    private static let sessionIdRegex = try! NSRegularExpression(pattern: "^[A-Za-z0-9._-]{1,128}$")
    private static let systemReminderRegex = try! NSRegularExpression(pattern: "<system-reminder>[\\s\\S]*?</system-reminder>", options: [])

    private static func isValidSessionId(_ sessionId: String) -> Bool {
        let range = NSRange(sessionId.startIndex..<sessionId.endIndex, in: sessionId)
        return sessionIdRegex.firstMatch(in: sessionId, range: range) != nil
    }

    /// The session's transcript file. `hint` (the hook's transcript_path) wins when that file exists.
    /// Otherwise claude: the first `<claudeRoot>/<any folder>/<sessionId>.jsonl` that exists;
    /// codex: the newest file under `<codexRoot>` (recursive) whose name ends with "-<sessionId>.jsonl".
    /// Other platforms or nothing found: nil. sessionId must match [A-Za-z0-9._-]{1,128}, else nil.
    public static func locate(platform: String, sessionId: String, hint: String?,
                              claudeRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects"),
                              codexRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")) -> URL? {
        guard isValidSessionId(sessionId) else { return nil }

        let fm = FileManager.default
        if let hint, !hint.isEmpty {
            let hintURL = URL(fileURLWithPath: hint)
            if fm.fileExists(atPath: hintURL.path) {
                return hintURL
            }
        }

        switch platform {
        case "claude":
            guard fm.fileExists(atPath: claudeRoot.path) else { return nil }
            guard let subdirs = try? fm.contentsOfDirectory(at: claudeRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                return nil
            }
            // Sort folder URLs to ensure deterministic ordering
            let sortedDirs = subdirs.sorted { $0.path < $1.path }
            for dir in sortedDirs {
                let candidate = dir.appendingPathComponent("\(sessionId).jsonl")
                if fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
            return nil

        case "codex":
            guard fm.fileExists(atPath: codexRoot.path) else { return nil }
            let suffix = "-\(sessionId).jsonl"
            var matches: [(url: URL, date: Date)] = []
            if let enumerator = fm.enumerator(at: codexRoot, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]) {
                for case let fileURL as URL in enumerator {
                    if fileURL.lastPathComponent.hasSuffix(suffix) {
                        let date = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
                        matches.append((fileURL, date))
                    }
                }
            }
            // Newest file under codexRoot
            matches.sort { $0.date > $1.date }
            return matches.first?.url

        default:
            return nil
        }
    }

    /// Reads the last maxBytes of the file (dropping the first partial line unless reading from offset 0) and parses it.
    public static func entries(_ url: URL, maxBytes: Int = 400_000) -> [ChatEntry] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), fileSize > 0 else { return [] }
        let readLength = min(Int(fileSize), max(0, maxBytes))
        guard readLength > 0 else { return [] }
        let offset = fileSize - UInt64(readLength)
        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: readLength) else { return [] }
            var slice = data
            // If truncated (offset > 0), advance past the first newline to drop the partial line
            if offset > 0 {
                if let firstNewlineIndex = slice.firstIndex(of: UInt8(ascii: "\n")) {
                    slice = slice.subdata(in: (firstNewlineIndex + 1)..<slice.endIndex)
                } else {
                    // No newline found in slice, entire slice was a partial line
                    return []
                }
            }
            let text = String(decoding: slice, as: UTF8.self)
            return parse(text)
        } catch {
            return []
        }
    }

    /// Parses JSONL text (one JSON object per line; invalid lines are skipped). Both formats may appear; order is kept.
    public static func parse(_ jsonl: String) -> [ChatEntry] {
        var rawEntries: [ChatEntry] = []

        let lines = jsonl.components(separatedBy: "\n")
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.isEmpty { continue }
            guard let data = trimmedLine.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            // Check if it's Claude or Codex or both
            parseLine(obj, into: &rawEntries)
        }

        // Post-processing:
        // Consecutive identical entries (same role and text) collapse into one. Empty texts are dropped.
        var collapsed: [ChatEntry] = []
        for entry in rawEntries {
            let trimmedText = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedText.isEmpty { continue }
            let cleanedEntry = ChatEntry(role: entry.role, text: entry.text)
            if let last = collapsed.last, last.role == cleanedEntry.role && last.text == cleanedEntry.text {
                continue
            }
            collapsed.append(cleanedEntry)
        }

        return collapsed
    }

    private static func parseLine(_ obj: [String: Any], into entries: inout [ChatEntry]) {
        // response_item lines are ignored
        if let typeStr = obj["type"] as? String, typeStr == "response_item" {
            return
        }

        // Codex format checks:
        // type == "event_msg"
        if let typeStr = obj["type"] as? String, typeStr == "event_msg" {
            parseCodexEventMsg(obj, into: &entries)
            return
        }

        // Claude format checks:
        // Skip lines with isMeta == true or isSidechain == true
        if (obj["isMeta"] as? Bool) == true || (obj["isSidechain"] as? Bool) == true {
            return
        }

        if let typeStr = obj["type"] as? String {
            if typeStr == "user" {
                parseClaudeUser(obj, into: &entries)
                return
            } else if typeStr == "assistant" {
                parseClaudeAssistant(obj, into: &entries)
                return
            }
        }
    }

    // MARK: - Claude Parsing

    private static func sanitizeClaudeUserText(_ raw: String) -> String? {
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        let stripped = systemReminderRegex.stringByReplacingMatches(in: raw, options: [], range: range, withTemplate: "")
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        let droppedPrefixes = [
            "<local-command-",
            "<command-name>",
            "<command-message>",
            "<task-notification>",
            "Caveat:"
        ]
        for prefix in droppedPrefixes {
            if trimmed.hasPrefix(prefix) {
                return nil
            }
        }
        return trimmed
    }

    private static func parseClaudeUser(_ obj: [String: Any], into entries: inout [ChatEntry]) {
        guard let message = obj["message"] as? [String: Any] else { return }
        let content = message["content"]

        if let contentString = content as? String {
            if let sanitized = sanitizeClaudeUserText(contentString) {
                entries.append(ChatEntry(role: .user, text: sanitized))
            }
        } else if let blocks = content as? [[String: Any]] {
            for block in blocks {
                guard let blockType = block["type"] as? String else { continue }
                if blockType == "text", let text = block["text"] as? String {
                    if let sanitized = sanitizeClaudeUserText(text) {
                        entries.append(ChatEntry(role: .user, text: sanitized))
                    }
                }
                // tool_result blocks are ignored
            }
        }
    }

    private static func parseClaudeAssistant(_ obj: [String: Any], into entries: inout [ChatEntry]) {
        guard let message = obj["message"] as? [String: Any] else { return }
        let content = message["content"]

        if let contentString = content as? String {
            let trimmed = contentString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                entries.append(ChatEntry(role: .assistant, text: trimmed))
            }
        } else if let blocks = content as? [[String: Any]] {
            for block in blocks {
                guard let blockType = block["type"] as? String else { continue }
                if blockType == "text", let text = block["text"] as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        entries.append(ChatEntry(role: .assistant, text: trimmed))
                    }
                } else if blockType == "tool_use" {
                    // Each tool_use block becomes a tool entry "<name> <arg>" where arg is the first
                    // non-empty string among input command, file_path, pattern, url, query, description, prompt,
                    // cut to its first line and 160 characters (<name> alone when none).
                    let name = (block["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let input = block["input"] as? [String: Any] ?? [:]
                    let candidateKeys = ["command", "file_path", "pattern", "url", "query", "description", "prompt"]
                    var matchedArg: String? = nil
                    for key in candidateKeys {
                        if let val = input[key] as? String, !val.isEmpty {
                            matchedArg = val
                            break
                        }
                    }
                    if let matchedArg {
                        let firstLine = matchedArg.components(separatedBy: .newlines).first ?? ""
                        let clipped = String(firstLine.prefix(160))
                        let text = "\(name) \(clipped)"
                        entries.append(ChatEntry(role: .tool, text: text))
                    } else {
                        entries.append(ChatEntry(role: .tool, text: name))
                    }
                }
                // thinking blocks are ignored
            }
        }
    }

    // MARK: - Codex Parsing

    private static func parseCodexEventMsg(_ obj: [String: Any], into entries: inout [ChatEntry]) {
        guard let payload = obj["payload"] as? [String: Any],
              let payloadType = payload["type"] as? String else {
            return
        }

        if payloadType == "item_completed" {
            guard let item = payload["item"] as? [String: Any],
                  let itemType = item["type"] as? String else {
                return
            }

            switch itemType {
            case "UserMessage":
                let content = item["content"] as? [[String: Any]] ?? []
                let texts = content.compactMap { $0["text"] as? String }
                let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty {
                    entries.append(ChatEntry(role: .user, text: joined))
                }

            case "AgentMessage":
                let content = item["content"] as? [[String: Any]] ?? []
                let texts = content.compactMap { $0["text"] as? String }
                let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty {
                    entries.append(ChatEntry(role: .assistant, text: joined))
                }

            case "CommandExecution":
                // tool entry "$ <cmd>"; command is an array — when it is [shell, "-lc", script] (shell ending in sh) use the script, else join with spaces; first line, 160 characters.
                let cmdArray = item["command"] as? [String] ?? []
                var rawCmd = ""
                if cmdArray.count == 3,
                   cmdArray[0].hasSuffix("sh"),
                   cmdArray[1] == "-lc" {
                    rawCmd = cmdArray[2]
                } else {
                    rawCmd = cmdArray.joined(separator: " ")
                }
                let firstLine = rawCmd.components(separatedBy: .newlines).first ?? ""
                let clipped = String(firstLine.prefix(160))
                entries.append(ChatEntry(role: .tool, text: "$ \(clipped)"))

            case "McpToolCall":
                // tool entry "<server>.<tool>" plus " — <arguments.title>" when that is a non-empty string.
                let server = item["server"] as? String ?? ""
                let tool = item["tool"] as? String ?? ""
                var entryText = "\(server).\(tool)"
                if let args = item["arguments"] as? [String: Any],
                   let title = args["title"] as? String,
                   !title.isEmpty {
                    entryText += " — \(title)"
                }
                entries.append(ChatEntry(role: .tool, text: entryText))

            case "FileChange":
                // tool entry "✎ " + the last path component of each key in changes, sorted, joined with ", ".
                let changes = item["changes"] as? [String: Any] ?? [:]
                let lastComponents = changes.keys.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted()
                let joined = lastComponents.joined(separator: ", ")
                entries.append(ChatEntry(role: .tool, text: "✎ \(joined)"))

            case "Extension":
                // with query string: tool entry "search <query>" (160 characters).
                if let query = item["query"] as? String {
                    let clipped = String(query.prefix(160))
                    entries.append(ChatEntry(role: .tool, text: "search \(clipped)"))
                }

            default:
                break
            }
        } else if payloadType == "user_message" {
            // older Codex
            if let msg = payload["message"] as? String {
                let trimmed = msg.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    entries.append(ChatEntry(role: .user, text: trimmed))
                }
            }
        } else if payloadType == "agent_message" {
            // older Codex
            if let msg = payload["message"] as? String {
                let trimmed = msg.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    entries.append(ChatEntry(role: .assistant, text: trimmed))
                }
            }
        }
    }
}
