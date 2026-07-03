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
