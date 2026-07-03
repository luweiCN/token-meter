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

        try database.execute(TokenMeterDatabaseSchema.v1)
    }
}

public enum TokenMeterDatabaseMigratorError: Error, Equatable {
    case unsupportedNewerVersion(Int64)
}
