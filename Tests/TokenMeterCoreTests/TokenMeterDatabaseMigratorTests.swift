import XCTest
@testable import TokenMeterCore

/// 数据库是纯派生物：真相在会话文件里（~/.claude、~/.codex、~/.omp、opencode.db）。
/// 这些测试钉住新契约——配置永存、派生随 schema 版本整体重建、任意方向的版本不符都重建。
final class TokenMeterDatabaseMigratorTests: XCTestCase {
    // MARK: - Helpers

    private func memoryDatabase() throws -> SQLiteDatabase {
        try SQLiteDatabase(path: ":memory:")
    }

    private func tableNames(_ database: SQLiteDatabase) throws -> [String] {
        try database.query("SELECT name FROM sqlite_master WHERE type = 'table'")
            .compactMap { $0.string("name") }
    }

    private func userVersion(_ database: SQLiteDatabase) throws -> Int64? {
        try database.query("PRAGMA user_version")[0].int("user_version")
    }

    private func rowCount(_ database: SQLiteDatabase, _ table: String) throws -> Int64? {
        try database.query("SELECT count(*) AS n FROM \(table)")[0].int("n")
    }

    /// 老 v1 库的建表 SQL，从 git 历史（dd0fb85 之前的 TokenMeterDatabaseSchema.v1）原样搬来，
    /// 作为测试夹具——生产代码里那段版本化迁移机器已被删除。它建出「没有 usage_events、
    /// agent_sessions 还带 source_file_id/model_name 等列、且存在 schema_migrations」的老形状，
    /// 并把 user_version 设为 1。
    private static let legacyV1SQL = """
    CREATE TABLE IF NOT EXISTS schema_migrations (
      version INTEGER PRIMARY KEY,
      name TEXT NOT NULL UNIQUE,
      applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    );

    CREATE TABLE IF NOT EXISTS settings (
      key TEXT PRIMARY KEY,
      value_json TEXT NOT NULL,
      value_type TEXT NOT NULL CHECK (value_type IN ('string', 'int', 'bool', 'json')),
      version INTEGER NOT NULL,
      updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_by TEXT NOT NULL CHECK (updated_by IN ('swift', 'electron', 'migrator', 'importer'))
    );

    CREATE TABLE IF NOT EXISTS provider_config_overrides (
      provider_id TEXT PRIMARY KEY,
      enabled INTEGER CHECK (enabled IN (0,1)),
      display_name TEXT,
      menu_rank INTEGER,
      show_in_menu_bar INTEGER CHECK (show_in_menu_bar IN (0,1)),
      show_in_charts INTEGER CHECK (show_in_charts IN (0,1)),
      updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    );

    CREATE TABLE IF NOT EXISTS scan_roots (
      id INTEGER PRIMARY KEY,
      kind TEXT NOT NULL CHECK (kind IN ('claude_jsonl', 'codex_jsonl', 'omp_jsonl', 'opencode_sqlite')),
      root_path TEXT NOT NULL,
      display_name TEXT NOT NULL,
      enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0,1)),
      scan_mode TEXT NOT NULL DEFAULT 'incremental' CHECK (scan_mode IN ('incremental', 'full', 'disabled')),
      file_glob TEXT,
      source_db_path TEXT,
      stable_source_key TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
      last_scan_started_at TEXT,
      last_scan_finished_at TEXT,
      last_successful_cursor TEXT,
      last_error TEXT,
      UNIQUE(kind, root_path),
      UNIQUE(stable_source_key)
    );

    CREATE TABLE IF NOT EXISTS source_files (
      id INTEGER PRIMARY KEY,
      scan_root_id INTEGER NOT NULL REFERENCES scan_roots(id) ON DELETE CASCADE,
      relative_path TEXT NOT NULL,
      canonical_path TEXT NOT NULL,
      file_type TEXT NOT NULL CHECK (file_type IN ('jsonl_session', 'sqlite_db')),
      size_bytes INTEGER NOT NULL,
      mtime_ns INTEGER NOT NULL,
      inode INTEGER,
      dev INTEGER,
      content_fingerprint TEXT,
      parser_state TEXT,
      first_seen_run_id INTEGER REFERENCES scan_runs(id) ON DELETE SET NULL,
      last_seen_run_id INTEGER REFERENCES scan_runs(id) ON DELETE SET NULL,
      last_parsed_run_id INTEGER REFERENCES scan_runs(id) ON DELETE SET NULL,
      disappeared_at TEXT,
      parse_status TEXT NOT NULL DEFAULT 'pending' CHECK (parse_status IN ('pending', 'ok', 'partial', 'failed')),
      parse_error TEXT,
      created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
      UNIQUE(scan_root_id, relative_path),
      UNIQUE(scan_root_id, canonical_path)
    );

    CREATE TABLE IF NOT EXISTS projects (
      id INTEGER PRIMARY KEY,
      project_key TEXT NOT NULL UNIQUE,
      canonical_path TEXT NOT NULL,
      display_name TEXT NOT NULL,
      first_seen_at TEXT NOT NULL,
      last_seen_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS agent_sessions (
      id INTEGER PRIMARY KEY,
      source_kind TEXT NOT NULL,
      source_session_key TEXT NOT NULL,
      scan_root_id INTEGER NOT NULL REFERENCES scan_roots(id) ON DELETE CASCADE,
      source_file_id INTEGER REFERENCES source_files(id) ON DELETE SET NULL,
      project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL,
      provider_id TEXT,
      agent_name TEXT,
      model_provider TEXT,
      model_name TEXT,
      cli_version TEXT,
      session_started_at TEXT,
      session_updated_at TEXT,
      session_closed_at TEXT,
      cwd_path TEXT,
      worktree_path TEXT,
      title TEXT,
      status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'closed', 'deleted', 'orphaned')),
      message_count INTEGER,
      event_count INTEGER,
      total_cost_usd_micros INTEGER,
      source_revision TEXT NOT NULL,
      first_seen_run_id INTEGER REFERENCES scan_runs(id) ON DELETE SET NULL,
      last_seen_run_id INTEGER REFERENCES scan_runs(id) ON DELETE SET NULL,
      last_indexed_run_id INTEGER REFERENCES scan_runs(id) ON DELETE SET NULL,
      deleted_at TEXT,
      raw_meta_json TEXT,
      UNIQUE(source_kind, source_session_key)
    );

    CREATE TABLE IF NOT EXISTS session_usage (
      id INTEGER PRIMARY KEY,
      session_id INTEGER NOT NULL REFERENCES agent_sessions(id) ON DELETE CASCADE,
      observed_at TEXT NOT NULL,
      usage_seq INTEGER NOT NULL,
      metric_scope TEXT NOT NULL DEFAULT 'session' CHECK (metric_scope IN ('session', 'window', 'total')),
      window_label TEXT,
      tokens_input INTEGER,
      tokens_output INTEGER,
      tokens_reasoning INTEGER,
      tokens_cache_read INTEGER,
      tokens_cache_write INTEGER,
      cost_usd_micros INTEGER,
      source_event_id TEXT,
      source_offset INTEGER,
      source_hash TEXT,
      is_cumulative INTEGER NOT NULL DEFAULT 1 CHECK (is_cumulative IN (0,1)),
      UNIQUE(session_id, usage_seq)
    );

    CREATE TABLE IF NOT EXISTS provider_daily_usage (
      usage_date TEXT NOT NULL,
      provider_id TEXT NOT NULL,
      project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL,
      source_kind TEXT NOT NULL,
      sessions_count INTEGER NOT NULL,
      tokens_input INTEGER NOT NULL DEFAULT 0,
      total_cost_usd_micros INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (usage_date, provider_id, project_id, source_kind)
    );

    CREATE TABLE IF NOT EXISTS scan_runs (
      id INTEGER PRIMARY KEY,
      scan_root_id INTEGER REFERENCES scan_roots(id) ON DELETE CASCADE,
      run_kind TEXT NOT NULL CHECK (run_kind IN ('discover', 'incremental', 'full', 'repair')),
      started_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
      finished_at TEXT,
      status TEXT NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'ok', 'partial', 'failed')),
      files_seen INTEGER NOT NULL DEFAULT 0,
      cursor_before TEXT,
      cursor_after TEXT,
      error_summary TEXT
    );

    CREATE INDEX IF NOT EXISTS idx_sessions_source_file ON agent_sessions(source_file_id);
    CREATE INDEX IF NOT EXISTS idx_settings_updated ON settings(updated_at DESC);

    PRAGMA user_version = 1;
    """

