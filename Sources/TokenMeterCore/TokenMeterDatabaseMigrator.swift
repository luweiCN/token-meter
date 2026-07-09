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

        let currentVersion = try database.query("PRAGMA user_version")[0].int("user_version") ?? 0
        guard currentVersion != TokenMeterDatabaseSchema.derivedVersion else { return }

        try rebuildDerivedTables(database)
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
