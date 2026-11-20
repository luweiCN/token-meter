import XCTest
@testable import TokenMeterCore

final class PromptCacheUsageTests: XCTestCase {
    func testWeightedInputAcrossModelsDaysAndOverviewPeriods() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(db)
        let now = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 12)))
        func add(_ day: String, _ provider: String, _ model: String, fresh: Int64, read: Int64,
                 write5m: Int64 = 0, write1h: Int64 = 0) throws {
            try db.execute("""
                INSERT INTO daily_rollup(usage_date, provider_id, source_kind, model_canonical,
                    tokens_input, tokens_cache_read, tokens_cache_write_5m, tokens_cache_write_1h, tokens_output, tokens_reasoning)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 10000, 5000)
                """, [.text(day), .text(provider), .text(provider), .text(model), .int(fresh), .int(read), .int(write5m), .int(write1h)])
        }
        try add("2026-11-18", "codex", "a", fresh: 10, read: 90)
        try add("2026-11-18", "claude", "a", fresh: 0, read: 10, write5m: 40, write1h: 50)
        try add("2026-11-18", "codex", "b", fresh: 800, read: 0)
        try add("2026-11-18", "codex", "output-only", fresh: 0, read: 0)
        try add("2026-11-17", "codex", "a", fresh: 0, read: 1000)
        try add("2026-11-02", "codex", "a", fresh: 2000, read: 0)
        try add("2026-10-10", "codex", "a", fresh: 0, read: 4000)

        let today = MenuBarTodaySummaryRepository.load(from: db, now: now)
        let models = Dictionary(uniqueKeysWithValues: today.perModel.map { ($0.model, $0.cacheUsage) })
        XCTAssertEqual(models["a"], PromptCacheUsage(readTokens: 100, inputTokens: 200))
        XCTAssertEqual(models["b"]?.hitRate, 0)
        XCTAssertNil(try XCTUnwrap(models["output-only"]).hitRate)
        XCTAssertEqual(today.cacheUsage, PromptCacheUsage(readTokens: 100, inputTokens: 1000))
        let breakdown = DayModelBreakdownRepository.load(from: db, date: "2026-11-18")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: breakdown.map { ($0.model, $0.cacheUsage) }), models)
        let month = MonthActivityRepository.load(from: db, now: now)
        XCTAssertEqual(month.first { $0.date == "2026-11-18" }?.cacheUsage, today.cacheUsage)
        XCTAssertEqual(month.first { $0.date == "2026-11-17" }?.cacheUsage.hitRate, 1)
        let overview = OverviewStatsRepository.load(from: db, now: now)
        XCTAssertEqual(overview.week.cacheUsage, PromptCacheUsage(readTokens: 1100, inputTokens: 2000))
        XCTAssertEqual(overview.month.cacheUsage, PromptCacheUsage(readTokens: 1100, inputTokens: 4000))
        XCTAssertEqual(overview.total.cacheUsage, PromptCacheUsage(readTokens: 5100, inputTokens: 8000))
    }
}