    /// 在派生表里塞一行会话 + 一条用量事件，用来证明重建会把派生数据清空。
    /// 需要 scan_roots(配置表)先有一行以满足外键。
    private func seedDerivedRows(_ database: SQLiteDatabase) throws {
        try database.execute(
            "INSERT INTO scan_roots(id, kind, root_path, display_name, stable_source_key) VALUES (1, 'claude_jsonl', '/c', 'C', 'c')"
        )
        try database.execute(
            "INSERT INTO source_files(id, scan_root_id, relative_path, canonical_path, file_type, size_bytes, mtime_ns) VALUES (1, 1, 'a.jsonl', '/c/a.jsonl', 'jsonl_session', 1, 1)"
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
    }

    // MARK: - 1. 全新库

    func testFreshDatabaseGetsConfigAndDerivedTablesAtDerivedVersion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLiteDatabase(path: directory.appendingPathComponent("tokenmeter.sqlite").path)

        try TokenMeterDatabaseMigrator.migrate(database)

        XCTAssertEqual(try userVersion(database), TokenMeterDatabaseSchema.derivedVersion)
        XCTAssertEqual(try database.query("PRAGMA journal_mode")[0].string("journal_mode"), "wal")

        let tables = try tableNames(database)
        for config in ["settings", "provider_config_overrides", "scan_roots"] {
            XCTAssertTrue(tables.contains(config), "缺配置表 \(config)")
        }
        for derived in ["source_files", "projects", "agent_sessions", "scan_runs", "usage_events", "daily_rollup", "session_rollup"] {
            XCTAssertTrue(tables.contains(derived), "缺派生表 \(derived)")
        }
    }

