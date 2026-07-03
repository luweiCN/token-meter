import XCTest
@testable import TokenMeterCore

final class SQLiteDatabaseTests: XCTestCase {
    func testOpensInMemoryDatabaseAndUsesParameters() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try database.execute("CREATE TABLE values_table (id INTEGER PRIMARY KEY, value TEXT NOT NULL)")
        try database.execute("INSERT INTO values_table (value) VALUES (?)", [.text("'; DROP TABLE values_table; --")])

        let rows = try database.query("SELECT value FROM values_table WHERE value = ?", [.text("'; DROP TABLE values_table; --")])

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].string("value"), "'; DROP TABLE values_table; --")
        XCTAssertEqual(try database.query("SELECT count(*) AS count FROM values_table")[0].int("count"), 1)
    }

    func testFinalizesStatementWhenBindingFails() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("binding.sqlite")
        let database = try SQLiteDatabase(path: url.path)
        try database.execute("CREATE TABLE values_table (id INTEGER PRIMARY KEY, value TEXT NOT NULL)")

        XCTAssertThrowsError(
            try database.execute("INSERT INTO values_table (value) VALUES (?)", [.text("kept"), .text("extra")])
        )

        XCTAssertNoThrow(try database.close())
    }
}
