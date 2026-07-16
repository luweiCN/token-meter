import XCTest
@testable import TokenMeterApp

final class AgentHooksInstallerTests: XCTestCase {
    private var home: URL!
    private var installer: AgentHooksInstaller!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenmeter-hooks-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let script = home.appendingPathComponent("bundle-hooks/tokenmeter-agent-hook.sh")
        let ompExtension = home.appendingPathComponent("bundle-hooks/tokenmeter-omp-agent-state.ts")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: script, atomically: true, encoding: .utf8)
        try "// tokenmeter omp extension\n".write(to: ompExtension, atomically: true, encoding: .utf8)

        installer = AgentHooksInstaller(
            hookScriptPath: script.path,
            ompExtensionSource: ompExtension,
            homeDirectory: home
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func claudeHooks() throws -> [String: [[String: Any]]] {
        let data = try Data(contentsOf: installer.claudeSettingsURL)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return root["hooks"] as? [String: [[String: Any]]] ?? [:]
    }

    func testInstallIntoMissingClaudeSettingsCreatesAllLifecycleEntries() throws {
        installer.sync(enabledKinds: ["claudeCode"])

        let hooks = try claudeHooks()
        XCTAssertEqual(
            Set(hooks.keys),
            ["SessionStart", "UserPromptSubmit", "PostToolUse", "Stop", "PermissionRequest", "Notification", "SessionEnd"]
        )
        let command = try XCTUnwrap(
            ((hooks["SessionStart"]?.first?["hooks"]) as? [[String: Any]])?.first?["command"] as? String
        )
        XCTAssertTrue(command.contains("claudeCode start"))
        XCTAssertTrue(command.contains(AgentHooksInstaller.marker))
        let blockedCommand = try XCTUnwrap(
            ((hooks["PermissionRequest"]?.first?["hooks"]) as? [[String: Any]])?.first?["command"] as? String
        )
        XCTAssertTrue(blockedCommand.contains("claudeCode blocked"))
    }

    func testSyncPreservesForeignEntriesAndIsIdempotent() throws {
        // 预置用户自有 hook（herdr 式）+ 无关顶层键，安装/卸载都不得动它们。
        let existing = """
        {
          "model": "opus",
          "hooks": {
            "SessionStart": [
              { "matcher": "*", "hooks": [ { "type": "command", "command": "bash ~/.claude/hooks/herdr-agent-state.sh session", "timeout": 10 } ] }
            ]
          }
        }
        """
        try FileManager.default.createDirectory(at: installer.claudeSettingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try existing.write(to: installer.claudeSettingsURL, atomically: true, encoding: .utf8)

        installer.sync(enabledKinds: ["claudeCode"])
        installer.sync(enabledKinds: ["claudeCode"])

        let hooks = try claudeHooks()
        let sessionStart = try XCTUnwrap(hooks["SessionStart"])
        // herdr 条目 1 条 + tokenmeter 条目 1 条——重复 sync 不翻倍。
        XCTAssertEqual(sessionStart.count, 2)

        installer.sync(enabledKinds: [])

        let afterRemoval = try claudeHooks()
        XCTAssertEqual(afterRemoval["SessionStart"]?.count, 1)
        XCTAssertNil(afterRemoval["SessionEnd"])
        let data = try Data(contentsOf: installer.claudeSettingsURL)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["model"] as? String, "opus")
    }

    func testCorruptJsonIsNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: installer.claudeSettingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{ not json".write(to: installer.claudeSettingsURL, atomically: true, encoding: .utf8)

        installer.sync(enabledKinds: ["claudeCode"])

        let text = try String(contentsOf: installer.claudeSettingsURL, encoding: .utf8)
        XCTAssertEqual(text, "{ not json")
    }

    func testOmpExtensionInstalledOnlyWhenOmpExistsAndRemovedOnDisable() throws {
        // 没有 ~/.omp/agent：不装、不造目录。
        installer.sync(enabledKinds: ["omp"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.ompExtensionDestination.path))

        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".omp/agent"),
            withIntermediateDirectories: true
        )
        installer.sync(enabledKinds: ["omp"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: installer.ompExtensionDestination.path))
        XCTAssertEqual(installer.installedState()["omp"], true)

        installer.sync(enabledKinds: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.ompExtensionDestination.path))
    }

    func testCodexHooksUseSameStructureWithoutSessionEnd() throws {
        installer.sync(enabledKinds: ["codex"])

        let data = try Data(contentsOf: installer.codexHooksURL)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: [[String: Any]]])
        XCTAssertEqual(Set(hooks.keys), ["SessionStart", "UserPromptSubmit", "Stop", "PostToolUse", "PermissionRequest"])
    }
}