    // MARK: - 2. v1 老库整体重建到当前形状

    func testLegacyV1DatabaseRebuildsToCurrentShape() throws {
        let database = try memoryDatabase()
        try database.execute(Self.legacyV1SQL)
        XCTAssertEqual(try userVersion(database), 1)
        // 老形状：有 session_usage / schema_migrations，agent_sessions 还带 model_name，且没有 usage_events。
        XCTAssertTrue(try tableNames(database).contains("session_usage"))
        XCTAssertFalse(try tableNames(database).contains("usage_events"))

        try TokenMeterDatabaseMigrator.migrate(database)

        XCTAssertEqual(try userVersion(database), TokenMeterDatabaseSchema.derivedVersion)
        let tables = try tableNames(database)
        // 派生表重建、且为空
        XCTAssertTrue(tables.contains("usage_events"))
        XCTAssertTrue(tables.contains("daily_rollup"))
        XCTAssertTrue(tables.contains("session_rollup"))
        XCTAssertEqual(try rowCount(database, "usage_events"), 0)
        XCTAssertEqual(try rowCount(database, "agent_sessions"), 0)
        // 遗留表 / 迁移机器被丢弃
        XCTAssertFalse(tables.contains("session_usage"))
        XCTAssertFalse(tables.contains("provider_daily_usage"))
        XCTAssertFalse(tables.contains("schema_migrations"))
        // agent_sessions 换成新形状：不再有下沉到 usage_events 的列
        let sessionColumns = try database.query("PRAGMA table_info(agent_sessions)").compactMap { $0.string("name") }
        XCTAssertFalse(sessionColumns.contains("model_name"))
        XCTAssertFalse(sessionColumns.contains("source_file_id"))
    }

    // MARK: - 3. 配置在重建中存活（押身家的那个）

