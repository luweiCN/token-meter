import XCTest
@testable import TokenMeterCore

final class TokenMeterDatabaseMigratorTests: XCTestCase {
    func testMigratesPhaseTwoSchemaAndEnablesWAL() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("tokenmeter.sqlite")
        let database = try SQLiteDatabase(path: url.path)

        try TokenMeterDatabaseMigrator.migrate(database)

        XCTAssertEqual(try database.query("PRAGMA user_version")[0].int("user_version"), 3)
        XCTAssertEqual(try database.query("PRAGMA journal_mode")[0].string("journal_mode"), "wal")
        XCTAssertEqual(try database.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'agent_sessions'").count, 1)
        XCTAssertEqual(try database.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'usage_events'").count, 1)
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

    func testMigratesFreshDatabaseToVersion3() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)

        let version = try database.query("PRAGMA user_version")[0].int("user_version")
        XCTAssertEqual(version, 3)

        let tables = try database.query("SELECT name FROM sqlite_master WHERE type = 'table'")
            .compactMap { $0.string("name") }
        XCTAssertTrue(tables.contains("usage_events"))
        XCTAssertTrue(tables.contains("daily_rollup"))
        XCTAssertTrue(tables.contains("session_rollup"))
        XCTAssertTrue(tables.contains("model_pricing"))
    }

    func testMigrationToV3DropsLegacyUsageTables() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)

        XCTAssertEqual(try database.query("PRAGMA user_version")[0].int("user_version"), 3)

        let tables = try database.query("SELECT name FROM sqlite_master WHERE type = 'table'")
            .compactMap { $0.string("name") }
        XCTAssertFalse(tables.contains("session_usage"))
        XCTAssertFalse(tables.contains("session_usage_latest"))
        XCTAssertFalse(tables.contains("provider_daily_usage"))

        // 新表必须还在
        XCTAssertTrue(tables.contains("usage_events"))
        XCTAssertTrue(tables.contains("daily_rollup"))
        XCTAssertTrue(tables.contains("session_rollup"))
    }

    func testMigrationToV3DropsRedundantSessionColumns() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)

        let columns = try database.query("PRAGMA table_info(agent_sessions)")
            .compactMap { $0.string("name") }

        // 已下沉到 usage_events / 再无人读的列被删
        XCTAssertFalse(columns.contains("model_name"))
        XCTAssertFalse(columns.contains("source_file_id"))
        XCTAssertFalse(columns.contains("total_cost_usd_micros"))
        XCTAssertFalse(columns.contains("worktree_path"))
        XCTAssertFalse(columns.contains("session_closed_at"))

        // 会话元信息保留
        XCTAssertTrue(columns.contains("source_session_key"))
        XCTAssertTrue(columns.contains("project_id"))
        XCTAssertTrue(columns.contains("provider_id"))

        // sessionsRepository.query 仍从 agent_sessions 读这三列，绝不能删——
        // 删了会让会话列表查询抛 "no such column"（计划原稿曾把它们列进 DROP）。
        XCTAssertTrue(columns.contains("model_provider"))
        XCTAssertTrue(columns.contains("message_count"))
        XCTAssertTrue(columns.contains("event_count"))
    }

    func testV1DatabaseMigratesAllTheWayToV3() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try database.execute(TokenMeterDatabaseSchema.v1)
        try database.execute(
            """
            INSERT INTO scan_roots(kind, root_path, display_name, stable_source_key, last_successful_cursor)
            VALUES ('claude_jsonl', '/tmp/claude', 'Claude', 'claude:/tmp/claude', 'cursor-123')
            """
        )

        try TokenMeterDatabaseMigrator.migrate(database)

        XCTAssertEqual(try database.query("PRAGMA user_version")[0].int("user_version"), 3)
        let tables = try database.query("SELECT name FROM sqlite_master WHERE type = 'table'")
            .compactMap { $0.string("name") }
        XCTAssertFalse(tables.contains("session_usage"))
        XCTAssertFalse(tables.contains("provider_daily_usage"))
        XCTAssertTrue(tables.contains("usage_events"))

        // v1→v3 升级不重扫：游标保持不动，全量重扫由 Task 15 的按钮显式触发。
        let roots = try database.query("SELECT last_successful_cursor FROM scan_roots")
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots[0].string("last_successful_cursor"), "cursor-123")
    }

    func testV2DatabaseMigratesToV3AndKeepsUsageEventRows() throws {
        // 已经跑到 v2 的老库（Task 3–17 开发期用户）升级到 v3：v1 表消失，usage_events 数据留存。
        let database = try SQLiteDatabase(path: ":memory:")
        try database.execute(TokenMeterDatabaseSchema.v1)
        try database.execute(TokenMeterDatabaseSchema.v2Additions)
        XCTAssertEqual(try database.query("PRAGMA user_version")[0].int("user_version"), 2)

        try database.execute(
            "INSERT INTO scan_roots(id, kind, root_path, display_name, stable_source_key) VALUES (1, 'claude_jsonl', '/tmp/c', 'C', 'c')"
        )
        try database.execute(
            "INSERT INTO source_files(id, scan_root_id, relative_path, canonical_path, file_type, size_bytes, mtime_ns) VALUES (1, 1, 'a.jsonl', '/tmp/c/a.jsonl', 'jsonl_session', 1, 1)"
        )
        try database.execute(
            "INSERT INTO agent_sessions(id, source_kind, source_session_key, scan_root_id, source_revision) VALUES (1, 'claude_jsonl', 's1', 1, 'rev')"
        )
        try database.execute(
            """
            INSERT INTO usage_events(session_id, source_file_id, event_seq, observed_epoch_ms, tokens_input, cost_source, source_offset)
            VALUES (1, 1, 1, 0, 42, 'unknown', 0)
            """
        )

        try TokenMeterDatabaseMigrator.migrate(database)

        XCTAssertEqual(try database.query("PRAGMA user_version")[0].int("user_version"), 3)
        let tables = try database.query("SELECT name FROM sqlite_master WHERE type = 'table'")
            .compactMap { $0.string("name") }
        XCTAssertFalse(tables.contains("session_usage"))
        XCTAssertFalse(tables.contains("provider_daily_usage"))
        // v2 已经写入的 usage_events 明细在升级后仍在。
        XCTAssertEqual(try database.query("SELECT tokens_input FROM usage_events")[0].int("tokens_input"), 42)
    }

    func testMigrationIsIdempotent() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)
        try TokenMeterDatabaseMigrator.migrate(database)

        XCTAssertEqual(try database.query("PRAGMA user_version")[0].int("user_version"), 3)
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
