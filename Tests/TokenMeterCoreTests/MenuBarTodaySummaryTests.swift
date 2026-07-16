import Foundation
import XCTest
@testable import TokenMeterCore

final class MenuBarTodaySummaryTests: XCTestCase {
    private var database: SQLiteDatabase!
    // 固定在当天正午，避开午夜与 DST 的日期归属歧义。
    private let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)

    override func setUpWithError() throws {
        database = try SQLiteDatabase(path: ":memory:")
        try database.execute("""
        CREATE TABLE daily_rollup (
          usage_date TEXT NOT NULL, provider_id TEXT NOT NULL, source_kind TEXT NOT NULL,
          project_id INTEGER, model_canonical TEXT NOT NULL,
          tokens_input INTEGER NOT NULL DEFAULT 0, tokens_output INTEGER NOT NULL DEFAULT 0,
          tokens_cache_read INTEGER NOT NULL DEFAULT 0,
          tokens_cache_write_5m INTEGER NOT NULL DEFAULT 0, tokens_cache_write_1h INTEGER NOT NULL DEFAULT 0,
          cost_usd_micros INTEGER, cost_unknown_events INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE agent_sessions (
          id INTEGER PRIMARY KEY, source_kind TEXT NOT NULL, source_session_key TEXT NOT NULL,
          provider_id TEXT, status TEXT NOT NULL DEFAULT 'active', root_session_key TEXT
        );
        CREATE TABLE session_rollup (
          session_id INTEGER PRIMARY KEY, first_event_epoch_ms INTEGER NOT NULL,
          last_event_epoch_ms INTEGER NOT NULL
        );
        """)
    }

    private func todayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now)
    }

    private func seedDaily(_ provider: String, tokens: Int64, cost: Int64, unknown: Int64 = 0, date: String? = nil, model: String = "m") throws {
        try database.execute(
            "INSERT INTO daily_rollup(usage_date, provider_id, source_kind, model_canonical, tokens_input, cost_usd_micros, cost_unknown_events) VALUES (?,?,?,?,?,?,?)",
            [.text(date ?? todayString()), .text(provider), .text("k"), .text(model), .int(tokens), .int(cost), .int(unknown)]
        )
    }

    private func seedSession(_ id: Int64, provider: String, lastEventMs: Int64, root: String? = nil) throws {
        try database.execute(
            "INSERT INTO agent_sessions(id, source_kind, source_session_key, provider_id, root_session_key) VALUES (?,?,?,?,?)",
            [.int(id), .text("k"), .text("s\(id)"), .text(provider), root.map { .text($0) } ?? .null]
        )
        try database.execute(
            "INSERT INTO session_rollup(session_id, first_event_epoch_ms, last_event_epoch_ms) VALUES (?,?,?)",
            [.int(id), .int(lastEventMs - 60_000), .int(lastEventMs)]
        )
    }

    func testAggregatesTodayPerProviderAndSkipsOtherDays() throws {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        try seedDaily("claude-code", tokens: 100, cost: 5000, unknown: 2)
        try seedDaily("codex", tokens: 40, cost: 2000)
        try seedDaily("claude-code", tokens: 999, cost: 9999, date: "2000-01-01")   // 非今日不计
        try seedSession(1, provider: "claude-code", lastEventMs: nowMs)
        try seedSession(2, provider: "claude-code", lastEventMs: nowMs, root: "s1")  // 子会话不计
        try seedSession(3, provider: "codex", lastEventMs: 1)                        // 今日之前不计

        let summary = MenuBarTodaySummaryRepository.load(from: database, now: now)

        XCTAssertEqual(summary.tokens, 140)
        XCTAssertEqual(summary.costUsdMicros, 7000)
        XCTAssertEqual(summary.unknownEvents, 2)
        XCTAssertEqual(summary.sessions, 1)
        XCTAssertEqual(summary.perProvider.map(\.providerId), ["claude-code", "codex"])   // tokens 降序
        XCTAssertEqual(summary.perProvider[0].sessions, 1)
        XCTAssertEqual(summary.perProvider[1].sessions, 0)
    }

    func testAggregatesTodayPerModelSortedByTokens() throws {
        // 口径与 Electron 热力图日详情（dayModelBreakdown）一致：
        // 今日、按 model_canonical 聚合（跨 provider 合并）、tokens 降序。
        try seedDaily("claude-code", tokens: 100, cost: 5000, model: "claude-sonnet-5")
        try seedDaily("codex", tokens: 300, cost: 9000, model: "gpt-5.6-sol")
        try seedDaily("claude-code", tokens: 50, cost: 100, model: "gpt-5.6-sol")
        try seedDaily("claude-code", tokens: 999, cost: 9, date: "2000-01-01", model: "stale")   // 非今日不计

        let summary = MenuBarTodaySummaryRepository.load(from: database, now: now)

        XCTAssertEqual(summary.perModel.map(\.model), ["gpt-5.6-sol", "claude-sonnet-5"])
        XCTAssertEqual(summary.perModel[0].tokens, 350)
        XCTAssertEqual(summary.perModel[0].costUsdMicros, 9100)
        XCTAssertEqual(summary.perModel[1].tokens, 100)
        XCTAssertEqual(summary.perModel[1].costUsdMicros, 5000)
    }

    func testReturnsEmptyWhenTablesAreMissing() throws {
        let bare = try SQLiteDatabase(path: ":memory:")
        XCTAssertEqual(MenuBarTodaySummaryRepository.load(from: bare, now: now), .empty)
    }
}
