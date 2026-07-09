import XCTest
@testable import TokenMeterCore

final class PrivacyIndexingTests: XCTestCase {
    func testCodexParserDoesNotCopyMessageTextIntoRawMetadata() throws {
        let lines = [
            JSONLLine(text: #"{"type":"session_meta","payload":{"id":"session-privacy","cwd":"/repo"}}"#, offset: 0, nextOffset: 1),
            JSONLLine(text: #"{"type":"event_msg","payload":{"type":"message","content":"SECRET_PROMPT_SHOULD_NOT_BE_INDEXED"}}"#, offset: 1, nextOffset: 2),
            JSONLLine(text: #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,"output_tokens":2}}}}"#, offset: 2, nextOffset: 3)
        ]

        let parsed = try CodexSessionParser().parse(lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/codex.jsonl"))

        XCTAssertFalse(parsed.rawMeta.values.contains { $0.contains("SECRET_PROMPT_SHOULD_NOT_BE_INDEXED") })
    }

    func testClaudeParserDoesNotCopyPrivateTextIntoRawMetadata() throws {
        let lines = [
            JSONLLine(text: #"{"type":"summary","summary":"SECRET_SUMMARY_SHOULD_NOT_BE_INDEXED","leafUuid":"claude-privacy"}"#, offset: 0, nextOffset: 1),
            JSONLLine(text: #"{"sessionId":"claude-privacy","type":"assistant","requestId":"req-privacy","message":{"id":"msg-privacy","model":"claude-sonnet","usage":{"input_tokens":1,"output_tokens":2},"content":[{"type":"text","text":"SECRET_ASSISTANT_SHOULD_NOT_BE_INDEXED"}],"toolUseResult":{"content":"SECRET_TOOL_OUTPUT_SHOULD_NOT_BE_INDEXED"}}}"#, offset: 1, nextOffset: 2)
        ]

        let parsed = try ClaudeCodeSessionParser().parse(lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/claude.jsonl"))

        XCTAssertFalse(parsed.rawMeta.values.contains { value in
            value.contains("SECRET_SUMMARY_SHOULD_NOT_BE_INDEXED")
                || value.contains("SECRET_ASSISTANT_SHOULD_NOT_BE_INDEXED")
                || value.contains("SECRET_TOOL_OUTPUT_SHOULD_NOT_BE_INDEXED")
        })
    }

    func testOmpParserDoesNotCopyPrivateTextIntoRawMetadata() throws {
        let lines = [
            JSONLLine(text: #"{"type":"session","id":"omp-privacy","cwd":"/repo"}"#, offset: 0, nextOffset: 1),
            JSONLLine(text: #"{"type":"message","message":{"role":"assistant","content":"SECRET_OMP_ASSISTANT_SHOULD_NOT_BE_INDEXED","tool":{"output":"SECRET_OMP_TOOL_SHOULD_NOT_BE_INDEXED"},"usage":{"inputTokens":1,"outputTokens":2}}}"#, offset: 1, nextOffset: 2)
        ]

        let parsed = try OmpSessionParser().parse(lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/omp.jsonl"))

        XCTAssertFalse(parsed.rawMeta.values.contains { value in
            value.contains("SECRET_OMP_ASSISTANT_SHOULD_NOT_BE_INDEXED")
                || value.contains("SECRET_OMP_TOOL_SHOULD_NOT_BE_INDEXED")
        })
    }

    func testPersistedLocalAgentTextColumnsDoNotContainPrivateCodexEventPayloads() throws {
        let parsed = try CodexSessionParser().parse(
            lines: [
                JSONLLine(text: #"{"type":"session_meta","payload":{"id":"privacy-db-session","cwd":"/repo/privacy","model":"gpt-5.5"}}"#, offset: 0, nextOffset: 1),
                JSONLLine(text: #"{"type":"event_msg","payload":{"type":"message","content":"SECRET_PROMPT","tool_output":"SECRET_TOOL_OUTPUT","reasoning":"SECRET_REASONING","api_key":"sk-should-not-persist"}}"#, offset: 1, nextOffset: 2),
                JSONLLine(text: #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,"output_tokens":2}}}}"#, offset: 2, nextOffset: 3)
            ],
            sourceURL: URL(fileURLWithPath: "/tmp/privacy-codex.jsonl")
        )
        XCTAssertEqual(parsed.rawMeta, ["source": "codex"])
        let database = try privacyMigratedDatabase()

        try LocalAgentUsageRepository(database: database).upsert(parsed, scanRootId: 1, sourceFileId: nil, runId: nil)

        let persistedText = try localAgentTextDump(database)
        for forbidden in ["SECRET_PROMPT", "SECRET_TOOL_OUTPUT", "SECRET_REASONING", "api_key", "sk-should-not-persist"] {
            XCTAssertFalse(persistedText.contains(forbidden), "Persisted DB text unexpectedly contained \(forbidden)")
        }
    }

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
