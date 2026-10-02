import Foundation
import Testing
@testable import HubCore

@Suite struct HookInstallerTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HookInstallerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func installIntoMissingFiles() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let claudeSettings = tempDir.appendingPathComponent(".claude/settings.json")
        let codexHooks = tempDir.appendingPathComponent(".codex/hooks.json")
        let ctlPath = "/custom/path/agenthubctl"

        let installer = HookInstaller(
            claudeSettings: claudeSettings,
            codexHooks: codexHooks,
            ctlPath: ctlPath
        )

        let result = try installer.install()
        #expect(result.count == 2)
        #expect(FileManager.default.fileExists(atPath: claudeSettings.path))
        #expect(FileManager.default.fileExists(atPath: codexHooks.path))

        // Claude checks
        let claudeData = try Data(contentsOf: claudeSettings)
        let claudeJSON = try #require(try JSONSerialization.jsonObject(with: claudeData) as? [String: Any])
        let claudeHooks = try #require(claudeJSON["hooks"] as? [String: Any])

        let expectedEvents = ["SessionStart", "UserPromptSubmit", "PostToolUse", "Stop", "SessionEnd"]
        for event in expectedEvents {
            let groups = try #require(claudeHooks[event] as? [[String: Any]])
            #expect(groups.count == 1)
            let group = groups[0]

            if event == "PostToolUse" {
                #expect((group["matcher"] as? String) == "*")
            } else {
                #expect(group["matcher"] == nil)
            }

            let hooks = try #require(group["hooks"] as? [[String: Any]])
            #expect(hooks.count == 1)
            let hook = hooks[0]
            #expect((hook["type"] as? String) == "command")
            #expect((hook["command"] as? String) == "'/custom/path/agenthubctl' hook claude \(event)")
            #expect((hook["timeout"] as? Int) == 10)
        }

        // Codex checks
        let codexData = try Data(contentsOf: codexHooks)
        let codexJSON = try #require(try JSONSerialization.jsonObject(with: codexData) as? [String: Any])
        let codexHooksDict = try #require(codexJSON["hooks"] as? [String: Any])

        for event in expectedEvents {
            let groups = try #require(codexHooksDict[event] as? [[String: Any]])
            #expect(groups.count == 1)
            let group = groups[0]
            #expect(group["matcher"] == nil)

            let hooks = try #require(group["hooks"] as? [[String: Any]])
            #expect(hooks.count == 1)
            let hook = hooks[0]
            #expect((hook["type"] as? String) == "command")
            #expect((hook["command"] as? String) == "'/custom/path/agenthubctl' hook codex \(event)")
            #expect((hook["timeout"] as? Int) == 10)
        }
    }

    @Test func existingUnrelatedGroupsAndKeysSurvive() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let claudeSettings = tempDir.appendingPathComponent(".claude/settings.json")
        let codexHooks = tempDir.appendingPathComponent(".codex/hooks.json")
        try FileManager.default.createDirectory(at: claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexHooks.deletingLastPathComponent(), withIntermediateDirectories: true)

        let initialClaude: [String: Any] = [
            "theme": "dark",
            "numberKey": 42,
            "hooks": [
                "PreToolUse": [
                    [
                        "hooks": [
                            ["type": "command", "command": "echo pre-tool", "timeout": 5]
                        ]
                    ]
                ],
                "SessionStart": [
                    [
                        "matcher": "startup",
                        "hooks": [
                            ["type": "command", "command": "echo startup", "timeout": 3]
                        ]
                    ]
                ]
            ]
        ]
        let claudeData = try JSONSerialization.data(withJSONObject: initialClaude, options: [.prettyPrinted, .sortedKeys])
        try claudeData.write(to: claudeSettings)

        let initialCodex: [String: Any] = [
            "description": "existing codex config",
            "nested": ["key": "val"],
            "hooks": [
                "Stop": [
                    [
                        "hooks": [
                            ["type": "command", "command": "run-tests.sh"]
                        ]
                    ]
                ]
            ]
        ]
        let codexData = try JSONSerialization.data(withJSONObject: initialCodex, options: [.prettyPrinted, .sortedKeys])
        try codexData.write(to: codexHooks)

        let installer = HookInstaller(
            claudeSettings: claudeSettings,
            codexHooks: codexHooks,
            ctlPath: "/path/to/agenthubctl"
        )
        try installer.install()

        // Check Claude
        let updatedClaudeData = try Data(contentsOf: claudeSettings)
        let updatedClaude = try #require(try JSONSerialization.jsonObject(with: updatedClaudeData) as? [String: Any])
        #expect((updatedClaude["theme"] as? String) == "dark")
        #expect((updatedClaude["numberKey"] as? Int) == 42)

        let claudeHooks = try #require(updatedClaude["hooks"] as? [String: Any])
        let preToolGroups = try #require(claudeHooks["PreToolUse"] as? [[String: Any]])
        #expect(preToolGroups.count == 1)

        let sessionStartGroups = try #require(claudeHooks["SessionStart"] as? [[String: Any]])
        #expect(sessionStartGroups.count == 2)
        #expect((sessionStartGroups[0]["matcher"] as? String) == "startup")
        let secondHook = try #require(sessionStartGroups[1]["hooks"] as? [[String: Any]])
        #expect((secondHook[0]["command"] as? String)?.contains("agenthubctl") == true)

        // Check Codex
        let updatedCodexData = try Data(contentsOf: codexHooks)
        let updatedCodex = try #require(try JSONSerialization.jsonObject(with: updatedCodexData) as? [String: Any])
        #expect((updatedCodex["description"] as? String) == "existing codex config")
        #expect(((updatedCodex["nested"] as? [String: Any])?["key"] as? String) == "val")

        let codexHooksDict = try #require(updatedCodex["hooks"] as? [String: Any])
        let stopGroups = try #require(codexHooksDict["Stop"] as? [[String: Any]])
        #expect(stopGroups.count == 2)
        let firstStopHook = try #require(stopGroups[0]["hooks"] as? [[String: Any]])
        #expect((firstStopHook[0]["command"] as? String) == "run-tests.sh")
        let secondStopHook = try #require(stopGroups[1]["hooks"] as? [[String: Any]])
        #expect((secondStopHook[0]["command"] as? String)?.contains("agenthubctl") == true)
    }

    @Test func runningInstallTwiceDoesNotDuplicate() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let claudeSettings = tempDir.appendingPathComponent(".claude/settings.json")
        let codexHooks = tempDir.appendingPathComponent(".codex/hooks.json")
        let installer = HookInstaller(
            claudeSettings: claudeSettings,
            codexHooks: codexHooks,
            ctlPath: "/path/to/agenthubctl"
        )

        try installer.install()
        try installer.install()

        let claudeData = try Data(contentsOf: claudeSettings)
        let claudeJSON = try #require(try JSONSerialization.jsonObject(with: claudeData) as? [String: Any])
        let claudeHooks = try #require(claudeJSON["hooks"] as? [String: Any])

        let expectedEvents = ["SessionStart", "UserPromptSubmit", "PostToolUse", "Stop", "SessionEnd"]
        for event in expectedEvents {
            let groups = try #require(claudeHooks[event] as? [[String: Any]])
            #expect(groups.count == 1)
        }

        let codexData = try Data(contentsOf: codexHooks)
        let codexJSON = try #require(try JSONSerialization.jsonObject(with: codexData) as? [String: Any])
        let codexHooksDict = try #require(codexJSON["hooks"] as? [String: Any])

        for event in expectedEvents {
            let groups = try #require(codexHooksDict[event] as? [[String: Any]])
            #expect(groups.count == 1)
        }
    }

    @Test func backupWrittenOnceAndNotOverwrittenOnSecondInstall() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let claudeSettings = tempDir.appendingPathComponent(".claude/settings.json")
        let codexHooks = tempDir.appendingPathComponent(".codex/hooks.json")
        try FileManager.default.createDirectory(at: claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexHooks.deletingLastPathComponent(), withIntermediateDirectories: true)

        let initialClaude = ["version": "v1.0", "custom": "initial"]
        let claudeData = try JSONSerialization.data(withJSONObject: initialClaude)
        try claudeData.write(to: claudeSettings)

        let initialCodex = ["version": "v1.0-codex", "custom": "initial"]
        let codexData = try JSONSerialization.data(withJSONObject: initialCodex)
        try codexData.write(to: codexHooks)

        let installer1 = HookInstaller(
            claudeSettings: claudeSettings,
            codexHooks: codexHooks,
            ctlPath: "/path/one/agenthubctl"
        )
        try installer1.install()

        let claudeBackup = URL(fileURLWithPath: claudeSettings.path + ".bak-agenthub")
        let codexBackup = URL(fileURLWithPath: codexHooks.path + ".bak-agenthub")
        #expect(FileManager.default.fileExists(atPath: claudeBackup.path))
        #expect(FileManager.default.fileExists(atPath: codexBackup.path))

        let claudeBackupData = try Data(contentsOf: claudeBackup)
        let claudeBackupJSON = try #require(try JSONSerialization.jsonObject(with: claudeBackupData) as? [String: Any])
        #expect((claudeBackupJSON["custom"] as? String) == "initial")
        #expect(claudeBackupJSON["hooks"] == nil)

        // Second install with different ctlPath
        let installer2 = HookInstaller(
            claudeSettings: claudeSettings,
            codexHooks: codexHooks,
            ctlPath: "/path/two/agenthubctl"
        )
        try installer2.install()

        // Backup must not have been overwritten with the result of first install!
        let claudeBackupData2 = try Data(contentsOf: claudeBackup)
        let claudeBackupJSON2 = try #require(try JSONSerialization.jsonObject(with: claudeBackupData2) as? [String: Any])
        #expect((claudeBackupJSON2["custom"] as? String) == "initial")
        #expect(claudeBackupJSON2["hooks"] == nil)
    }

    @Test func quotingCtlPathWithSpacesAndSingleQuotes() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let claudeSettings = tempDir.appendingPathComponent(".claude/settings.json")
        let codexHooks = tempDir.appendingPathComponent(".codex/hooks.json")
        let trickyPath = "/Applications/Agent's Tools/My App's CLI/agenthubctl"

        let installer = HookInstaller(
            claudeSettings: claudeSettings,
            codexHooks: codexHooks,
            ctlPath: trickyPath
        )
        try installer.install()
        try installer.installStatusLine()

        let expectedQuoted = Proc.quote(trickyPath)
        #expect(expectedQuoted == "'/Applications/Agent'\"'\"'s Tools/My App'\"'\"'s CLI/agenthubctl'")

        let claudeData = try Data(contentsOf: claudeSettings)
        let claudeJSON = try #require(try JSONSerialization.jsonObject(with: claudeData) as? [String: Any])
        let claudeHooks = try #require(claudeJSON["hooks"] as? [String: Any])
        let startGroups = try #require(claudeHooks["SessionStart"] as? [[String: Any]])
        let hookList = try #require(startGroups[0]["hooks"] as? [[String: Any]])
        let command = try #require(hookList[0]["command"] as? String)
        #expect(command == "\(expectedQuoted) hook claude SessionStart")

        let statusLineObj = try #require(claudeJSON["statusLine"] as? [String: Any])
        let statusCmd = try #require(statusLineObj["command"] as? String)
        #expect(statusCmd == "\(expectedQuoted) statusline")
    }

    @Test func statusLineScenarios() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let claudeSettings = tempDir.appendingPathComponent(".claude/settings.json")
        let codexHooks = tempDir.appendingPathComponent(".codex/hooks.json")
        let installer = HookInstaller(
            claudeSettings: claudeSettings,
            codexHooks: codexHooks,
            ctlPath: "/path/to/agenthubctl"
        )

        // 1. Set when absent
        let msg1 = try installer.installStatusLine()
        #expect(!msg1.isEmpty)
        let data1 = try Data(contentsOf: claudeSettings)
        let json1 = try #require(try JSONSerialization.jsonObject(with: data1) as? [String: Any])
        let sl1 = try #require(json1["statusLine"] as? [String: Any])
        #expect((sl1["type"] as? String) == "command")
        #expect((sl1["command"] as? String) == "'/path/to/agenthubctl' statusline")

        // 2. Replaced when ours
        let installer2 = HookInstaller(
            claudeSettings: claudeSettings,
            codexHooks: codexHooks,
            ctlPath: "/new/path/agenthubctl"
        )
        let msg2 = try installer2.installStatusLine()
        #expect(!msg2.isEmpty)
        let data2 = try Data(contentsOf: claudeSettings)
        let json2 = try #require(try JSONSerialization.jsonObject(with: data2) as? [String: Any])
        let sl2 = try #require(json2["statusLine"] as? [String: Any])
        #expect((sl2["command"] as? String) == "'/new/path/agenthubctl' statusline")

        // 3. Another statusLine exists, refuse when force is false (file unchanged, message returned)
        var jsonWithOther = json2
        jsonWithOther["statusLine"] = [
            "type": "command",
            "command": "custom-statusline --show"
        ]
        let otherData = try JSONSerialization.data(withJSONObject: jsonWithOther, options: [.prettyPrinted, .sortedKeys])
        try otherData.write(to: claudeSettings)

        let refuseMsg = try installer.installStatusLine(force: false)
        #expect(refuseMsg.contains("Refused") || refuseMsg.contains("custom-statusline"))
        // Check file unchanged
        let data3 = try Data(contentsOf: claudeSettings)
        let json3 = try #require(try JSONSerialization.jsonObject(with: data3) as? [String: Any])
        let sl3 = try #require(json3["statusLine"] as? [String: Any])
        #expect((sl3["command"] as? String) == "custom-statusline --show")

        // 4. Another statusLine exists, replaced when force is true
        let forceMsg = try installer.installStatusLine(force: true)
        #expect(!forceMsg.isEmpty)
        let data4 = try Data(contentsOf: claudeSettings)
        let json4 = try #require(try JSONSerialization.jsonObject(with: data4) as? [String: Any])
        let sl4 = try #require(json4["statusLine"] as? [String: Any])
        #expect((sl4["command"] as? String) == "'/path/to/agenthubctl' statusline")
    }

    @Test func uninstallRemovesOnlyOurGroupsAndStatusLine() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let claudeSettings = tempDir.appendingPathComponent(".claude/settings.json")
        let codexHooks = tempDir.appendingPathComponent(".codex/hooks.json")
        let installer = HookInstaller(
            claudeSettings: claudeSettings,
            codexHooks: codexHooks,
            ctlPath: "/path/to/agenthubctl"
        )

        // Install our hooks and statusline
        try installer.install()
        try installer.installStatusLine()

        // Also add unrelated keys and hooks
        var claudeJSON = try #require(try JSONSerialization.jsonObject(with: try Data(contentsOf: claudeSettings)) as? [String: Any])
        claudeJSON["otherTopLevel"] = "survives"
        var hooks = try #require(claudeJSON["hooks"] as? [String: Any])
        var sessionStartGroups = try #require(hooks["SessionStart"] as? [[String: Any]])
        sessionStartGroups.append([
            "matcher": "custom",
            "hooks": [["type": "command", "command": "echo custom-hook"]]
        ])
        hooks["SessionStart"] = sessionStartGroups
        claudeJSON["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: claudeJSON, options: [.prettyPrinted, .sortedKeys]).write(to: claudeSettings)

        // Codex also has other keys
        var codexJSON = try #require(try JSONSerialization.jsonObject(with: try Data(contentsOf: codexHooks)) as? [String: Any])
        codexJSON["codexConfig"] = true
        var codexHooksDict = try #require(codexJSON["hooks"] as? [String: Any])
        var stopGroups = try #require(codexHooksDict["Stop"] as? [[String: Any]])
        stopGroups.append([
            "hooks": [["type": "command", "command": "echo keep-codex"]]
        ])
        codexHooksDict["Stop"] = stopGroups
        codexJSON["hooks"] = codexHooksDict
        try JSONSerialization.data(withJSONObject: codexJSON, options: [.prettyPrinted, .sortedKeys]).write(to: codexHooks)

        // Perform uninstall
        try installer.uninstall()

        // Verify Claude:
        let updatedClaude = try #require(try JSONSerialization.jsonObject(with: try Data(contentsOf: claudeSettings)) as? [String: Any])
        #expect((updatedClaude["otherTopLevel"] as? String) == "survives")
        #expect(updatedClaude["statusLine"] == nil) // ours was removed

        let updatedHooks = try #require(updatedClaude["hooks"] as? [String: Any])
        let updatedSessionStart = try #require(updatedHooks["SessionStart"] as? [[String: Any]])
        #expect(updatedSessionStart.count == 1)
        #expect((updatedSessionStart[0]["matcher"] as? String) == "custom")

        let postTool = try #require(updatedHooks["PostToolUse"] as? [[String: Any]])
        #expect(postTool.isEmpty)

        // Verify Codex:
        let updatedCodex = try #require(try JSONSerialization.jsonObject(with: try Data(contentsOf: codexHooks)) as? [String: Any])
        #expect((updatedCodex["codexConfig"] as? Bool) == true)
        let updatedCodexHooks = try #require(updatedCodex["hooks"] as? [String: Any])
        let updatedStop = try #require(updatedCodexHooks["Stop"] as? [[String: Any]])
        #expect(updatedStop.count == 1)
        let remainingHook = try #require(updatedStop[0]["hooks"] as? [[String: Any]])
        #expect((remainingHook[0]["command"] as? String) == "echo keep-codex")

        // Verify that someone else's statusLine is NOT removed by uninstall
        var claudeWithForeignStatusLine = updatedClaude
        claudeWithForeignStatusLine["statusLine"] = ["type": "command", "command": "foreign-statusline"]
        try JSONSerialization.data(withJSONObject: claudeWithForeignStatusLine).write(to: claudeSettings)

        try installer.uninstall()

        let claudeRechecked = try #require(try JSONSerialization.jsonObject(with: try Data(contentsOf: claudeSettings)) as? [String: Any])
        let foreignStatusLine = try #require(claudeRechecked["statusLine"] as? [String: Any])
        #expect((foreignStatusLine["command"] as? String) == "foreign-statusline")
    }

    @Test func statusReportsCorrectly() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let claudeSettings = tempDir.appendingPathComponent(".claude/settings.json")
        let codexHooks = tempDir.appendingPathComponent(".codex/hooks.json")
        let installer = HookInstaller(
            claudeSettings: claudeSettings,
            codexHooks: codexHooks,
            ctlPath: "/path/to/agenthubctl"
        )

        // 1. Missing files
        let statusBefore = installer.status()
        #expect(statusBefore["claude"] == false)
        #expect(statusBefore["codex"] == false)
        #expect(statusBefore[claudeSettings.path] == false)
        #expect(statusBefore[codexHooks.path] == false)

        // 2. After install
        try installer.install()
        let statusInstalled = installer.status()
        #expect(statusInstalled["claude"] == true)
        #expect(statusInstalled["codex"] == true)
        #expect(statusInstalled[claudeSettings.path] == true)
        #expect(statusInstalled[codexHooks.path] == true)

        // 3. After uninstall
        try installer.uninstall()
        let statusUninstalled = installer.status()
        #expect(statusUninstalled["claude"] == false)
        #expect(statusUninstalled["codex"] == false)
        #expect(statusUninstalled[claudeSettings.path] == false)
        #expect(statusUninstalled[codexHooks.path] == false)
    }

    @Test func installCLILinkCreatesAndReplacesSymlink() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let linkURL = tempDir.appendingPathComponent("bin/agenthubctl")
        let initialTargetURL = tempDir.appendingPathComponent("initial_agenthubctl")
        try "".write(to: initialTargetURL, atomically: true, encoding: .utf8)
        let initialTarget = initialTargetURL.path

        let installer = HookInstaller(ctlPath: initialTarget)
        try installer.installCLILink(at: linkURL)

        let target1 = try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path)
        #expect(target1 == initialTarget)

        // Replace symlink with new target
        let newTargetURL = tempDir.appendingPathComponent("new_agenthubctl")
        try "".write(to: newTargetURL, atomically: true, encoding: .utf8)
        let newTarget = newTargetURL.path

        let installer2 = HookInstaller(ctlPath: newTarget)
        try installer2.installCLILink(at: linkURL)

        let target2 = try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path)
        #expect(target2 == newTarget)
    }
}
