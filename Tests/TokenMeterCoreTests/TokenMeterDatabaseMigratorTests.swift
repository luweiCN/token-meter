import XCTest
@testable import TokenMeterCore

final class TokenMeterDatabaseMigratorTests: XCTestCase {
    func testMigratesPhaseTwoSchemaAndEnablesWAL() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("tokenmeter.sqlite")
        let database = try SQLiteDatabase(path: url.path)

        try TokenMeterDatabaseMigrator.migrate(database)

        XCTAssertEqual(try database.query("PRAGMA user_version")[0].int("user_version"), 1)
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
        try database.execute("PRAGMA user_version = 2")

        XCTAssertThrowsError(try TokenMeterDatabaseMigrator.migrate(database)) { error in
            XCTAssertEqual(error as? TokenMeterDatabaseMigratorError, .unsupportedNewerVersion(2))
        }
        XCTAssertEqual(try database.query("PRAGMA user_version")[0].int("user_version"), 2)
    }
}
