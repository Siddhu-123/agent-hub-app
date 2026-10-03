import Foundation
import Testing
@testable import HubCore

struct CLITests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    func args(_ extra: [String] = []) throws -> CLIArgs {
        try CLIArgs(["delegate", "--main", "gpt-6.1-sol", "--project", "Tests/../Sources",
                     "--objective", "Implement CLI", "--allowed-file", "main.swift",
                     "--check", "[\"sh\",\"check.sh\"]"] + extra)
    }

    @Test func repeatedFlagsAndPositionals() throws {
        let a = try CLIArgs(["hook", "claude", "Stop", "--allowed-file", "a.swift", "--allowed-file", "b.swift", "--main", "first", "--main", "last"])
        #expect(a.subcommand == "hook")
        #expect(a.positionals == ["claude", "Stop"])
        #expect(a.flags["allowed-file"] == ["a.swift", "b.swift"])
        #expect(a.value("main") == "last")
        #expect(try CLIArgs([]).subcommand == "help")
    }

    @Test func booleanFlags() throws {
        let keys = ["json", "wait", "dry-run", "worktree", "all", "statusline", "force", "no-launch"]
        let a = try CLIArgs(["delegate"] + keys.map { "--" + $0 })
        #expect(a.booleans == Set(keys))
        #expect(a.flags.isEmpty)
        #expect(a.positionals.isEmpty)
    }

    @Test func invalidFlagsAndMissingValues() {
        for argv in [["status", "--unknown"], ["delegate", "--objective"],
                     ["delegate", "--project", "--wait"], ["delegate", "--check", ""], ["status", "-x"]] {
            do {
                _ = try CLIArgs(argv)
                Issue.record("Accepted invalid arguments: \(argv)")
            } catch let HubError.invalid(message) {
                #expect(message.contains("Usage: agenthubctl"))
            } catch { Issue.record("Unexpected error: \(error)") }
        }
    }

    @Test func delegateDefaultsAndAbsoluteProject() throws {
        let job = try CLIArgs.jobFromDelegateArgs(args(), now: now)
        #expect(job.size == .routine)
        #expect(job.kind == .implement)
        #expect(job.privacy == .project)
        #expect(job.isolation == .checkout)
        #expect(job.created == now)
        #expect(job.id.hasPrefix("j-20231114-221320-"))
        #expect(job.mainModel == "gpt-6.1-sol")
        #expect(job.checkArgv == ["sh", "check.sh"])
        #expect(job.project == URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Sources").path)
        #expect(job.state == .queued)
    }

    @Test func parentSessionComesFromEnvironment() throws {
        let claude = try CLIArgs.jobFromDelegateArgs(args(), now: now, env: ["CLAUDE_CODE_SESSION_ID": "c-123", "CODEX_THREAD_ID": "x-9"])
        #expect(claude.parentSession == "claude:c-123")
        let codex = try CLIArgs.jobFromDelegateArgs(args(), now: now, env: ["CLAUDE_CODE_SESSION_ID": "", "CODEX_THREAD_ID": "x-9"])
        #expect(codex.parentSession == "codex:x-9")
        let none = try CLIArgs.jobFromDelegateArgs(args(), now: now, env: [:])
        #expect(none.parentSession == nil)
    }

    @Test func delegateOverrides() throws {
        let job = try CLIArgs.jobFromDelegateArgs(args(["--size", "hard", "--kind", "review", "--privacy", "generic", "--worktree", "--allowed-file", "other.swift"]), now: now)
        #expect(job.size == .hard)
        #expect(job.kind == .review)
        #expect(job.privacy == .generic)
        #expect(job.isolation == .worktree)
        #expect(job.allowedFiles == ["main.swift", "other.swift"])
    }

    @Test func invalidCheckJSONAndEnums() throws {
        for text in ["bad json", "{}", "[1]", "[\"sh\",1]", "null", "\"sh\""] {
            #expect(throws: HubError.self) {
                try CLIArgs.jobFromDelegateArgs(args(["--check", text]), now: now)
            }
        }
        for key in ["size", "kind", "privacy"] {
            #expect(throws: HubError.self) {
                try CLIArgs.jobFromDelegateArgs(args(["--" + key, "invalid"]), now: now)
            }
        }
        #expect(throws: HubError.self) {
            try CLIArgs.jobFromDelegateArgs(CLIArgs(["delegate"]), now: now)
        }
    }
}

extension CLITests {
    @Test func disabledClaudeStatusRemainsUsable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = ConfigStore.defaults()
        for i in config.models.indices where config.models[i].harness == "claude" {
            config.models[i].enabled = false
        }
        config.mainOrder = ["gpt-6.1-sol"]
        for i in config.harnesses.indices { config.harnesses[i].usageSource = .none }
        try ConfigStore.save(config, HubPaths(root: root))
        let ctl = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/agenthubctl").path
        let env = ["AGENT_HUB_HOME": root.path, "AGENT_HUB_TEST": "1", "PATH": "/usr/bin:/bin"]
        let status = Proc.run([ctl, "status", "--json"], env: env, timeout: 5)
        #expect(status.passed)
        let object = try #require(JSONSerialization.jsonObject(with: Data(status.output.utf8)) as? [String: Any])
        #expect(object["usage"] is [String: Any])
        #expect(!status.output.lowercased().contains("no main"))
        let input = #"{"model":{"display_name":"Sample"},"rate_limits":{"five_hour":{"used_percentage":25}}}"#
        let line = Proc.run([ctl, "statusline"], env: env, stdin: input, timeout: 5)
        #expect(line.passed && line.output.contains("Sample") && line.output.contains("5h 25%"))
    }

    @Test func hooksRouteAllPlatformsAndInvalidInput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/agenthubctl").path
        #expect(FileManager.default.isExecutableFile(atPath: executable))
        func hook(_ platform: String, _ event: String, _ input: String) -> CheckResult {
            Proc.run([executable, "hook", platform, event], env: ["AGENT_HUB_HOME": root.path, "AGENT_HUB_TEST": "1", "PATH": "/usr/bin:/bin"], stdin: input, timeout: 5)
        }
        for platform in ["claude", "codex", "antigravity", "opencode"] {
            for input in ["", "garbage", "{}", "[]"] {
                let r = hook(platform, "SessionStart", input)
                #expect(r.passed)
                #expect(r.output.trimmingCharacters(in: .whitespacesAndNewlines) == (platform == "antigravity" ? "{}" : ""))
            }
        }
        #expect(hook("claude", "SessionStart", "{\"session_id\":\"c\"}").passed)
        #expect(hook("codex", "SessionStart", "{\"session_id\":\"d\"}").passed)
        #expect(hook("antigravity", "PreInvocation", "{\"conversationId\":\"a\"}").output.trimmingCharacters(in: .whitespacesAndNewlines) == "{}")
        let r = hook("opencode", "permission", "{\"sessionID\":\"o\",\"id\":\"p\"}")
        let output = try #require(JSONSerialization.jsonObject(with: Data(r.output.utf8)) as? [String: Any])
        #expect(output["requestId"] is String)
        #expect(hook("unknown", "SessionStart", "{\"session_id\":\"x\"}").output.isEmpty)
        let feed = LiveFeed(paths: HubPaths(root: root))
        #expect(Set(feed.sessions().map(\.platform)) == Set(["claude", "codex", "antigravity", "opencode"]))
    }
}
