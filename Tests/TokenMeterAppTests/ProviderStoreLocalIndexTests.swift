import Foundation
import XCTest
@testable import TokenMeterApp
@testable import TokenMeterCore

@MainActor
final class ProviderStoreLocalIndexTests: XCTestCase {
    /// 并发单飞：await scanner 让出 MainActor 时重入的第二个调用必须被挡回
    ///（否则增量扫描会堆叠——实测 16 路并发把 CPU 顶到 150%+）。
    func testConcurrentRefreshCallsCoalesceIntoOneScan() async throws {
        let homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        let codexRoot = homeDirectory.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try writeLocalIndexJSONL(codexJSONL(sessionKey: "s", inputTokens: 1, outputTokens: 1), to: codexRoot.appendingPathComponent("session.jsonl"))

        let databaseURL = homeDirectory
            .appendingPathComponent("database", isDirectory: true)
            .appendingPathComponent("tokenmeter.sqlite")
        let store = ProviderStore(
            config: TokenMeterConfig(menuBar: MenuBarConfig(primaryProviderId: nil), providers: []),
            notificationCenter: nil,
            databaseURL: databaseURL
        )
        let database = try SQLiteDatabase(path: databaseURL.path)
        try insertScanRoot(database, id: 1, kind: .codexJSONL, rootPath: codexRoot.path, displayName: "Codex")

        async let first = store.refreshLocalAgentIndex()
        async let second = store.refreshLocalAgentIndex()
        let results = await [first, second]

        // 一个真扫、另一个被单飞守卫合并（消息「扫描已在进行」，不新起 scan_runs）。
        let skipped = results.filter { $0.message == "扫描已在进行" }
        XCTAssertEqual(skipped.count, 1, "并发调用必须恰好一个被合并")
        XCTAssertEqual(
            try scalarInt(database, "SELECT count(*) AS value FROM scan_runs"),
            1,
            "两次并发调用只允许产生一轮扫描"
        )
    }

    func testRefreshLocalAgentIndexScansOnlyEnabledAgentKinds() async throws {
        let homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        let claudeRoot = homeDirectory.appendingPathComponent("claude", isDirectory: true)
        let codexRoot = homeDirectory.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try writeLocalIndexJSONL(claudeJSONL(sessionKey: "claude-disabled", inputTokens: 1, outputTokens: 2), to: claudeRoot.appendingPathComponent("session.jsonl"))
        try writeLocalIndexJSONL(codexJSONL(sessionKey: "codex-enabled", inputTokens: 3, outputTokens: 4), to: codexRoot.appendingPathComponent("session.jsonl"))

        let databaseURL = homeDirectory
            .appendingPathComponent("database", isDirectory: true)
            .appendingPathComponent("tokenmeter.sqlite")
        let store = ProviderStore(
            config: TokenMeterConfig(menuBar: MenuBarConfig(primaryProviderId: nil), providers: []),
            notificationCenter: nil,
            databaseURL: databaseURL
        )

        let database = try SQLiteDatabase(path: databaseURL.path)
        try insertScanRoot(database, id: 1, kind: .claudeJSONL, rootPath: claudeRoot.path, displayName: "Claude")
        try insertScanRoot(database, id: 2, kind: .codexJSONL, rootPath: codexRoot.path, displayName: "Codex")

        let settingsStore = SettingsStore(database: database)
        let currentSettings = try XCTUnwrap(store.settingsSnapshot)
        _ = try settingsStore.apply(
            SettingsPatch(enabledAgentKinds: [LocalAgentKind.codex.rawValue]),
            expectedVersion: currentSettings.version,
            updatedBy: .swift
        )
        try store.reloadSettings()

        await store.refreshLocalAgentIndex()

        XCTAssertEqual(
            try scalarInt(database, "SELECT count(*) AS value FROM scan_runs WHERE scan_root_id = 1"),
            0,
            "disabled agent kinds must not create scan_runs for their roots"
        )
        XCTAssertEqual(
            try scalarInt(database, "SELECT count(*) AS value FROM source_files WHERE scan_root_id = 1"),
            0,
            "disabled agent kinds must not index source_files from their roots"
        )
        XCTAssertEqual(
            try scalarInt(database, "SELECT count(*) AS value FROM scan_runs WHERE scan_root_id = 2"),
            1,
            "enabled agent kinds should still be scanned"
        )
        XCTAssertEqual(
            try database.query("SELECT source_session_key FROM agent_sessions WHERE scan_root_id = 2").first?.string("source_session_key"),
            "codex-enabled"
        )
    }
}

private func insertScanRoot(
    _ database: SQLiteDatabase,
    id: Int64,
    kind: SourceKind,
    rootPath: String,
    displayName: String
) throws {
    try database.execute(
        """
        INSERT INTO scan_roots(id, kind, root_path, display_name, stable_source_key)
        VALUES (?, ?, ?, ?, ?)
        """,
        [
            .int(id),
            .text(kind.rawValue),
            .text(rootPath),
            .text(displayName),
            .text("\(kind.rawValue):\(rootPath)")
        ]
    )
}

private func claudeJSONL(sessionKey: String, inputTokens: Int64, outputTokens: Int64) -> String {
    """
    {"sessionId":"\(sessionKey)","cwd":"/repo/\(sessionKey)","type":"assistant","message":{"role":"assistant","model":"claude-sonnet","usage":{"input_tokens":\(inputTokens),"output_tokens":\(outputTokens)}}}

    """
}

private func codexJSONL(sessionKey: String, inputTokens: Int64, outputTokens: Int64) -> String {
    """
    {"type":"session_meta","payload":{"id":"\(sessionKey)","cwd":"/repo/\(sessionKey)"}}
    {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(inputTokens),"output_tokens":\(outputTokens)}}}}

    """
}

private func writeLocalIndexJSONL(_ content: String, to file: URL) throws {
    try Data(content.utf8).write(to: file)
}

private func scalarInt(_ database: SQLiteDatabase, _ sql: String, _ parameters: [SQLiteValue] = []) throws -> Int64 {
    try XCTUnwrap(database.query(sql, parameters).first?.int("value"))
}
