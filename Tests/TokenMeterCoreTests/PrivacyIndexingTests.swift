import XCTest
@testable import TokenMeterCore

final class PrivacyIndexingTests: XCTestCase {
    func testScannedDatabaseTextDumpIncludesParserStateWithoutPrivatePayloads() async throws {
        let directory = try privacyTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("privacy.jsonl")
        try Data((#"{"type":"session_meta","payload":{"id":"privacy-scanned-session","cwd":"/repo/privacy","model":"gpt-5.5"}}"# + "\n" +
                  #"{"type":"event_msg","payload":{"type":"message","content":"SECRET_PROMPT","tool_output":"SECRET_TOOL_OUTPUT","reasoning":"SECRET_REASONING","api_key":"sk-should-not-persist"}}"# + "\n" +
                  #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,"output_tokens":2}}}}"# + "\n").utf8).write(to: file)
        let database = try privacyMigratedDatabase(rootPath: directory.path)

        try await LocalAgentScanner(database: database).scanRoot(id: 1)

        let persistedText = try localAgentTextDump(database)
        XCTAssertTrue(persistedText.contains("lastEventSeq"), "privacy text dump must include source_files.parser_state")
        for forbidden in ["SECRET_PROMPT", "SECRET_TOOL_OUTPUT", "SECRET_REASONING", "api_key", "sk-should-not-persist"] {
            XCTAssertFalse(persistedText.contains(forbidden), "Persisted DB text unexpectedly contained \(forbidden)")
        }
    }
}

private func privacyMigratedDatabase(rootPath: String = "/tmp/token-meter-privacy") throws -> SQLiteDatabase {
    let database = try SQLiteDatabase(path: ":memory:")
    try TokenMeterDatabaseMigrator.migrate(database)
    try database.execute(
        """
        INSERT INTO scan_roots(id, kind, root_path, display_name, stable_source_key)
        VALUES (?, ?, ?, ?, ?)
        """,
        [
            .int(1),
            .text(SourceKind.codexJSONL.rawValue),
            .text(rootPath),
            .text("TokenMeter Privacy Tests"),
            .text("privacy-codex-root")
        ]
    )
    return database
}

private func privacyTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func localAgentTextDump(_ database: SQLiteDatabase) throws -> String {
    let rows = try database.query(
        """
        SELECT value FROM (
          SELECT root_path AS value FROM scan_roots
          UNION ALL SELECT display_name FROM scan_roots
          UNION ALL SELECT stable_source_key FROM scan_roots
          UNION ALL SELECT source_kind FROM agent_sessions
          UNION ALL SELECT source_session_key FROM agent_sessions
          UNION ALL SELECT provider_id FROM agent_sessions
          UNION ALL SELECT model_name FROM agent_sessions
          UNION ALL SELECT cli_version FROM agent_sessions
          UNION ALL SELECT session_started_at FROM agent_sessions
          UNION ALL SELECT session_updated_at FROM agent_sessions
          UNION ALL SELECT cwd_path FROM agent_sessions
          UNION ALL SELECT status FROM agent_sessions
          UNION ALL SELECT source_revision FROM agent_sessions
          UNION ALL SELECT raw_meta_json FROM agent_sessions
          UNION ALL SELECT parser_state FROM source_files
          UNION ALL SELECT parse_error FROM source_files
          UNION ALL SELECT model_name FROM usage_events
          UNION ALL SELECT model_canonical FROM usage_events
          UNION ALL SELECT dedupe_key FROM usage_events
          UNION ALL SELECT project_key FROM projects
          UNION ALL SELECT canonical_path FROM projects
          UNION ALL SELECT display_name FROM projects
          UNION ALL SELECT observed_at FROM session_usage
          UNION ALL SELECT metric_scope FROM session_usage
          UNION ALL SELECT window_label FROM session_usage
          UNION ALL SELECT source_event_id FROM session_usage
          UNION ALL SELECT source_hash FROM session_usage
          UNION ALL SELECT usage_date FROM provider_daily_usage
          UNION ALL SELECT provider_id FROM provider_daily_usage
          UNION ALL SELECT source_kind FROM provider_daily_usage
        )
        WHERE value IS NOT NULL
        """
    )
    return rows.compactMap { $0.string("value") }.joined(separator: "\n")
}