    func testConfigSurvivesRebuild() throws {
        let database = try memoryDatabase()
        try TokenMeterDatabaseMigrator.migrate(database)

        try database.execute(
            """
            INSERT INTO settings(key, value_json, value_type, version, updated_by)
            VALUES ('filters.enabledAgentKinds', '["claude_code","codex"]', 'json', 7, 'electron')
            """
        )
        try database.execute(
            """
            INSERT INTO provider_config_overrides(provider_id, enabled, display_name, menu_rank, show_in_menu_bar, show_in_charts)
            VALUES ('claude', 1, 'Claude Code', 2, 1, 0)
            """
        )
        // 用户自定义扫描根。只填配置列，扫描状态列留 NULL——这样整行在重建后应逐字节不变
        // （扫描状态清零由 testScanCursorsClearedOnRebuild 单独钉）。
        try database.execute(
            """
            INSERT INTO scan_roots(id, kind, root_path, display_name, enabled, scan_mode, stable_source_key)
            VALUES (99, 'claude_jsonl', '/custom/path', 'My Custom Root', 1, 'incremental', 'custom-key')
            """
        )

        let settingsBefore = try database.query("SELECT * FROM settings ORDER BY key")
        let overridesBefore = try database.query("SELECT * FROM provider_config_overrides ORDER BY provider_id")
        let rootsBefore = try database.query("SELECT * FROM scan_roots ORDER BY id")

        // 把版本号搞错，强制一次重建。
        try database.execute("PRAGMA user_version = 999")
        try TokenMeterDatabaseMigrator.migrate(database)

        XCTAssertEqual(try userVersion(database), TokenMeterDatabaseSchema.derivedVersion)
        XCTAssertEqual(try database.query("SELECT * FROM settings ORDER BY key"), settingsBefore, "settings 必须逐字节存活")
        XCTAssertEqual(try database.query("SELECT * FROM provider_config_overrides ORDER BY provider_id"), overridesBefore, "provider_config_overrides 必须逐字节存活")
        XCTAssertEqual(try database.query("SELECT * FROM scan_roots ORDER BY id"), rootsBefore, "自定义 scan_roots 必须逐字节存活")
    }

    // MARK: - 4. 派生数据不存活

    func testDerivedDataDoesNotSurviveRebuild() throws {
        let database = try memoryDatabase()
        try TokenMeterDatabaseMigrator.migrate(database)
        try seedDerivedRows(database)
        XCTAssertEqual(try rowCount(database, "usage_events"), 1)

        try database.execute("PRAGMA user_version = 999")
        try TokenMeterDatabaseMigrator.migrate(database)

        XCTAssertEqual(try rowCount(database, "usage_events"), 0)
        XCTAssertEqual(try rowCount(database, "agent_sessions"), 0)
        XCTAssertEqual(try rowCount(database, "source_files"), 0)
    }

    // MARK: - 5. 扫描游标被清空（不清就永远拉不回 OpenCode 数据）

    func testScanCursorsClearedOnRebuild() throws {
        let database = try memoryDatabase()
        try TokenMeterDatabaseMigrator.migrate(database)
        try database.execute(
            """
            INSERT INTO scan_roots(id, kind, root_path, display_name, stable_source_key,
                                   last_successful_cursor, last_scan_started_at, last_scan_finished_at, last_error)
            VALUES (1, 'opencode_sqlite', '/oc', 'OC', 'oc',
                    '2026-07-03T00:00:00Z', '2026-07-03T00:00:01Z', '2026-07-03T00:00:02Z', 'boom')
            """
        )

        try database.execute("PRAGMA user_version = 999")
        try TokenMeterDatabaseMigrator.migrate(database)

        let row = try database.query(
            "SELECT last_successful_cursor, last_scan_started_at, last_scan_finished_at, last_error FROM scan_roots WHERE id = 1"
        )[0]
        XCTAssertNil(row.string("last_successful_cursor"), "游标不清空，OpenCode 的 changedSessions(after:) 会挡住重建")
        XCTAssertNil(row.string("last_scan_started_at"))
        XCTAssertNil(row.string("last_scan_finished_at"))
        XCTAssertNil(row.string("last_error"))
    }

    // MARK: - 6. 降级也重建，不抛错

