import Foundation
import Testing
@testable import HubCore

struct TranscriptTests {
    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // Claude user string
    @Test func claudeUserString() {
        let jsonl = """
        {"type": "user", "message": {"content": "Hello Claude"}}
        """
        let entries = Transcript.parse(jsonl)
        #expect(entries == [ChatEntry(role: .user, text: "Hello Claude")])
    }

    // Claude user with system-reminder only (dropped)
    @Test func claudeUserSystemReminderOnlyDropped() {
        let jsonl = """
        {"type": "user", "message": {"content": "<system-reminder>Some system reminder</system-reminder>"}}
        """
        let entries = Transcript.parse(jsonl)
        #expect(entries.isEmpty)
    }

    // Claude user with text and system-reminder
    @Test func claudeUserWithSystemReminderPreservesCleanText() {
        let jsonl = """
        {"type": "user", "message": {"content": "User instruction <system-reminder>Ignore this</system-reminder> please help"}}
        """
        let entries = Transcript.parse(jsonl)
        #expect(entries == [ChatEntry(role: .user, text: "User instruction  please help")])
    }

    // Command caveat (dropped) and other dropped prefixes
    @Test func claudeUserCommandCaveatAndCommandsDropped() {
        let jsonl = """
        {"type": "user", "message": {"content": "Caveat: tool results"}}
        {"type": "user", "message": {"content": "<local-command-result>done</local-command-result>"}}
        {"type": "user", "message": {"content": "<command-name>run</command-name>"}}
        {"type": "user", "message": {"content": "<command-message>msg</command-message>"}}
        {"type": "user", "message": {"content": "<task-notification>note</task-notification>"}}
        """
        let entries = Transcript.parse(jsonl)
        #expect(entries.isEmpty)
    }

