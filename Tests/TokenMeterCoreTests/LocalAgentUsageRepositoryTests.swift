import XCTest
@testable import TokenMeterCore

final class LocalAgentUsageRepositoryTests: XCTestCase {
    func testUpsertsSessionUsageAndLatestPointer() throws {
        let database = try migratedDatabase()
        let repository = LocalAgentUsageRepository(database: database)
        let session = makeSession(
            usage: ParsedSessionUsage(
                inputTokens: 100,
                outputTokens: 20,
                reasoningTokens: 3,
                cacheReadTokens: 4,
                cacheWriteTokens: 5,
                costUSDMicros: nil
            )
        )

        try repository.upsert(session, scanRootId: 1, sourceFileId: nil, runId: nil)

        XCTAssertEqual(try database.query("SELECT count(*) AS count FROM agent_sessions")[0].int("count"), 1)
        XCTAssertEqual(try database.query("SELECT tokens_total FROM session_usage")[0].int("tokens_total"), 132)
        XCTAssertEqual(try database.query("SELECT count(*) AS count FROM session_usage_latest")[0].int("count"), 1)
    }

    func testReupsertingSameSessionAdvancesLatestUsagePointer() throws {
        let database = try migratedDatabase()
        let repository = LocalAgentUsageRepository(database: database)
        try repository.upsert(
            makeSession(usageSequence: 1, sourceOffset: 42, inputTokens: 10, outputTokens: 5),
            scanRootId: 1,
            sourceFileId: nil,
            runId: nil
        )

        try repository.upsert(
            makeSession(
                updatedAt: "2026-07-03T01:20:00Z",
                usageSequence: 2,
                sourceOffset: 84,
                inputTokens: 30,
                outputTokens: 7
            ),
            scanRootId: 1,
            sourceFileId: nil,
            runId: nil
        )

        let latest = try database.query(
            """
            SELECT u.usage_seq, u.tokens_total
            FROM session_usage_latest latest
            JOIN session_usage u ON u.id = latest.session_usage_id
            """
        )[0]
        XCTAssertEqual(try database.query("SELECT count(*) AS count FROM session_usage")[0].int("count"), 2)
        XCTAssertEqual(latest.int("usage_seq"), 2)
        XCTAssertEqual(latest.int("tokens_total"), 37)
    }

    func testRepeatingSameUsageSnapshotDoesNotDuplicateUsageRows() throws {
        let database = try migratedDatabase()
        let repository = LocalAgentUsageRepository(database: database)
        let session = makeSession(usageSequence: 3, sourceOffset: 128, inputTokens: 9, outputTokens: 1)

        try repository.upsert(session, scanRootId: 1, sourceFileId: nil, runId: nil)
        try repository.upsert(session, scanRootId: 1, sourceFileId: nil, runId: nil)

        XCTAssertEqual(try database.query("SELECT count(*) AS count FROM agent_sessions")[0].int("count"), 1)
        XCTAssertEqual(try database.query("SELECT count(*) AS count FROM session_usage")[0].int("count"), 1)
        XCTAssertEqual(try database.query("SELECT tokens_total FROM session_usage")[0].int("tokens_total"), 10)
    }

