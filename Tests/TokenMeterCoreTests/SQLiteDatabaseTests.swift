import XCTest
@testable import TokenMeterCore

final class SQLiteDatabaseTests: XCTestCase {
    func testReadOnlySourceReadsClosedWALDatabaseWithoutCreatingCompanions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let active = directory.appendingPathComponent("active.sqlite")
        let closed = directory.appendingPathComponent("closed.sqlite")
        let writer = try SQLiteDatabase(path: active.path)
        try writer.execute("PRAGMA journal_mode=WAL")
        try writer.execute("CREATE TABLE entry(value INTEGER)")
        try writer.execute("INSERT INTO entry VALUES (1)")
        try writer.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try FileManager.default.copyItem(at: active, to: closed)
        try writer.execute("INSERT INTO entry VALUES (2)")

        let offline = try SQLiteDatabase(path: closed.path, readOnly: true)
        XCTAssertEqual(try offline.query("SELECT sum(value) AS n FROM entry").first?.int("n"), 1)
        XCTAssertThrowsError(try offline.execute("DELETE FROM entry"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: closed.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: closed.path + "-shm"))
        let live = try SQLiteDatabase(path: active.path, readOnly: true)
        XCTAssertEqual(try live.query("SELECT sum(value) AS n FROM entry").first?.int("n"), 3)
    }

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

    func testReadOnlyConnectionReadsButCannotMutateOrCreateDatabase() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenmeter-readonly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.sqlite")
        let writer = try SQLiteDatabase(path: url.path)
        try writer.execute("CREATE TABLE source_rows(value INTEGER NOT NULL)")
        try writer.execute("INSERT INTO source_rows(value) VALUES (7)")
        try writer.close()

        let reader = try SQLiteDatabase(path: url.path, readOnly: true)
        XCTAssertEqual(try reader.query("SELECT value FROM source_rows").first?.int("value"), 7)
        XCTAssertThrowsError(try reader.execute("INSERT INTO source_rows(value) VALUES (8)"))

        let missing = directory.appendingPathComponent("missing.sqlite")
        XCTAssertThrowsError(try SQLiteDatabase(path: missing.path, readOnly: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }
}