    func testDowngradeRebuildsInsteadOfThrowing() throws {
        let database = try memoryDatabase()
        try TokenMeterDatabaseMigrator.migrate(database)
        try seedDerivedRows(database)

        // 版本高于 derivedVersion：老机器会抛 unsupportedNewerVersion，新机器应重建。
        try database.execute("PRAGMA user_version = \(TokenMeterDatabaseSchema.derivedVersion + 1)")
        try TokenMeterDatabaseMigrator.migrate(database)

        XCTAssertEqual(try userVersion(database), TokenMeterDatabaseSchema.derivedVersion, "版本不符（更高）也应落回 derivedVersion")
        XCTAssertEqual(try rowCount(database, "usage_events"), 0, "降级同样是重建，派生数据被清空")
    }

    // MARK: - 7. 连跑两次是 no-op（第二次绝不能删东西）

    func testMigrateTwiceIsNoOp() throws {
        let database = try memoryDatabase()
        try TokenMeterDatabaseMigrator.migrate(database)
        try seedDerivedRows(database)
        try database.execute("UPDATE scan_roots SET last_successful_cursor = 'keep-me' WHERE id = 1")

        // 版本已等于 derivedVersion，第二次迁移应直接返回，不碰任何派生数据。
        try TokenMeterDatabaseMigrator.migrate(database)

        XCTAssertEqual(try userVersion(database), TokenMeterDatabaseSchema.derivedVersion)
        XCTAssertEqual(try rowCount(database, "usage_events"), 1, "no-op 迁移绝不能清派生表")
        XCTAssertEqual(try rowCount(database, "source_files"), 1, "no-op 迁移绝不能清派生表")
        XCTAssertEqual(
            try database.query("SELECT last_successful_cursor AS c FROM scan_roots WHERE id = 1")[0].string("c"),
            "keep-me",
            "no-op 迁移绝不能清扫描游标"
        )
    }

    // MARK: - 派生 schema 正确性（沿用，仍然有效）

    func testUsageEventsTotalTokensGeneratedColumnExcludesReasoning() throws {
        let database = try memoryDatabase()
        try TokenMeterDatabaseMigrator.migrate(database)
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
            INSERT INTO usage_events(
                session_id, source_file_id, event_seq, observed_epoch_ms,
                tokens_input, tokens_output, tokens_reasoning, tokens_cache_read,
                cost_source, source_offset
            ) VALUES (1, 1, 1, 0, 100, 50, 20, 900, 'unknown', 0)
            """
        )

        XCTAssertEqual(try database.query("SELECT tokens_total FROM usage_events")[0].int("tokens_total"), 1050)
    }

    func testSessionRollupHasCostUnknownEventsColumn() throws {
        let database = try memoryDatabase()
        try TokenMeterDatabaseMigrator.migrate(database)

        let columns = try database.query("PRAGMA table_info(session_rollup)").compactMap { $0.string("name") }
        XCTAssertTrue(columns.contains("cost_unknown_events"))
    }

    /// `configTableNames` 是一份【白名单】：重建时凡是不在其中的表一律删除。
    ///
    /// 这个方向是 fail-dangerous 的——将来谁加了一张配置表却忘了写进白名单，
    /// 它会在下一次 schema 变更时被静默删掉，带走用户的设置。反过来的黑名单
    /// 是 fail-safe 的，但要求维护一份会不断变长的派生表清单，且清不掉遗留表。
    ///
    /// 选了白名单，就得有一道防线：把它与 `configTables` 里【实际声明】的表名钉死。
    func testConfigTableAllowlistMatchesWhatConfigSchemaDeclares() throws {
        let declared = Set(
            TokenMeterDatabaseSchema.configTables
                .components(separatedBy: "CREATE TABLE IF NOT EXISTS ")
                .dropFirst()
                .map { String($0.prefix { !$0.isWhitespace && $0 != "(" }) }
        )

        XCTAssertEqual(
            declared,
            TokenMeterDatabaseMigrator.configTableNames,
            "configTables 声明的表与白名单不一致。不在白名单里的配置表会被重建过程删除。"
        )
    }
}
