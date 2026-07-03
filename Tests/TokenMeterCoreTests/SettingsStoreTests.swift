import XCTest
@testable import TokenMeterCore

final class SettingsStoreTests: XCTestCase {
    func testImportsTokenMeterConfigIntoSQLiteSettings() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)
        let store = SettingsStore(database: database)
        let config = TokenMeterConfig(
            menuBar: MenuBarConfig(primaryProviderId: "codex"),
            providers: [
                ProviderConfig(
                    id: "codex",
                    type: .codex,
                    displayName: "Codex",
                    enabled: true,
                    credential: nil,
                    endpoint: nil,
                    manualUsage: nil
                ),
                ProviderConfig(
                    id: "claude-code",
                    type: .claudeCode,
                    displayName: "Claude Code",
                    enabled: false,
                    credential: nil,
                    endpoint: nil,
                    manualUsage: nil
                )
            ]
        )

        try store.importConfigIfNeeded(config)
        let snapshot = try store.snapshot()

        XCTAssertEqual(snapshot.version, 1)
        XCTAssertEqual(snapshot.menuBarPrimaryProviderId, "codex")
        XCTAssertEqual(snapshot.autoRefreshSeconds, 300)
        XCTAssertEqual(snapshot.enabledAgentKinds, ["claudeCode", "codex", "opencode", "omp"])
        XCTAssertEqual(snapshot.providerOverrides.first { $0.providerId == "codex" }?.enabled, true)
        XCTAssertEqual(snapshot.providerOverrides.first { $0.providerId == "claude-code" }?.enabled, false)
    }

    func testRejectsStaleSettingsPatch() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)
        let store = SettingsStore(database: database)
        try store.importConfigIfNeeded(ProviderConfigLoader.defaultConfig())

        XCTAssertThrowsError(
            try store.apply(SettingsPatch(menuBarPrimaryProviderId: "zhipu"), expectedVersion: 0, updatedBy: .electron)
        ) { error in
            XCTAssertEqual(error as? SettingsStoreError, .staleVersion(expected: 0, actual: 1))
        }
    }
}
