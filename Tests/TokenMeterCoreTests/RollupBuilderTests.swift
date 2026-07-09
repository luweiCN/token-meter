import XCTest
@testable import TokenMeterCore

final class RollupBuilderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // 不设 TZ 的话，UTC 环境下 UTC 日期与本地日期相同，
        // testUsesLocalDateNotUTCDate 会绿着，而 bug 还在。
        setenv("TZ", "Asia/Shanghai", 1)
        tzset()
    }

    override func tearDown() {
        unsetenv("TZ")
        tzset()
        super.tearDown()
    }

    private func makeDatabase() throws -> SQLiteDatabase {
        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)
        try database.execute("INSERT INTO scan_roots(id, kind, root_path, display_name, stable_source_key) VALUES (1,'claude_jsonl','/tmp/c','C','c')")
        try database.execute("INSERT INTO source_files(id, scan_root_id, relative_path, canonical_path, file_type, size_bytes, mtime_ns) VALUES (1,1,'a.jsonl','/tmp/c/a.jsonl','jsonl_session',1,1)")
        try database.execute("INSERT INTO projects(id, project_key, canonical_path, display_name, first_seen_at, last_seen_at) VALUES (1,'/repo','/repo','repo','x','x')")
        try database.execute("INSERT INTO agent_sessions(id, source_kind, source_session_key, scan_root_id, project_id, provider_id, source_revision) VALUES (1,'claude_jsonl','s1',1,1,'claude-code','r')")
        return database
    }

    private func insertEvent(_ database: SQLiteDatabase, seq: Int, iso: String, model: String, input: Int64, cost: Int64?) throws {
        let ms = Int64(ISO8601DateFormatter().date(from: iso)!.timeIntervalSince1970 * 1000)
        try database.execute(
            """
            INSERT INTO usage_events(session_id, source_file_id, event_seq, observed_epoch_ms, model_canonical,
                                     tokens_input, cost_usd_micros, cost_source, source_offset)
            VALUES (1, 1, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.int(Int64(seq)), .int(ms), .text(model), .int(input),
             cost.map { SQLiteValue.int($0) } ?? .null, .text(cost == nil ? "unknown" : "computed"), .int(Int64(seq))]
        )
    }

    func testSqliteHonoursTheTZEnvironmentVariable() throws {
        // 先证明工具本身能测出这个 bug，否则下面的测试是自欺
        let database = try SQLiteDatabase(path: ":memory:")
        let row = try database.query("SELECT date(1783528200, 'unixepoch', 'localtime') AS d")[0]
        XCTAssertEqual(row.string("d"), "2026-07-09", "setUp 里的 TZ=Asia/Shanghai 没有生效")
    }

    func testUsesLocalDateNotUTCDate() throws {
        let database = try makeDatabase()
        // UTC 2026-07-08T16:30:00Z 在东八区是 2026-07-09 00:30
        try insertEvent(database, seq: 1, iso: "2026-07-08T16:30:00Z", model: "m", input: 10, cost: 100)

        try RollupBuilder(database: database).rebuildAll()

        let rows = try database.query("SELECT usage_date FROM daily_rollup")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].string("usage_date"), "2026-07-09",
                       "旧实现的 substr(observed_at,1,10) 会给出 2026-07-08")
    }

    func testSplitsCrossDaySessionAcrossDays() throws {
        let database = try makeDatabase()
        try insertEvent(database, seq: 1, iso: "2026-07-07T05:00:00Z", model: "m", input: 10, cost: 100)
        try insertEvent(database, seq: 2, iso: "2026-07-08T05:00:00Z", model: "m", input: 20, cost: 200)

        try RollupBuilder(database: database).rebuildAll()

        let rows = try database.query("SELECT usage_date, tokens_input FROM daily_rollup ORDER BY usage_date")
        XCTAssertEqual(rows.count, 2, "跨天会话不能全部记在最后一天")
        XCTAssertEqual(rows[0].int("tokens_input"), 10)
        XCTAssertEqual(rows[1].int("tokens_input"), 20)
    }

    func testSplitsByModelWithinOneDay() throws {
        let database = try makeDatabase()
        try insertEvent(database, seq: 1, iso: "2026-07-08T05:00:00Z", model: "claude-fable-5", input: 10, cost: 100)
        try insertEvent(database, seq: 2, iso: "2026-07-08T06:00:00Z", model: "claude-opus-4-8", input: 20, cost: 200)

        try RollupBuilder(database: database).rebuildAll()

        let rows = try database.query("SELECT model_canonical, tokens_input FROM daily_rollup ORDER BY model_canonical")
        XCTAssertEqual(rows.count, 2, "会话内换模型必须各归各的")
        XCTAssertEqual(rows[0].string("model_canonical"), "claude-fable-5")
        XCTAssertEqual(rows[1].string("model_canonical"), "claude-opus-4-8")
    }

    func testDailyRollupCountsUnknownCostEvents() throws {
        let database = try makeDatabase()
        try insertEvent(database, seq: 1, iso: "2026-07-08T05:00:00Z", model: "m", input: 10, cost: nil)
        try insertEvent(database, seq: 2, iso: "2026-07-08T06:00:00Z", model: "m", input: 20, cost: 200)

        try RollupBuilder(database: database).rebuildAll()

        let row = try database.query("SELECT cost_usd_micros, cost_unknown_events FROM daily_rollup")[0]
        XCTAssertEqual(row.int("cost_usd_micros"), 200, "未知成本按 NULL 处理，不静默累加为 0")
        XCTAssertEqual(row.int("cost_unknown_events"), 1)
    }

    func testBuildsSessionRollupWithPrimaryModel() throws {
        let database = try makeDatabase()
        try insertEvent(database, seq: 1, iso: "2026-07-08T05:00:00Z", model: "claude-fable-5", input: 1000, cost: 100)
        try insertEvent(database, seq: 2, iso: "2026-07-08T06:00:00Z", model: "claude-opus-4-8", input: 10, cost: 200)

        try RollupBuilder(database: database).rebuildAll()

        let row = try database.query("SELECT events_count, tokens_total, cost_usd_micros, primary_model, first_event_epoch_ms, last_event_epoch_ms FROM session_rollup")[0]
        XCTAssertEqual(row.int("events_count"), 2)
        XCTAssertEqual(row.int("tokens_total"), 1010)
        XCTAssertEqual(row.int("cost_usd_micros"), 300)
        XCTAssertEqual(row.string("primary_model"), "claude-fable-5", "token 最多的模型")
        XCTAssertLessThan(row.int("first_event_epoch_ms")!, row.int("last_event_epoch_ms")!)
    }

    func testSessionRollupCountsUnknownCostEvents() throws {
        let database = try makeDatabase()
        // 会话中途换到未定价的模型。sum() 静默跳过 NULL 行，
        // 金额会偏低却看起来精确——这比缺失更有害，UI 必须能察觉。
        try insertEvent(database, seq: 1, iso: "2026-07-08T05:00:00Z", model: "claude-fable-5", input: 1000, cost: 100)
        try insertEvent(database, seq: 2, iso: "2026-07-08T06:00:00Z", model: "unlisted-model", input: 500, cost: nil)

        try RollupBuilder(database: database).rebuildAll()

        let row = try database.query("SELECT cost_usd_micros, cost_unknown_events FROM session_rollup")[0]
        XCTAssertEqual(row.int("cost_usd_micros"), 100, "只累加已知成本")
        XCTAssertEqual(row.int("cost_unknown_events"), 1, "但必须记下有 1 条未计入")
    }

    func testRebuildIsIdempotent() throws {
        let database = try makeDatabase()
        try insertEvent(database, seq: 1, iso: "2026-07-08T05:00:00Z", model: "m", input: 10, cost: 100)

        let builder = RollupBuilder(database: database)
        try builder.rebuildAll()
        try builder.rebuildAll()

        XCTAssertEqual(try database.query("SELECT count(*) AS n FROM daily_rollup")[0].int("n"), 1)
        XCTAssertEqual(try database.query("SELECT count(*) AS n FROM session_rollup")[0].int("n"), 1)
    }

    func testExcludesDeletedSessions() throws {
        let database = try makeDatabase()
        try insertEvent(database, seq: 1, iso: "2026-07-08T05:00:00Z", model: "m", input: 10, cost: 100)
        try database.execute("UPDATE agent_sessions SET status = 'deleted' WHERE id = 1")

        try RollupBuilder(database: database).rebuildAll()

        XCTAssertEqual(try database.query("SELECT count(*) AS n FROM daily_rollup")[0].int("n"), 0)
    }
}
