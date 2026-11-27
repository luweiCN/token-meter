import XCTest
@testable import TokenMeterCore

final class AccountCreditsTests: XCTestCase {
    func testOnePersistedBalancePinCanBeReplacedAndCleared() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)
        let store = SettingsStore(database: database)
        XCTAssertNil(try store.snapshot().menuBarAppearance.pinnedBalanceProviderId)
        var version = try store.snapshot().version
        for id: String? in ["codex", "claude-code", nil] {
            try store.setPinnedBalanceProvider(id)
            let saved = try SettingsStore(database: database).snapshot()
            XCTAssertEqual(saved.menuBarAppearance.pinnedBalanceProviderId, id)
            XCTAssertEqual(saved.version, version + 1)
            version = saved.version
        }
    }
}