    func testRawMetadataPersistsParserMetadataWithoutMessageContent() throws {
        let database = try migratedDatabase()
        let repository = LocalAgentUsageRepository(database: database)
        let parsed = try CodexSessionParser().parse(
            lines: [
                JSONLLine(text: #"{"type":"session_meta","payload":{"id":"session-privacy","cwd":"/repo"}}"#, offset: 0, nextOffset: 1),
                JSONLLine(text: #"{"type":"event_msg","payload":{"type":"message","content":"SECRET_PROMPT_SHOULD_NOT_BE_PERSISTED"}}"#, offset: 1, nextOffset: 2),
                JSONLLine(text: #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,"output_tokens":2}}}}"#, offset: 2, nextOffset: 3)
            ],
            sourceURL: URL(fileURLWithPath: "/tmp/codex.jsonl")
        )

        try repository.upsert(parsed, scanRootId: 1, sourceFileId: nil, runId: nil)

        let rawMetadata = try XCTUnwrap(database.query("SELECT raw_meta_json FROM agent_sessions")[0].string("raw_meta_json"))
        XCTAssertTrue(rawMetadata.contains("codex"))
        XCTAssertFalse(rawMetadata.contains("SECRET_PROMPT_SHOULD_NOT_BE_PERSISTED"))
    }

    func testRawMetadataFiltersPrivateKeysBeforePersistence() throws {
        let database = try migratedDatabase()
        let repository = LocalAgentUsageRepository(database: database)
        let session = makeSession(
            sessionKey: "metadata-privacy-session",
            rawMeta: [
                "source": "codex",
                "safe_model_family": "gpt",
                "prompt": "SECRET_PROMPT_SHOULD_NOT_BE_PERSISTED",
                "message": "SECRET_MESSAGE_SHOULD_NOT_BE_PERSISTED",
                "tool_output": "SECRET_TOOL_SHOULD_NOT_BE_PERSISTED",
                "reasoning": "SECRET_REASONING_SHOULD_NOT_BE_PERSISTED",
                "api_key": "sk-should-not-be-persisted",
                "token_count": "SECRET_TOKEN_METADATA_SHOULD_NOT_BE_PERSISTED",
                "credential_path": "/tmp/secret-credential",
                "provider": "/Users/alice/.ssh/id_rsa",
                "provider_file_url": "file:///Users/alice/Documents/acme-client",
                "provider_relative": ".ssh/id_rsa",
                "profile_relative": ".aws/credentials",
                "agent_config_relative": ".config/opencode/token.json",
                "provider_windows_relative": ".ssh\\id_rsa",
                "profile_windows_relative": ".aws\\credentials",
                "agent_config_windows_relative": ".config\\token.json",
                "provider_padded_file_url": " file:///Users/alice/private",
                "provider_padded_absolute": " /Users/alice/private",
                "provider_embedded_file_url": "opened file:///Users/alice/private-project",
                "safe_note": "opened .ssh/id_ed25519",
                "safe_profile": "loaded .aws/credentials-prod",
                "safe_config": "read .config/opencode/private-token.json",
                "safe_windows_note": "opened .ssh\\id_ed25519",
                "safe_windows_profile": "loaded .aws\\credentials-prod",
                "safe_windows_config": "read .config\\opencode\\private-token.json"
            ]
        )

        try repository.upsert(session, scanRootId: 1, sourceFileId: nil, runId: nil)

        let rawMetadata = try XCTUnwrap(database.query("SELECT raw_meta_json FROM agent_sessions")[0].string("raw_meta_json"))
        XCTAssertTrue(rawMetadata.contains("safe_model_family"))
        for forbidden in [
            "SECRET_PROMPT_SHOULD_NOT_BE_PERSISTED",
            "SECRET_MESSAGE_SHOULD_NOT_BE_PERSISTED",
            "SECRET_TOOL_SHOULD_NOT_BE_PERSISTED",
            "SECRET_REASONING_SHOULD_NOT_BE_PERSISTED",
            "sk-should-not-be-persisted",
            "SECRET_TOKEN_METADATA_SHOULD_NOT_BE_PERSISTED",
            "/Users/alice/.ssh/id_rsa",
            "id_rsa",
            "file:///Users/alice/Documents/acme-client",
            "acme-client",
            ".ssh",
            ".aws",
            ".config",
            "credentials",
            "token.json",
            " file:///Users/alice/private",
            " /Users/alice/private",
            "opened file:///Users/alice/private-project",
            "private-project",
            "opened .ssh/id_ed25519",
            "loaded .aws/credentials-prod",
            "read .config/opencode/private-token.json",
            "opened .ssh\\id_ed25519",
            "loaded .aws\\credentials-prod",
            "read .config\\opencode\\private-token.json",
            "id_ed25519",
            "credentials-prod",
            "private-token.json",
            "secret-credential",
            "prompt",
            "message",
            "tool_output",
            "reasoning",
            "api_key",
            "token_count",
            "credential_path"
        ] {
            XCTAssertFalse(rawMetadata.contains(forbidden), "raw_meta_json unexpectedly persisted private metadata key or value: \(forbidden)")
        }
    }

    func testDailyRollupWithNilProjectDoesNotDuplicateRows() throws {
        let database = try migratedDatabase()
        let repository = LocalAgentUsageRepository(database: database)
        let session = makeSession(projectPath: nil, usageSequence: 1, sourceOffset: 42, inputTokens: 11, outputTokens: 22)

        try repository.upsert(session, scanRootId: 1, sourceFileId: nil, runId: nil)
        try repository.upsert(session, scanRootId: 1, sourceFileId: nil, runId: nil)

        let rows = try database.query(
            """
            SELECT usage_date, sessions_count, tokens_input, tokens_output
            FROM provider_daily_usage
            WHERE provider_id = ? AND source_kind = ? AND project_id IS NULL
            """,
            [.text("codex"), .text(SourceKind.codexJSONL.rawValue)]
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].string("usage_date"), "2026-07-03")
        XCTAssertEqual(rows[0].int("sessions_count"), 1)
        XCTAssertEqual(rows[0].int("tokens_input"), 11)
        XCTAssertEqual(rows[0].int("tokens_output"), 22)
    }

    func testDailyRollupUsesLatestSessionUsageWithoutInflatingSessionCount() throws {
        let database = try migratedDatabase()
        let repository = LocalAgentUsageRepository(database: database)
        try repository.upsert(
            makeSession(
                usageSequence: 1,
                sourceOffset: 42,
                usage: ParsedSessionUsage(
                    inputTokens: 10,
                    outputTokens: 5,
                    reasoningTokens: 2,
                    cacheReadTokens: 3,
                    cacheWriteTokens: 4,
                    costUSDMicros: 1_234
                )
            ),
            scanRootId: 1,
            sourceFileId: nil,
            runId: nil
        )

        try repository.upsert(
            makeSession(
                updatedAt: "2026-07-03T01:20:00Z",
                usageSequence: 2,
                sourceOffset: 84,
                usage: ParsedSessionUsage(
                    inputTokens: 30,
                    outputTokens: 7,
                    reasoningTokens: 3,
                    cacheReadTokens: 4,
                    cacheWriteTokens: 5,
                    costUSDMicros: 4_321
                )
            ),
            scanRootId: 1,
            sourceFileId: nil,
            runId: nil
        )

        let rows = try database.query(
            """
            SELECT d.usage_date,
                   d.provider_id,
                   d.project_id,
                   d.source_kind,
                   d.sessions_count,
                   d.tokens_input,
                   d.tokens_output,
                   d.tokens_reasoning,
                   d.tokens_cache_read,
                   d.tokens_cache_write,
                   d.total_cost_usd_micros,
                   p.canonical_path
            FROM provider_daily_usage d
            JOIN projects p ON p.id = d.project_id
            WHERE d.provider_id = ? AND d.source_kind = ?
            """,
            [.text("codex"), .text(SourceKind.codexJSONL.rawValue)]
        )

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].string("usage_date"), "2026-07-03")
        XCTAssertEqual(rows[0].string("provider_id"), "codex")
        XCTAssertNotNil(rows[0].int("project_id"))
        XCTAssertEqual(rows[0].string("source_kind"), SourceKind.codexJSONL.rawValue)
        XCTAssertEqual(rows[0].string("canonical_path"), "/repo")
        XCTAssertEqual(rows[0].int("sessions_count"), 1)
        XCTAssertEqual(rows[0].int("tokens_input"), 30)
        XCTAssertEqual(rows[0].int("tokens_output"), 7)
        XCTAssertEqual(rows[0].int("tokens_reasoning"), 3)
        XCTAssertEqual(rows[0].int("tokens_cache_read"), 4)
        XCTAssertEqual(rows[0].int("tokens_cache_write"), 5)
        XCTAssertEqual(rows[0].int("total_cost_usd_micros"), 4_321)
    }