    // Assistant text + tool_use
    @Test func claudeAssistantTextAndToolUse() {
        let jsonl = """
        {"type": "assistant", "message": {"content": [{"type": "text", "text": "I will inspect the file."}, {"type": "tool_use", "name": "View", "input": {"file_path": "/path/to/file.swift", "command": "cat /path/to/file.swift"}}, {"type": "thinking", "text": "internal thought to be ignored"}, {"type": "tool_use", "name": "Bash", "input": {"command": "swift test\\nwith extra line"}}]}}
        """
        let entries = Transcript.parse(jsonl)
        #expect(entries == [
            ChatEntry(role: .assistant, text: "I will inspect the file."),
            ChatEntry(role: .tool, text: "View cat /path/to/file.swift"),
            ChatEntry(role: .tool, text: "Bash swift test")
        ])
    }

    // Meta and sidechain skipped
    @Test func claudeMetaAndSidechainSkipped() {
        let jsonl = """
        {"type": "user", "isMeta": true, "message": {"content": "Meta message"}}
        {"type": "assistant", "isSidechain": true, "message": {"content": [{"type": "text", "text": "Sidechain reply"}]}}
        {"type": "user", "message": {"content": "Real message"}}
        """
        let entries = Transcript.parse(jsonl)
        #expect(entries == [ChatEntry(role: .user, text: "Real message")])
    }

    // Codex UserMessage, AgentMessage, CommandExecution with -lc, FileChange, McpToolCall
    @Test func codexItemCompletedEvents() {
        let jsonl = """
        {"type": "event_msg", "payload": {"type": "item_completed", "item": {"type": "UserMessage", "content": [{"text": "First line"}, {"text": "Second line"}]}}}
        {"type": "event_msg", "payload": {"type": "item_completed", "item": {"type": "AgentMessage", "content": [{"text": "I can help with that."}]}}}
        {"type": "event_msg", "payload": {"type": "item_completed", "item": {"type": "CommandExecution", "command": ["/bin/zsh", "-lc", "echo hello\\necho world"]}}}
        {"type": "event_msg", "payload": {"type": "item_completed", "item": {"type": "FileChange", "changes": {"/root/Sources/B.swift": {}, "/root/A.swift": {}}}}}
        {"type": "event_msg", "payload": {"type": "item_completed", "item": {"type": "McpToolCall", "server": "github", "tool": "create_issue", "arguments": {"title": "Fix bug"}}}}
        {"type": "event_msg", "payload": {"type": "item_completed", "item": {"type": "McpToolCall", "server": "weather", "tool": "get_forecast", "arguments": {}}}}
        {"type": "event_msg", "payload": {"type": "item_completed", "item": {"type": "Extension", "query": "swift testing"}}}
        {"type": "response_item", "payload": {"type": "item_completed"}}
        """
        let entries = Transcript.parse(jsonl)
        #expect(entries == [
            ChatEntry(role: .user, text: "First line\nSecond line"),
            ChatEntry(role: .assistant, text: "I can help with that."),
            ChatEntry(role: .tool, text: "$ echo hello"),
            ChatEntry(role: .tool, text: "✎ A.swift, B.swift"),
            ChatEntry(role: .tool, text: "github.create_issue — Fix bug"),
            ChatEntry(role: .tool, text: "weather.get_forecast"),
            ChatEntry(role: .tool, text: "search swift testing")
        ])
    }

    // Codex CommandExecution non -lc
    @Test func codexCommandExecutionPlain() {
        let jsonl = """
        {"type": "event_msg", "payload": {"type": "item_completed", "item": {"type": "CommandExecution", "command": ["git", "status"]}}}
        """
        let entries = Transcript.parse(jsonl)
        #expect(entries == [ChatEntry(role: .tool, text: "$ git status")])
    }

    // Old user_message / agent_message
    @Test func codexOldUserAndAgentMessage() {
        let jsonl = """
        {"type": "event_msg", "payload": {"type": "user_message", "message": "Old user prompt"}}
        {"type": "event_msg", "payload": {"type": "agent_message", "message": "Old agent response"}}
        """
        let entries = Transcript.parse(jsonl)
        #expect(entries == [
            ChatEntry(role: .user, text: "Old user prompt"),
            ChatEntry(role: .assistant, text: "Old agent response")
        ])
    }

    // Invalid lines
    @Test func invalidLinesSkipped() {
        let jsonl = """
        this is not json
        {"broken":
        {"type": "user", "message": {"content": "Valid user"}}
        null
        123
        """
        let entries = Transcript.parse(jsonl)
        #expect(entries == [ChatEntry(role: .user, text: "Valid user")])
    }

    // Duplicate collapse and empty text dropped
    @Test func duplicateCollapseAndEmptyTextDropped() {
        let jsonl = """
        {"type": "user", "message": {"content": "Repeat me"}}
        {"type": "user", "message": {"content": "Repeat me"}}
        {"type": "user", "message": {"content": "   "}}
        {"type": "assistant", "message": {"content": "Response"}}
        {"type": "assistant", "message": {"content": "Response"}}
        {"type": "user", "message": {"content": "Repeat me"}}
        """
        let entries = Transcript.parse(jsonl)
        #expect(entries == [
            ChatEntry(role: .user, text: "Repeat me"),
            ChatEntry(role: .assistant, text: "Response"),
            ChatEntry(role: .user, text: "Repeat me")
        ])
    }

    // entries with maxBytes smaller than the file (first partial line dropped)
    @Test func entriesWithMaxBytesDropsFirstPartialLine() throws {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("test.jsonl")

        let line1 = "{\"type\": \"user\", \"message\": {\"content\": \"First message to be dropped when cut\"}}\n"
        let line2 = "{\"type\": \"assistant\", \"message\": {\"content\": \"Second message\"}}\n"
        let line3 = "{\"type\": \"user\", \"message\": {\"content\": \"Third message\"}}\n"

        let fullContent = line1 + line2 + line3
        try fullContent.write(to: file, atomically: true, encoding: .utf8)

        let line2and3Bytes = (line2 + line3).utf8.count
        // Reading line2and3Bytes + 10 bytes will start inside line1. The partial line1 should be dropped!
        let entries = Transcript.entries(file, maxBytes: line2and3Bytes + 10)
        #expect(entries == [
            ChatEntry(role: .assistant, text: "Second message"),
            ChatEntry(role: .user, text: "Third message")
        ])

        // When maxBytes covers the whole file, line 1 is NOT dropped
        let allEntries = Transcript.entries(file, maxBytes: fullContent.utf8.count + 100)
        #expect(allEntries.count == 3)
        #expect(allEntries.first?.text == "First message to be dropped when cut")
    }

    // locate for claude and codex with temp roots, hint precedence, invalid session id
    @Test func locateClaudeAndCodex() throws {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let claudeRoot = dir.appendingPathComponent("claude_projects")
        let codexRoot = dir.appendingPathComponent("codex_sessions")

        let projectA = claudeRoot.appendingPathComponent("projectA")
        try FileManager.default.createDirectory(at: projectA, withIntermediateDirectories: true)

        let session1File = projectA.appendingPathComponent("sess-123.jsonl")
        try "{}".write(to: session1File, atomically: true, encoding: .utf8)

        // Invalid session ID checks
        #expect(Transcript.locate(platform: "claude", sessionId: "", hint: nil, claudeRoot: claudeRoot, codexRoot: codexRoot) == nil)
        #expect(Transcript.locate(platform: "claude", sessionId: "sess/123", hint: nil, claudeRoot: claudeRoot, codexRoot: codexRoot) == nil)
        #expect(Transcript.locate(platform: "claude", sessionId: "sess 123", hint: nil, claudeRoot: claudeRoot, codexRoot: codexRoot) == nil)
        #expect(Transcript.locate(platform: "other", sessionId: "sess-123", hint: nil, claudeRoot: claudeRoot, codexRoot: codexRoot) == nil)

        // Claude locate found
        let foundClaude = Transcript.locate(platform: "claude", sessionId: "sess-123", hint: nil, claudeRoot: claudeRoot, codexRoot: codexRoot)
        #expect(foundClaude?.standardizedFileURL.path == session1File.standardizedFileURL.path)

        // Hint precedence (even for claude)
        let hintFile = dir.appendingPathComponent("custom_hint.jsonl")
        try "{}".write(to: hintFile, atomically: true, encoding: .utf8)
        let hintClaude = Transcript.locate(platform: "claude", sessionId: "sess-123", hint: hintFile.path, claudeRoot: claudeRoot, codexRoot: codexRoot)
        #expect(hintClaude?.standardizedFileURL.path == hintFile.standardizedFileURL.path)

        // Non-existent hint falls back to locate
        let missingHintClaude = Transcript.locate(platform: "claude", sessionId: "sess-123", hint: "/non/existent/hint.jsonl", claudeRoot: claudeRoot, codexRoot: codexRoot)
        #expect(missingHintClaude?.standardizedFileURL.path == session1File.standardizedFileURL.path)

        // Codex locate: newest file ending with "-<sessionId>.jsonl"
        let codexSubdir = codexRoot.appendingPathComponent("2026/10")
        try FileManager.default.createDirectory(at: codexSubdir, withIntermediateDirectories: true)

        let codexOlder = codexSubdir.appendingPathComponent("roll-sess-456.jsonl")
        try "old".write(to: codexOlder, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: codexOlder.path)

        let codexNewer = codexRoot.appendingPathComponent("other-sess-456.jsonl")
        try "new".write(to: codexNewer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2000)], ofItemAtPath: codexNewer.path)

        let foundCodex = Transcript.locate(platform: "codex", sessionId: "sess-456", hint: nil, claudeRoot: claudeRoot, codexRoot: codexRoot)
        #expect(foundCodex?.standardizedFileURL.path == codexNewer.standardizedFileURL.path)
    }

    // LiveFeed stores transcript from a UserPromptSubmit payload
    @Test func liveFeedStoresTranscriptFromUserPromptSubmit() throws {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let paths = HubPaths(root: dir)
        let feed = LiveFeed(paths: paths)

        let payload: [String: Any] = [
            "session_id": "session-xyz",
            "prompt": "Hello there",
            "transcript_path": "/path/to/transcript.jsonl"
        ]
        _ = feed.handle(platform: "claude", event: "UserPromptSubmit", payload: payload, env: [:], pid: nil)

        let sessions = feed.sessions()
        let session = try #require(sessions.first)
        #expect(session.transcript == "/path/to/transcript.jsonl")
    }
}
