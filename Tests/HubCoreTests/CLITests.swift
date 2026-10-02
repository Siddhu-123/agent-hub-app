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