    func testDeltaUsageRowsDoNotBecomeLatestAfterCumulativeRefresh() throws {
        let database = try migratedDatabase()
        let repository = LocalAgentUsageRepository(database: database)
        let cumulativeUsage = ParsedSessionUsage(
            inputTokens: 100,
            outputTokens: 20,
            reasoningTokens: nil,
            cacheReadTokens: nil,
            cacheWriteTokens: nil,
            costUSDMicros: nil,
            kind: .cumulativeSessionTotal
        )
        try repository.upsert(
            makeSession(
                sessionKey: "codex-delta-latest",
                usageSequence: 1,
                sourceOffset: 10,
                usage: cumulativeUsage
            ),
            scanRootId: 1,
            sourceFileId: nil,
            runId: nil
        )
        try repository.upsert(
            makeSession(
                sessionKey: "codex-delta-latest",
                updatedAt: "2026-07-03T01:20:00Z",
                usageSequence: 2,
                sourceOffset: 20,
                usage: ParsedSessionUsage(
                    inputTokens: 5,
                    outputTokens: 2,
                    reasoningTokens: nil,
                    cacheReadTokens: nil,
                    cacheWriteTokens: nil,
                    costUSDMicros: nil,
                    kind: .perEventDelta
                )
            ),
            scanRootId: 1,
            sourceFileId: nil,
            runId: nil
        )
        try repository.upsert(
            makeSession(
                sessionKey: "codex-delta-latest",
                updatedAt: "2026-07-03T01:30:00Z",
                usageSequence: 1,
                sourceOffset: 10,
                usage: cumulativeUsage
            ),
            scanRootId: 1,
            sourceFileId: nil,
            runId: nil
        )

        let latest = try database.query(
            """
            SELECT u.usage_seq, u.is_cumulative, u.tokens_input, u.tokens_output
            FROM session_usage_latest latest
            JOIN session_usage u ON u.id = latest.session_usage_id
            """
        )[0]
        XCTAssertEqual(latest.int("usage_seq"), 1)
        XCTAssertEqual(latest.int("is_cumulative"), 1)
        XCTAssertEqual(latest.int("tokens_input"), 100)
        XCTAssertEqual(latest.int("tokens_output"), 20)

        let rollup = try database.query("SELECT tokens_input, tokens_output FROM provider_daily_usage")[0]
        XCTAssertEqual(rollup.int("tokens_input"), 100)
        XCTAssertEqual(rollup.int("tokens_output"), 20)
    }

