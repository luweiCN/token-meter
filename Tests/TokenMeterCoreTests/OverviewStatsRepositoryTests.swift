import XCTest
@testable import TokenMeterCore

final class OverviewStatsRepositoryTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.firstWeekday = 2
        return calendar
    }()

    private func makeDatabase() throws -> SQLiteDatabase {
        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)
        return database
    }

    private func insertRollup(
        _ database: SQLiteDatabase,
        date: String,
        tokensInput: Int64,
        tokensOutput: Int64,
        tokensCacheRead: Int64,
        cost: Int64,
        sessions: Int64
    ) throws {
        try database.execute(
            """
            INSERT INTO daily_rollup(
                usage_date, provider_id, source_kind, project_id, model_canonical,
                sessions_count, events_count,
                tokens_input, tokens_output, tokens_reasoning,
                tokens_cache_read, tokens_cache_write_5m, tokens_cache_write_1h,
                cost_usd_micros, cost_unknown_events
            ) VALUES (?, 'codex', 'codex_jsonl', NULL, 'gpt-5', ?, 1, ?, ?, 0, ?, 0, 0, ?, 0)
            """,
            [
                .text(date), .int(sessions), .int(tokensInput),
                .int(tokensOutput), .int(tokensCacheRead), .int(cost)
            ]
        )
    }

    private func now(_ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: day, hour: 12))!
    }

    func testMonthActivityAggregatesCurrentMonthOnly() throws {
        let database = try makeDatabase()
        try insertRollup(database, date: "2026-08-01", tokensInput: 10, tokensOutput: 5, tokensCacheRead: 5, cost: 100, sessions: 1)
        try insertRollup(database, date: "2026-08-17", tokensInput: 1000, tokensOutput: 500, tokensCacheRead: 0, cost: 10_000, sessions: 2)
        try insertRollup(database, date: "2026-08-18", tokensInput: 100, tokensOutput: 50, tokensCacheRead: 0, cost: 1_000, sessions: 3)
        try insertRollup(database, date: "2026-07-31", tokensInput: 9999, tokensOutput: 0, tokensCacheRead: 0, cost: 99_999, sessions: 1)

        let days = MonthActivityRepository.load(from: database, now: now(18), calendar: calendar)
        XCTAssertEqual(days.map(\.date), ["2026-08-01", "2026-08-17", "2026-08-18"])
        XCTAssertEqual(days.first?.tokens, 20)
        XCTAssertEqual(days.first?.costUsdMicros, 100)
        XCTAssertEqual(days.first?.sessions, 1)
    }

    func testOverviewStatsTotalMonthWeekUseMainInterfaceCaliber() throws {
        let database = try makeDatabase()
        try insertRollup(database, date: "2026-08-01", tokensInput: 10, tokensOutput: 5, tokensCacheRead: 5, cost: 100, sessions: 1)
        try insertRollup(database, date: "2026-08-17", tokensInput: 1000, tokensOutput: 500, tokensCacheRead: 0, cost: 10_000, sessions: 2)
        try insertRollup(database, date: "2026-08-18", tokensInput: 100, tokensOutput: 50, tokensCacheRead: 0, cost: 1_000, sessions: 3)
        try insertRollup(database, date: "2026-07-31", tokensInput: 9999, tokensOutput: 0, tokensCacheRead: 0, cost: 99_999, sessions: 1)

        let stats = OverviewStatsRepository.load(from: database, now: now(18), calendar: calendar)

        // 总计含 7 月；本月只算 8 月；本周从周一 8/17 起。
        XCTAssertEqual(stats.total.tokens, 11_669)
        XCTAssertEqual(stats.total.costUsdMicros, 111_099)
        XCTAssertEqual(stats.month.tokens, 1_670)
        XCTAssertEqual(stats.month.costUsdMicros, 11_100)
        XCTAssertEqual(stats.week.tokens, 1_650)
        XCTAssertEqual(stats.week.costUsdMicros, 11_000)
        XCTAssertEqual(stats.totalSessions, 0)
    }

    func testDayTextZeroPadsAndMatchesSqliteLocalTimeShape() {
        let date = calendar.date(from: DateComponents(year: 2026, month: 8, day: 5))!
        XCTAssertEqual(MonthActivityRepository.dayText(date, calendar: calendar), "2026-08-05")
    }
}
