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
          cost_usd_micros INTEGER, cost_unknown_events INTEGER NOT NULL DEFAULT 0,
          token_unreported_events INTEGER NOT NULL DEFAULT 0,
          credits_picos INTEGER NOT NULL DEFAULT 0,
          credit_events INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE agent_sessions (
          id INTEGER PRIMARY KEY, source_kind TEXT NOT NULL, source_session_key TEXT NOT NULL,
          provider_id TEXT, status TEXT NOT NULL DEFAULT 'active', root_session_key TEXT, scan_root_id INTEGER
        );
        CREATE TABLE scan_roots (id INTEGER PRIMARY KEY, root_path TEXT NOT NULL);
        CREATE TABLE usage_events (session_id INTEGER, observed_epoch_ms INTEGER);
        CREATE TABLE daily_active_sessions (
          usage_date TEXT, provider_id TEXT, root_session_key TEXT, sessions_count INTEGER,
          PRIMARY KEY (usage_date, provider_id, root_session_key)
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

    private func seedSession(_ id: Int64, provider: String, lastEventMs: Int64, root: String? = nil,
                             key: String? = nil, scanRoot: Int64 = 1) throws {
        let rawKey = key ?? "s\(id)"
        try database.execute(
            "INSERT INTO agent_sessions(id, source_kind, source_session_key, provider_id, root_session_key, scan_root_id) VALUES (?,?,?,?,?,?)",
            [.int(id), .text("k"), .text(rawKey), .text(provider), root.map { .text($0) } ?? .null, .int(scanRoot)]
        )
        try database.execute("INSERT INTO usage_events VALUES (?,?)", [.int(id), .int(lastEventMs)])
        try database.execute(
            """
            INSERT INTO daily_active_sessions VALUES (date(? / 1000, 'unixepoch', 'localtime'),?,?,1)
            ON CONFLICT(usage_date, provider_id, root_session_key) DO UPDATE SET sessions_count=sessions_count+1
            """,
            [.int(lastEventMs), .text(provider), .text("k:" + (root ?? rawKey))]
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
        XCTAssertTrue(summary.sessionCountIsComplete)
    }

    func testOneActiveConversationWhenOnlyItsChildrenRunToday() throws {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        try seedDaily("codex", tokens: 200, cost: 15)
        try seedSession(1, provider: "codex", lastEventMs: 1)
        try seedSession(2, provider: "codex", lastEventMs: nowMs, root: "s1")
        try seedSession(3, provider: "codex", lastEventMs: nowMs, root: "s1")
        let summary = MenuBarTodaySummaryRepository.load(from: database, now: now)
        XCTAssertEqual(summary.perProvider.first?.knownSessionCount, 1)
        XCTAssertEqual(summary.sessions, 1)
        XCTAssertTrue(summary.sessionCountIsComplete)
    }

    func testAntigravityCountsOnlyVisibleTopLevelConversationsAndRetainsAllUsage() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let parent = UUID().uuidString.lowercased()
        let child = UUID().uuidString.lowercased()
        let helper = UUID().uuidString.lowercased()
        let prior = UUID().uuidString.lowercased()
        let future = UUID().uuidString.lowercased()
        let cache = folder.appendingPathComponent("cache", isDirectory: true)
        let conversations = folder.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: conversations, withIntermediateDirectories: true)
        let cacheFile = cache.appendingPathComponent("conversation_metadata.json")
        let metadata = ["conversations": [parent: ["is_internal": false], child: ["is_internal": false], helper: ["is_internal": true]]]
        try JSONEncoder().encode(metadata).write(to: cacheFile)
        let upstream = try SQLiteDatabase(path: folder.appendingPathComponent("conversation_summaries.db").path)
        try upstream.execute("""
            CREATE TABLE conversation_summaries(conversation_id TEXT, parent_conversation_id TEXT, nesting_depth INTEGER);
            CREATE TABLE conversation_parents(conversation_id TEXT, parent_id TEXT);
            """)
        try upstream.execute("INSERT INTO conversation_summaries VALUES (?, '', 0), (?, ?, 1)", [.text(parent), .text(child), .text(parent)])
        try upstream.execute("INSERT INTO conversation_parents VALUES (?,?)", [.text(child), .text(parent)])
        try upstream.close()
        try database.execute("INSERT INTO scan_roots VALUES (1, ?)", [.text(conversations.path)])
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let agent = SourceKind.antigravitySQLite.defaultProviderId
        try seedDaily(agent, tokens: 500, cost: 700)
        try seedDaily("codex", tokens: 100, cost: 200)
        try seedSession(1, provider: agent, lastEventMs: nowMs, key: parent)
        try seedSession(2, provider: agent, lastEventMs: nowMs, key: child)
        try seedSession(3, provider: agent, lastEventMs: nowMs, key: helper)
        try seedSession(4, provider: agent, lastEventMs: 1, key: prior)
        try seedSession(5, provider: agent, lastEventMs: nowMs + 2 * 86_400_000, key: future)
        try seedSession(6, provider: "codex", lastEventMs: nowMs)
        try database.execute("INSERT INTO usage_events VALUES (1,?)", [.int(nowMs + 1)])

        var summary = MenuBarTodaySummaryRepository.load(from: database, now: now)
        XCTAssertEqual(summary.perProvider.first?.knownSessionCount, 1)
        XCTAssertTrue(summary.sessionCountIsComplete)
        XCTAssertEqual(summary.sessions, 2)
        XCTAssertEqual(summary.tokens, 600)
        XCTAssertEqual(summary.costUsdMicros, 900)

        // A second active source with unavailable metadata does not erase
        // known spend or turn its missing session count into a displayed zero.
        try seedSession(7, provider: agent, lastEventMs: nowMs, key: UUID().uuidString.lowercased(), scanRoot: 99)
        summary = MenuBarTodaySummaryRepository.load(from: database, now: now)
        XCTAssertNil(summary.perProvider.first?.knownSessionCount)
        XCTAssertFalse(summary.sessionCountIsComplete)
        XCTAssertEqual(summary.perProvider.last?.knownSessionCount, 1)
        XCTAssertEqual(summary.tokens, 600)
        XCTAssertEqual(summary.costUsdMicros, 900)

        try database.execute("UPDATE agent_sessions SET status='deleted' WHERE id IN (1,2,7)")
        summary = MenuBarTodaySummaryRepository.load(from: database, now: now)
        XCTAssertEqual(summary.perProvider.first?.knownSessionCount, 0)
        XCTAssertTrue(summary.sessionCountIsComplete)
        XCTAssertEqual(summary.sessions, 1)
        XCTAssertEqual(summary.perProvider.first?.tokens, 500)
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
