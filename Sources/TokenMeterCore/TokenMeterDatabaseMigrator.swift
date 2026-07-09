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

        // v1 全是 CREATE TABLE IF NOT EXISTS，重复执行安全。
        // 全新库两段都跑；v1 老库跳过第一段，只补上新表。
        if currentVersion < 1 {
            try database.execute(TokenMeterDatabaseSchema.v1)
        }
        try database.execute(TokenMeterDatabaseSchema.v2Additions)
    }
}

public enum TokenMeterDatabaseMigratorError: Error, Equatable {
    case unsupportedNewerVersion(Int64)
}
