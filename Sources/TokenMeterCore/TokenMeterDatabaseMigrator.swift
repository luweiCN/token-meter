public enum TokenMeterDatabaseMigrator {
    public static func migrate(_ database: SQLiteDatabase) throws {
        try database.execute("PRAGMA journal_mode = WAL")
        try database.execute("PRAGMA synchronous = NORMAL")
        try database.execute("PRAGMA foreign_keys = ON")
        try database.execute("PRAGMA temp_store = MEMORY")
        try database.execute("PRAGMA busy_timeout = 5000")

        let currentVersion = try database.query("PRAGMA user_version")[0].int("user_version") ?? 0
        guard currentVersion <= TokenMeterDatabaseSchema.currentVersion else {
            throw TokenMeterDatabaseMigratorError.unsupportedNewerVersion(currentVersion)
        }
        guard currentVersion < TokenMeterDatabaseSchema.currentVersion else { return }

        // v1 全是 CREATE TABLE IF NOT EXISTS，重复执行安全。三段按版本顺序补齐：
        // 全新库跑全部三段；v1 老库跳过第一段；v2 老库只跑 v3 清理。
        // v3Cleanup 含不可幂等的 DROP COLUMN，但上面的 guard 保证 currentVersion < 3 才会到这里，
        // 每列至多被删一次；v1→v3 升级后 usage_events 为空表，全量重扫由 Task 15 的按钮显式触发。
        if currentVersion < 1 {
            try database.execute(TokenMeterDatabaseSchema.v1)
        }
        if currentVersion < 2 {
            try database.execute(TokenMeterDatabaseSchema.v2Additions)
        }
        try database.execute(TokenMeterDatabaseSchema.v3Cleanup)
    }
}

public enum TokenMeterDatabaseMigratorError: Error, Equatable {
    case unsupportedNewerVersion(Int64)
}
