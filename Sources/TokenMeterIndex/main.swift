import Darwin
import Foundation
import TokenMeterCore

@main
struct TokenMeterIndex {
    static func main() async {
        do { try await scan() }
        catch LocalAgentScannerError.scanAlreadyInProgress { exit(75) }
        catch {
            FileHandle.standardError.write(Data("TokenMeterIndex: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func scan() async throws {
        let url = TokenMeterPaths.databaseURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try SQLiteDatabase(path: url.path)
        try TokenMeterDatabaseMigrator.migrate(db)
        let settings = SettingsStore(database: db)
        try settings.importConfigIfNeeded(ProviderConfigLoader.current())
        try LocalAgentScanner.seedDefaultScanRoots(database: db)
        let snapshot = try settings.snapshot()
        let roots = try LocalAgentScanner.enabledRoots(in: db, settings: snapshot)
        let scanner = LocalAgentScanner(database: db)
        let failures = try await scanner.scanRoots(ids: roots.compactMap { $0.int("id") })
        // The service schedules the next pass using the user's desktop setting.
        let result = ["scanned": roots.count - failures.count, "failures": failures.count, "interval": snapshot.autoRefreshSeconds]
        FileHandle.standardOutput.write(try JSONEncoder().encode(result))
    }
}
