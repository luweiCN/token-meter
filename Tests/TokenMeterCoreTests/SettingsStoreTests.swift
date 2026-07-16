import XCTest
import Foundation
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

    func testStoresEnabledAgentKindsAsJSONSetting() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)
        let store = SettingsStore(database: database)
        try store.importConfigIfNeeded(ProviderConfigLoader.defaultConfig())

        let row = try database.query(
            "SELECT value_json, value_type FROM settings WHERE key = ?",
            [.text("filters.enabledAgentKinds")]
        )[0]

        XCTAssertEqual(row.string("value_type"), "json")
        XCTAssertEqual(try store.snapshot().enabledAgentKinds, ["claudeCode", "codex", "opencode", "omp"])

        try database.execute(
            "UPDATE settings SET value_json = ?, value_type = ? WHERE key = ?",
            [.text("[\"codex\"]"), .text("json"), .text("filters.enabledAgentKinds")]
        )
        XCTAssertEqual(try store.snapshot().enabledAgentKinds, ["codex"])
    }

    func testRejectsEmptySettingsPatch() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)
        let store = SettingsStore(database: database)
        try store.importConfigIfNeeded(ProviderConfigLoader.defaultConfig())

        XCTAssertThrowsError(
            try store.apply(SettingsPatch(), expectedVersion: 1, updatedBy: .electron)
        ) { error in
            XCTAssertEqual(error as? SettingsStoreError, .invalidValue("settings patch must change at least one setting"))
        }
        XCTAssertEqual(try store.snapshot().version, 1)
    }

    func testRejectsPatchThatBecameStaleWhileWaitingForWriteLock() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("settings.sqlite")
        let writer = try SQLiteDatabase(path: url.path)
        let competing = try SQLiteDatabase(path: url.path)
        try TokenMeterDatabaseMigrator.migrate(writer)
        let store = SettingsStore(database: competing)
        try SettingsStore(database: writer).importConfigIfNeeded(ProviderConfigLoader.defaultConfig())

        try writer.execute("BEGIN IMMEDIATE")
        try writer.execute(
            "UPDATE settings SET value_json = ?, version = ? WHERE key = ?",
            [.text("600"), .int(2), .text("scan.autoRefreshSeconds")]
        )

        let result = LockProtected<Result<SettingsApplyRequest, Error>?>(nil)
        let finished = expectation(description: "stale patch rejected")
        DispatchQueue.global(qos: .userInitiated).async {
            let applyResult = Result {
                try store.apply(SettingsPatch(menuBarPrimaryProviderId: "zhipu"), expectedVersion: 1, updatedBy: .electron)
            }
            result.set(applyResult)
            finished.fulfill()
        }

        Thread.sleep(forTimeInterval: 0.1)
        try writer.execute("COMMIT")
        wait(for: [finished], timeout: 5)

        switch result.value() {
        case let .failure(error):
            XCTAssertEqual(error as? SettingsStoreError, .staleVersion(expected: 1, actual: 2))
        case .success, .none:
            XCTFail("Expected staleVersion after the competing writer committed version 2")
        }
    }

    // MARK: - 菜单栏外观设置（menubar.* kv + overrides 窗口列）

    func testMenuBarAppearanceDefaultsWhenUnset() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)
        let store = SettingsStore(database: database)
        let snapshot = try store.snapshot()
        XCTAssertEqual(snapshot.menuBarAppearance, .default)
        XCTAssertEqual(snapshot.menuBarAppearance.style, .rings)
        XCTAssertEqual(snapshot.menuBarAppearance.windowOrder, .longFirst)
    }

    func testMenuBarAppearanceReadsStoredValues() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)
        try database.execute(
            "INSERT OR REPLACE INTO settings(key, value_json, value_type, version, updated_by) VALUES ('menubar.style', '\"deck2\"', 'string', 2, 'electron')"
        )
        try database.execute(
            "INSERT OR REPLACE INTO settings(key, value_json, value_type, version, updated_by) VALUES ('menubar.showName', '0', 'int', 2, 'electron')"
        )
        try database.execute(
            "INSERT OR REPLACE INTO settings(key, value_json, value_type, version, updated_by) VALUES ('menubar.usage', '\"cost\"', 'string', 2, 'electron')"
        )
        try database.execute(
            "INSERT OR REPLACE INTO settings(key, value_json, value_type, version, updated_by) VALUES ('menubar.windowOrder', '\"shortFirst\"', 'string', 2, 'electron')"
        )
        try database.execute(
            "INSERT INTO provider_config_overrides(provider_id, menubar_glyph_window, menubar_number_window) VALUES ('claude-code', 'both', 'short')"
        )
        let snapshot = try SettingsStore(database: database).snapshot()
        XCTAssertEqual(snapshot.menuBarAppearance.style, .deck2)
        XCTAssertFalse(snapshot.menuBarAppearance.showName)
        XCTAssertTrue(snapshot.menuBarAppearance.showGlyph)
        XCTAssertEqual(snapshot.menuBarAppearance.usage, .cost)
        XCTAssertEqual(snapshot.menuBarAppearance.windowOrder, .shortFirst)
        let override = snapshot.providerOverrides.first { $0.providerId == "claude-code" }
        XCTAssertEqual(override?.menuBarGlyphWindow, .both)
        XCTAssertEqual(override?.menuBarNumberWindow, .short)
    }

    func testMenuBarAppearanceUnknownValuesFallBackToDefault() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)
        try database.execute(
            "INSERT OR REPLACE INTO settings(key, value_json, value_type, version, updated_by) VALUES ('menubar.style', '\"holographic\"', 'string', 2, 'electron')"
        )
        let snapshot = try SettingsStore(database: database).snapshot()
        XCTAssertEqual(snapshot.menuBarAppearance.style, .rings)
    }

    func testMigratorAddsMenubarColumnsToLegacyOverridesTable() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        // 老库：无 menubar 列的 overrides 表已存在
        try database.execute(
            """
            CREATE TABLE provider_config_overrides (
              provider_id TEXT PRIMARY KEY,
              enabled INTEGER CHECK (enabled IN (0,1)),
              display_name TEXT,
              menu_rank INTEGER,
              show_in_menu_bar INTEGER CHECK (show_in_menu_bar IN (0,1)),
              show_in_charts INTEGER CHECK (show_in_charts IN (0,1)),
              updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
            """
        )
        try database.execute("INSERT INTO provider_config_overrides(provider_id, enabled) VALUES ('zhipu', 1)")
        try TokenMeterDatabaseMigrator.migrate(database)
        let columns = try database.query("PRAGMA table_info(provider_config_overrides)").compactMap { $0.string("name") }
        XCTAssertTrue(columns.contains("menubar_glyph_window"))
        XCTAssertTrue(columns.contains("menubar_number_window"))
        // 旧行保留
        XCTAssertEqual(try database.query("SELECT count(*) AS c FROM provider_config_overrides")[0].int("c"), 1)
        // 幂等：再跑一次不炸
        try TokenMeterDatabaseMigrator.migrate(database)
    }
}

private final class LockProtected<Value> {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        self.storedValue = value
    }

    func set(_ value: Value) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }

    func value() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}