    func testDeltaUsageDoesNotOverwriteExistingCumulativeUsageRow() throws {
        let database = try migratedDatabase()
        let repository = LocalAgentUsageRepository(database: database)
        try repository.upsert(
            makeSession(
                sessionKey: "codex-delta-rewrite",
                usageSequence: 1,
                sourceOffset: 10,
                usage: ParsedSessionUsage(
                    inputTokens: 100,
                    outputTokens: 20,
                    reasoningTokens: nil,
                    cacheReadTokens: nil,
                    cacheWriteTokens: nil,
                    costUSDMicros: nil,
                    kind: .cumulativeSessionTotal
                )
            ),
            scanRootId: 1,
            sourceFileId: nil,
            runId: nil
        )
        try repository.upsert(
            makeSession(
                sessionKey: "codex-delta-rewrite",
                updatedAt: "2026-07-03T01:20:00Z",
                usageSequence: 1,
                sourceOffset: 20,
                usage: ParsedSessionUsage(
                    inputTokens: 5,
                    outputTokens: 2,
                    reasoningTokens: nil,
                    cacheReadTokens: nil,
                    cacheWriteTokens: nil,
                    costUSDMicros: nil,
                    kind: .perEventDelta
                )
            ),
            scanRootId: 1,
            sourceFileId: nil,
            runId: nil
        )

        let usageRows = try database.query(
            """
            SELECT usage_seq, source_offset, is_cumulative, tokens_input, tokens_output
            FROM session_usage
            ORDER BY id ASC
            """
        )
        XCTAssertEqual(usageRows.count, 1)
        XCTAssertEqual(usageRows[0].int("is_cumulative"), 1)
        XCTAssertEqual(usageRows[0].int("tokens_input"), 100)
        XCTAssertEqual(usageRows[0].int("tokens_output"), 20)

        let latest = try database.query(
            """
            SELECT u.is_cumulative, u.tokens_input, u.tokens_output
            FROM session_usage_latest latest
            JOIN session_usage u ON u.id = latest.session_usage_id
            """
        )[0]
        XCTAssertEqual(latest.int("is_cumulative"), 1)
        XCTAssertEqual(latest.int("tokens_input"), 100)
        XCTAssertEqual(latest.int("tokens_output"), 20)
    }
}

private func migratedDatabase(sourceKind: SourceKind = .codexJSONL) throws -> SQLiteDatabase {
    let database = try SQLiteDatabase(path: ":memory:")
    try TokenMeterDatabaseMigrator.migrate(database)
    try database.execute(
        """
        INSERT INTO scan_roots(id, kind, root_path, display_name, stable_source_key)
        VALUES (?, ?, ?, ?, ?)
        """,
        [
            .int(1),
            .text(sourceKind.rawValue),
            .text("/tmp/token-meter"),
            .text("TokenMeter Tests"),
            .text("test-\(sourceKind.rawValue)")
        ]
    )
    return database
}

private func makeSession(
    sessionKey: String = "codex-session-1",
    projectPath: String? = "/repo",
    modelName: String? = "gpt-5.3",
    updatedAt: String = "2026-07-03T01:10:00Z",
    usageSequence: Int = 1,
    sourceOffset: Int64? = 42,
    inputTokens: Int64 = 100,
    outputTokens: Int64 = 20,
    usage: ParsedSessionUsage? = nil,
    rawMeta: [String: String] = ["source": "codex"]
) -> ParsedAgentSession {
    ParsedAgentSession(
        sourceKind: .codexJSONL,
        sessionKey: sessionKey,
        projectPath: projectPath,
        modelName: modelName,
        cliVersion: nil,
        startedAt: ISO8601DateFormatter().date(from: "2026-07-03T01:00:00Z"),
        updatedAt: ISO8601DateFormatter().date(from: updatedAt),
        usage: usage ?? ParsedSessionUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            reasoningTokens: nil,
            cacheReadTokens: nil,
            cacheWriteTokens: nil,
            costUSDMicros: nil
        ),
        usageSequence: usageSequence,
        sourceOffset: sourceOffset,
        rawMeta: rawMeta
    )
}
