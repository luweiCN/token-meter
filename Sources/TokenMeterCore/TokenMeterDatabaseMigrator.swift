import Foundation

public enum TokenMeterDatabaseMigrator {
    /// 永不删除的配置表。其余出现在库里的一切都被当作派生数据看待。
    static let configTableNames: Set<String> = ["settings", "provider_config_overrides", "scan_roots"]

    /// 数据库是纯派生物，所以没有版本化迁移链，只有「重建」：
    /// 1. 幂等地建好配置表（CREATE TABLE IF NOT EXISTS，每次启动跑都安全）。
    /// 2. 读 user_version；等于 derivedVersion 就完成。
    /// 3. 否则删光所有非配置表、重跑 derivedTables、清 scan_roots 的扫描状态、写 user_version。
    ///
    /// 版本比较用 `!=` 而不是 `<`：无论 user_version 比 derivedVersion 高还是低，只要不等就重建。
    /// 于是「降级」也是安全的——数据的真相在会话文件里，任意方向的重建都等价且无损，
    /// 不再需要「更高版本 = 报错拒绝」这种防御。
    public static func migrate(_ database: SQLiteDatabase) throws {
        try database.execute("PRAGMA journal_mode = WAL")
        try database.execute("PRAGMA synchronous = NORMAL")
        try database.execute("PRAGMA foreign_keys = ON")
        try database.execute("PRAGMA temp_store = MEMORY")
        try database.execute("PRAGMA busy_timeout = 5000")

        try database.execute(TokenMeterDatabaseSchema.configTables)
        // 配置表不参与版本重建，新增列走幂等 additive 迁移（必须每次跑，不受版本短路影响）。
        try ensureConfigColumns(database)
        try ensureScanRootsKind(database)
        try ensureNewAgentDefaults(database)

        let currentVersion = try database.query("PRAGMA user_version")[0].int("user_version") ?? 0
        if currentVersion != TokenMeterDatabaseSchema.derivedVersion {
            try rebuildDerivedTables(database)
        }

        // 运行时表必须在派生表重建之后建：rebuildDerivedTables 的「非配置表全删」
        // 网兜会把它一并 DROP，先建后删就丢表了。
        try database.execute(TokenMeterDatabaseSchema.runtimeTables)
    }

    /// 配置表（settings / provider_config_overrides）里的新列：缺列才 ALTER，
    /// 老库数据原样保留；新库建表语句已含列，PRAGMA 检查天然幂等。
    private static func ensureConfigColumns(_ database: SQLiteDatabase) throws {
        let columns = try database.query("PRAGMA table_info(provider_config_overrides)")
            .compactMap { $0.string("name") }
        if !columns.contains("menubar_glyph_window") {
            try database.execute(
                "ALTER TABLE provider_config_overrides ADD COLUMN menubar_glyph_window TEXT CHECK (menubar_glyph_window IN ('short','long','both'))"
            )
        }
        if !columns.contains("menubar_number_window") {
            try database.execute(
                "ALTER TABLE provider_config_overrides ADD COLUMN menubar_number_window TEXT CHECK (menubar_number_window IN ('short','long','both'))"
            )
        }
        if !columns.contains("menubar_glyph_windows") {
            try database.execute(
                "ALTER TABLE provider_config_overrides ADD COLUMN menubar_glyph_windows TEXT"
            )
        }
        if !columns.contains("menubar_number_windows") {
            try database.execute(
                "ALTER TABLE provider_config_overrides ADD COLUMN menubar_number_windows TEXT"
            )
        }
    }

