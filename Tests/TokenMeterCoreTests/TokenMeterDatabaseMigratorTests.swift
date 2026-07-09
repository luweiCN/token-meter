import XCTest
@testable import TokenMeterCore

final class TokenMeterDatabaseMigratorTests: XCTestCase {
    func testMigratesPhaseTwoSchemaAndEnablesWAL() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("tokenmeter.sqlite")
        let database = try SQLiteDatabase(path: url.path)

        try TokenMeterDatabaseMigrator.migrate(database)

        XCTAssertEqual(try database.query("PRAGMA user_version")[0].int("user_version"), 2)
        XCTAssertEqual(try database.query("PRAGMA journal_mode")[0].string("journal_mode"), "wal")
        XCTAssertEqual(try database.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'agent_sessions'").count, 1)
        XCTAssertEqual(try database.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'session_usage_latest'").count, 1)
    }

    func testRejectsLatestUsageFromDifferentSession() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)
        try database.execute(
            "INSERT INTO scan_roots(id, kind, root_path, display_name, stable_source_key) VALUES (1, 'codex_jsonl', '/tmp/codex', 'Codex', 'codex')"
        )
        try database.execute(
            "INSERT INTO agent_sessions(id, source_kind, source_session_key, scan_root_id, source_revision) VALUES (1, 'codex_jsonl', 'session-a', 1, 'rev-a')"
        )
        try database.execute(
            "INSERT INTO agent_sessions(id, source_kind, source_session_key, scan_root_id, source_revision) VALUES (2, 'codex_jsonl', 'session-b', 1, 'rev-b')"
        )
        try database.execute(
            "INSERT INTO session_usage(id, session_id, observed_at, usage_seq) VALUES (10, 2, '2026-07-03T00:00:00Z', 1)"
        )

        XCTAssertThrowsError(
            try database.execute("INSERT INTO session_usage_latest(session_id, session_usage_id) VALUES (1, 10)")
        )
    }

    func testRejectsDuplicateDailyRollupWhenProjectIsNull() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)
        try database.execute(
            "INSERT INTO provider_daily_usage(usage_date, provider_id, project_id, source_kind, sessions_count) VALUES ('2026-07-03', 'codex', NULL, 'codex_jsonl', 1)"
        )

        XCTAssertThrowsError(
            try database.execute("INSERT INTO provider_daily_usage(usage_date, provider_id, project_id, source_kind, sessions_count) VALUES ('2026-07-03', 'codex', NULL, 'codex_jsonl', 1)")
        )
    }

    func testRejectsNewerSchemaVersionWithoutDowngrading() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        let futureVersion = TokenMeterDatabaseSchema.currentVersion + 1
        try database.execute("PRAGMA user_version = \(futureVersion)")

        XCTAssertThrowsError(try TokenMeterDatabaseMigrator.migrate(database)) { error in
            XCTAssertEqual(error as? TokenMeterDatabaseMigratorError, .unsupportedNewerVersion(futureVersion))
        }
        XCTAssertEqual(try database.query("PRAGMA user_version")[0].int("user_version"), futureVersion)
    }

    func testMigratesFreshDatabaseToVersion2() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)

        let version = try database.query("PRAGMA user_version")[0].int("user_version")
        XCTAssertEqual(version, 2)

        let tables = try database.query("SELECT name FROM sqlite_master WHERE type = 'table'")
            .compactMap { $0.string("name") }
        XCTAssertTrue(tables.contains("usage_events"))
        XCTAssertTrue(tables.contains("daily_rollup"))
        XCTAssertTrue(tables.contains("session_rollup"))
        XCTAssertTrue(tables.contains("model_pricing"))
    }

    func testMigrationFromV1AddsNewTablesAndKeepsLegacyOnes() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try database.execute(TokenMeterDatabaseSchema.v1)
        try database.execute(
            """
            INSERT INTO scan_roots(kind, root_path, display_name, stable_source_key, last_successful_cursor)
            VALUES ('claude_jsonl', '/tmp/claude', 'Claude', 'claude:/tmp/claude', 'cursor-123')
            """
        )

        try TokenMeterDatabaseMigrator.migrate(database)

        let tables = try database.query("SELECT name FROM sqlite_master WHERE type = 'table'")
            .compactMap { $0.string("name") }

        XCTAssertTrue(tables.contains("usage_events"))
        XCTAssertTrue(tables.contains("daily_rollup"))
        XCTAssertTrue(tables.contains("session_rollup"))
        XCTAssertTrue(tables.contains("model_pricing"))

        // 旧表保留：Task 11 / 14 才切换过去，Task 18 负责清理
        XCTAssertTrue(tables.contains("session_usage"))
        XCTAssertTrue(tables.contains("session_usage_latest"))
        XCTAssertTrue(tables.contains("provider_daily_usage"))

        // 扫描游标此刻不动
        let roots = try database.query("SELECT root_path, last_successful_cursor FROM scan_roots")
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots[0].string("last_successful_cursor"), "cursor-123")
    }

    func testMigrationIsIdempotent() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)
        try TokenMeterDatabaseMigrator.migrate(database)

        XCTAssertEqual(try database.query("PRAGMA user_version")[0].int("user_version"), 2)
    }

    func testUsageEventsTotalTokensGeneratedColumnExcludesReasoning() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)
        try database.execute(
            """
            INSERT INTO scan_roots(id, kind, root_path, display_name, stable_source_key)
            VALUES (1, 'claude_jsonl', '/tmp/c', 'C', 'c')
            """
        )
        try database.execute(
            """
            INSERT INTO source_files(id, scan_root_id, relative_path, canonical_path, file_type, size_bytes, mtime_ns)
            VALUES (1, 1, 'a.jsonl', '/tmp/c/a.jsonl', 'jsonl_session', 1, 1)
            """
        )
        try database.execute(
            """
            INSERT INTO agent_sessions(id, source_kind, source_session_key, scan_root_id, source_revision)
            VALUES (1, 'claude_jsonl', 's1', 1, 'rev')
            """
        )
        try database.execute(
            """
            INSERT INTO usage_events(
                session_id, source_file_id, event_seq, observed_epoch_ms,
                tokens_input, tokens_output, tokens_reasoning, tokens_cache_read,
                cost_source, source_offset
            ) VALUES (1, 1, 1, 0, 100, 50, 20, 900, 'unknown', 0)
            """
        )

        let total = try database.query("SELECT tokens_total FROM usage_events")[0].int("tokens_total")
        XCTAssertEqual(total, 1050)
    }

    func testSessionRollupHasCostUnknownEventsColumn() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)

        let columns = try database.query("PRAGMA table_info(session_rollup)")
            .compactMap { $0.string("name") }
        XCTAssertTrue(columns.contains("cost_unknown_events"))
    }
}
