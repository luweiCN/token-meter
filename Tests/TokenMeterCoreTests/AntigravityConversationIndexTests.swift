import Foundation
import XCTest
@testable import TokenMeterCore

final class AntigravityConversationIndexTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testCountsVisibleRootOnceAndExcludesAllKnownFormsOfBackgroundActivity() throws {
        let root = try profile("custom", entries: """
            {"main":{"is_internal":false},"internal":{"is_internal":true},
             "child":{"is_internal":false},"nested":{},"linked":{},"other-date":"malformed"}
            """, rows: [("main", "", 0), ("child", "main", 0), ("nested", "", 2)], links: [("linked", "main")])
        let keys = ["main", "main", "internal", "child", "nested", "linked"]
        XCTAssertEqual(AntigravityCLIUsage.topLevelSessionCount(keys.map { ($0, root) }), 1)
        XCTAssertEqual(AntigravityCLIUsage.topLevelSessionCount([("internal", root), ("child", root)]), 0)
    }

    func testCountsAcrossProfilesAndReadsExplicitVisibilityFromSummary() throws {
        let a = try profile("profileA", entries: #"{"a":{"is_internal":false}}"#, rows: [("a", "", 0)])
        let b = try profile("profileB", entries: #"{"b":{"summary":{"Internal":false}}}"#, rows: [("b", "", 0)], links: nil)
        XCTAssertEqual(AntigravityCLIUsage.topLevelSessionCount([("a", a), ("b", b)]), 2)
        XCTAssertEqual(AntigravityCLIUsage.topLevelSessionCount([]), 0)
    }

    func testMissingOrContradictoryMetadataHidesCountOfActiveSessionsOnly() throws {
        let root = try profile("active", entries: """
            {"ok":{"is_internal":false},"missing-in-summary":{"is_internal":false},
             "invalid":{"is_internal":"false"},"conflict":{"is_internal":false,"summary":{"Internal":true}}}
            """, rows: [("ok", "", 0), ("missing-in-cache", "", 0), ("invalid", "", 0), ("conflict", "", 0)])
        for missing in ["missing-in-summary", "missing-in-cache", "invalid", "conflict"] {
            XCTAssertNil(AntigravityCLIUsage.topLevelSessionCount([("ok", root), (missing, root)]))
        }
        XCTAssertNil(AntigravityCLIUsage.topLevelSessionCount([("ok", "")]))
        XCTAssertEqual(AntigravityCLIUsage.topLevelSessionCount([("ok", root)]), 1)
    }

    func testMissingIndexesDoNotCreateFilesOrTurnUnknownIntoZero() throws {
        let root = try profile("missing", entries: #"{"hidden":{"is_internal":true},"visible":{"is_internal":false}}"#, rows: [])
        let db = directory.appendingPathComponent("missing/conversation_summaries.db")
        try FileManager.default.removeItem(at: db)
        XCTAssertEqual(AntigravityCLIUsage.topLevelSessionCount([("hidden", root)]), 0)
        XCTAssertNil(AntigravityCLIUsage.topLevelSessionCount([("visible", root)]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: db.path))
    }

    private func profile(_ name: String, entries: String, rows: [(String, String, Int64)], links: [(String, String)]? = []) throws -> String {
        let profile = directory.appendingPathComponent(name)
        let cache = profile.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("{\"conversations\":\(entries)}".utf8).write(to: cache.appendingPathComponent("conversation_metadata.json"))
        let database = try SQLiteDatabase(path: profile.appendingPathComponent("conversation_summaries.db").path)
        defer { try? database.close() }
        try database.execute("CREATE TABLE conversation_summaries(conversation_id TEXT PRIMARY KEY, parent_conversation_id TEXT, nesting_depth INTEGER)")
        for (id, parent, depth) in rows {
            try database.execute("INSERT INTO conversation_summaries VALUES (?,?,?)", [.text(id), .text(parent), .int(depth)])
        }
        if let links {
            try database.execute("CREATE TABLE conversation_parents(conversation_id TEXT PRIMARY KEY, parent_id TEXT)")
            for (id, parent) in links {
                try database.execute("INSERT INTO conversation_parents VALUES (?,?)", [.text(id), .text(parent)])
            }
        }
        return profile.appendingPathComponent("conversations").path
    }
}
