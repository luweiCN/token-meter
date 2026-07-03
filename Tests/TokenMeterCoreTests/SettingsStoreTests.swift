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
