import XCTest
@testable import TokenMeterCore

final class MenuBarSummaryRepositoryTests: XCTestCase {
    func testReadsPrimaryProviderLatestTokenSummary() throws {
        let database = try migratedMenuSummaryDatabase()
        let settings = SettingsStore(database: database)
        try settings.importConfigIfNeeded(ProviderConfigLoader.defaultConfig())
        let repository = LocalAgentUsageRepository(database: database)
        let session = makeMenuSummarySession(
            updatedAt: "2026-07-03T01:10:00Z",
            inputTokens: 100,
            outputTokens: 20
        )
        try repository.upsert(session, scanRootId: 1, sourceFileId: nil, runId: nil)

        let summary = try MenuBarSummaryRepository(database: database).primarySummary(providerId: "codex")

        XCTAssertEqual(summary?.providerId, "codex")
        XCTAssertEqual(summary?.modelName, "gpt-5.3")
        XCTAssertEqual(summary?.totalTokens, 120)
    }

    func testReadsMostRecentlyUpdatedActiveSessionForProvider() throws {
        let database = try migratedMenuSummaryDatabase()
        let usageRepository = LocalAgentUsageRepository(database: database)
        try usageRepository.upsert(
            makeMenuSummarySession(
                sessionKey: "older",
                modelName: "older-model",
                updatedAt: "2026-07-03T01:00:00Z",
                inputTokens: 1,
                outputTokens: 2
            ),
            scanRootId: 1,
            sourceFileId: nil,
            runId: nil
        )
        try usageRepository.upsert(
            makeMenuSummarySession(
                sessionKey: "newer",
                modelName: "newer-model",
                updatedAt: "2026-07-03T01:30:00Z",
                inputTokens: 30,
                outputTokens: 4
            ),
            scanRootId: 1,
            sourceFileId: nil,
            runId: nil
        )

        let summary = try MenuBarSummaryRepository(database: database).primarySummary(providerId: "codex")

        XCTAssertEqual(summary?.modelName, "newer-model")
        XCTAssertEqual(summary?.totalTokens, 34)
    }

    func testDoesNotReturnClosedSessionSummary() throws {
        let database = try migratedMenuSummaryDatabase()
        let usageRepository = LocalAgentUsageRepository(database: database)
        try usageRepository.upsert(makeMenuSummarySession(), scanRootId: 1, sourceFileId: nil, runId: nil)
        try database.execute("UPDATE agent_sessions SET status = ?", [.text("closed")])

        let summary = try MenuBarSummaryRepository(database: database).primarySummary(providerId: "codex")

        XCTAssertNil(summary)
    }
}

private func migratedMenuSummaryDatabase() throws -> SQLiteDatabase {
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
            .text("/tmp/token-meter"),
            .text("TokenMeter Tests"),
            .text("menu-summary-codex")
        ]
    )
    return database
}

private func makeMenuSummarySession(
    sessionKey: String = "codex-session-1",
    modelName: String? = "gpt-5.3",
    updatedAt: String = "2026-07-03T01:10:00Z",
    inputTokens: Int64 = 100,
    outputTokens: Int64 = 20
) -> ParsedAgentSession {
    ParsedAgentSession(
        sourceKind: .codexJSONL,
        sessionKey: sessionKey,
        projectPath: "/repo",
        modelName: modelName,
        cliVersion: nil,
        startedAt: nil,
        updatedAt: ISO8601DateFormatter().date(from: updatedAt),
        usage: ParsedSessionUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            reasoningTokens: nil,
            cacheReadTokens: nil,
            cacheWriteTokens: nil,
            costUSDMicros: nil
        ),
        usageSequence: 1,
        sourceOffset: Int64(abs(sessionKey.hashValue % 10_000)),
        rawMeta: [:]
    )
}