    /// scan_roots.kind 的 CHECK 约束无法 ALTER：新增 kind（如 reasonix_stats）时旧库
    /// 会拒绝插入。幂等重建——建新表（最新 CHECK）、原样搬行、换名。列定义与
    /// TokenMeterDatabaseSchema.configTables 的 scan_roots 保持同构。
    /// 全程关外键：source_files 引用 scan_root_id，开着外键 DROP 会被引用检查绊住；
    /// source_files 属派生数据，随后按需重建。
    private static func ensureScanRootsKind(_ database: SQLiteDatabase) throws {
        let createSQL = try database.query(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'scan_roots'"
        )[0].string("sql") ?? ""
        guard !createSQL.contains("reasonix_stats") else { return }

        try database.execute("PRAGMA foreign_keys = OFF")
        defer { try? database.execute("PRAGMA foreign_keys = ON") }
        try database.execute(
            """
            CREATE TABLE scan_roots_new (
              id INTEGER PRIMARY KEY,
              kind TEXT NOT NULL CHECK (kind IN ('claude_jsonl', 'codex_jsonl', 'omp_jsonl', 'opencode_sqlite', 'reasonix_stats')),
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
            )
            """
        )
        try database.execute(
            """
            INSERT INTO scan_roots_new (
              id, kind, root_path, display_name, enabled, scan_mode, file_glob, source_db_path,
              stable_source_key, created_at, updated_at, last_scan_started_at,
              last_scan_finished_at, last_successful_cursor, last_error
            )
            SELECT id, kind, root_path, display_name, enabled, scan_mode, file_glob, source_db_path,
                   stable_source_key, created_at, updated_at, last_scan_started_at,
                   last_scan_finished_at, last_successful_cursor, last_error
            FROM scan_roots
            """
        )
        try database.execute("DROP TABLE scan_roots")
        try database.execute("ALTER TABLE scan_roots_new RENAME TO scan_roots")
    }

    /// 老库的 enabledAgentKinds 是导入时的默认集（不含后来新增的 agent）：
    /// 仅当数组恰好等于旧默认全集（没被用户改过）时，把新 agent（reasonix）补进默认启用列表。
    /// 用户手动调整过（关掉某个 agent、或关掉 reasonix 后又重启）数组就不再等于旧全集，
    /// 不会被反复加回来——这是幂等的关键。
    private static func ensureNewAgentDefaults(_ database: SQLiteDatabase) throws {
        let legacyDefaults = Set(["claudeCode", "codex", "opencode", "omp"])
        let rows = try database.query(
            "SELECT value_json FROM settings WHERE key = 'filters.enabledAgentKinds'"
        )
        guard let json = rows.first?.string("value_json"),
              let data = json.data(using: .utf8),
              var kinds = try? JSONSerialization.jsonObject(with: data) as? [String],
              Set(kinds) == legacyDefaults else {
            return
        }
        kinds.append("reasonix")
        guard let updated = String(data: try JSONSerialization.data(withJSONObject: kinds), encoding: .utf8) else {
            return
        }
        try database.execute(
            "UPDATE settings SET value_json = ?, updated_at = CURRENT_TIMESTAMP WHERE key = 'filters.enabledAgentKinds'",
            [.text(updated)]
        )
    }

    private static func rebuildDerivedTables(_ database: SQLiteDatabase) throws {
        // 开着外键时，DROP TABLE 会对每张表做一次隐式逐行 DELETE 以触发级联；真实库里
        // usage_events 有数十万行，那会很慢。派生数据整体作废、不需要级联语义，故重建期间关外键，
        // 让 DROP TABLE 直接回收 b-tree。migrate() 结束前会重新打开。
        try database.execute("PRAGMA foreign_keys = OFF")
        for name in try derivedTableNames(in: database) {
            try database.execute("DROP TABLE IF EXISTS \"\(name)\"")
        }
        try database.execute(TokenMeterDatabaseSchema.derivedTables)
        // scan_roots 是配置表却携带扫描状态；重建后必须清回「从未扫描过」，否则增量游标会挡住重建。
        // 与 LocalAgentScanner.fullRescan 共用同一段常量，清同样的列，不会漂移。
        try database.execute(TokenMeterDatabaseSchema.resetScanState)
        try database.execute("PRAGMA foreign_keys = ON")
        try database.execute("PRAGMA user_version = \(TokenMeterDatabaseSchema.derivedVersion)")
    }

    /// 库里除配置表和 sqlite_ 内部表之外的所有表。遗留表（session_usage、provider_daily_usage、
    /// schema_migrations 等）也会被这一网兜住并丢弃——它们既非配置也不在 derivedTables 里。
    private static func derivedTableNames(in database: SQLiteDatabase) throws -> [String] {
        try database.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
            .compactMap { $0.string("name") }
            .filter { !configTableNames.contains($0) }
    }
}
