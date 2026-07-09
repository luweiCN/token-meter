import XCTest
@testable import TokenMeterCore

final class UsageEventWriterTests: XCTestCase {
    private func makeDatabase() throws -> SQLiteDatabase {
        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)
        try database.execute(
            "INSERT INTO scan_roots(id, kind, root_path, display_name, stable_source_key) VALUES (1, 'claude_jsonl', '/tmp/c', 'C', 'c')"
        )
        try database.execute(
            """
            INSERT INTO source_files(id, scan_root_id, relative_path, canonical_path, file_type, size_bytes, mtime_ns)
            VALUES (1, 1, 'a.jsonl', '/tmp/c/a.jsonl', 'jsonl_session', 1, 1),
                   (2, 1, 'subagents/b.jsonl', '/tmp/c/subagents/b.jsonl', 'jsonl_session', 1, 1)
            """
        )
        return database
    }

    private func calculator() -> CostCalculator {
        CostCalculator(snapshot: PricingSnapshot(
            snapshotVersion: "test",
            source: "litellm",
            models: ["claude-fable-5": ModelPricing(
                inputPerMTok: 10, outputPerMTok: 100, cacheReadPerMTok: 1,
                cacheWrite5mPerMTok: 12.5, cacheWrite1hPerMTok: 20
            )]
        ))
    }

    private func session(_ events: [UsageEvent]) -> ParsedSession {
        ParsedSession(
            sourceKind: .claudeJSONL,
            sessionKey: "s1",
            projectPath: "/repo",
            cliVersion: "1.0",
            startedAt: events.first?.observedAt,
            updatedAt: events.last?.observedAt,
            events: events,
            rawMeta: ["source": "claude-code"]
        )
    }

    private func event(seq: Int, at seconds: TimeInterval, input: Int64 = 1_000_000, model: String? = "claude-fable-5") -> UsageEvent {
        UsageEvent(
            eventSeq: seq,
            observedAt: Date(timeIntervalSince1970: seconds),
            modelName: model,
            dedupeKey: nil,
            inputTokens: input,
            sourceOffset: Int64(seq * 100)
        )
    }

    func testWritesOneRowPerEventAndComputesCost() throws {
        let database = try makeDatabase()
        let writer = UsageEventWriter(database: database, costCalculator: calculator())

        try writer.write(session([1, 2].map { event(seq: $0, at: TimeInterval($0)) }), scanRootId: 1, sourceFileId: 1, runId: nil)

        let rows = try database.query("SELECT event_seq, cost_usd_micros, cost_source, model_canonical FROM usage_events ORDER BY event_seq")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].int("cost_usd_micros"), 10_000_000)
        XCTAssertEqual(rows[0].string("cost_source"), "computed")
        XCTAssertEqual(rows[0].string("model_canonical"), "claude-fable-5")
    }

    func testUnknownModelStoresNullCostNotZero() throws {
        let database = try makeDatabase()
        let writer = UsageEventWriter(database: database, costCalculator: calculator())

        try writer.write(session([event(seq: 1, at: 1, model: "totally-unlisted")]), scanRootId: 1, sourceFileId: 1, runId: nil)

        let rows = try database.query("SELECT cost_usd_micros, cost_source FROM usage_events")
        XCTAssertNil(rows[0].int("cost_usd_micros"), "未知定价必须存 NULL，0 会看起来像「免费」")
        XCTAssertEqual(rows[0].string("cost_source"), "unknown")
    }

    func testSameSessionAcrossTwoSourceFilesKeepsBothEventSeqNamespaces() throws {
        let database = try makeDatabase()
        let writer = UsageEventWriter(database: database, costCalculator: calculator())

        // Claude 的 subagent 文件与父文件共享 sessionId，event_seq 各自从 1 开始
        try writer.write(session([event(seq: 1, at: 1)]), scanRootId: 1, sourceFileId: 1, runId: nil)
        try writer.write(session([event(seq: 1, at: 2)]), scanRootId: 1, sourceFileId: 2, runId: nil)

        XCTAssertEqual(try database.query("SELECT count(*) AS n FROM usage_events")[0].int("n"), 2,
                       "唯一约束是 UNIQUE(source_file_id, event_seq)，不是 UNIQUE(session_id, event_seq)")
        XCTAssertEqual(try database.query("SELECT count(*) AS n FROM agent_sessions")[0].int("n"), 1)
    }

    func testDedupeKeyCollisionKeepsEarliestObservedAt() throws {
        let database = try makeDatabase()
        let writer = UsageEventWriter(database: database, costCalculator: calculator())

        let later = UsageEvent(eventSeq: 1, observedAt: Date(timeIntervalSince1970: 200), modelName: "claude-fable-5",
                               messageId: "m1", dedupeKey: "m1\u{1F}r1", inputTokens: 1, sourceOffset: 10)
        let earlier = UsageEvent(eventSeq: 1, observedAt: Date(timeIntervalSince1970: 100), modelName: "claude-fable-5",
                                 messageId: "m1", dedupeKey: "m1\u{1F}r1", inputTokens: 1, sourceOffset: 20)

        // 先写晚的，再写早的。INSERT OR IGNORE 会保留先写入的那条，那是错的。
        try writer.write(session([later]), scanRootId: 1, sourceFileId: 1, runId: nil)
        try writer.write(session([earlier]), scanRootId: 1, sourceFileId: 2, runId: nil)

        let rows = try database.query("SELECT observed_epoch_ms FROM usage_events")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].int("observed_epoch_ms"), 100_000)
    }

    func testDedupeKeyCollisionKeepsExistingWhenNewIsLater() throws {
        let database = try makeDatabase()
        let writer = UsageEventWriter(database: database, costCalculator: calculator())

        let earlier = UsageEvent(eventSeq: 1, observedAt: Date(timeIntervalSince1970: 100), modelName: "claude-fable-5",
                                 messageId: "m1", dedupeKey: "m1\u{1F}r1", inputTokens: 1, sourceOffset: 10)
        let later = UsageEvent(eventSeq: 1, observedAt: Date(timeIntervalSince1970: 200), modelName: "claude-fable-5",
                               messageId: "m1", dedupeKey: "m1\u{1F}r1", inputTokens: 1, sourceOffset: 20)

        try writer.write(session([earlier]), scanRootId: 1, sourceFileId: 1, runId: nil)
        try writer.write(session([later]), scanRootId: 1, sourceFileId: 2, runId: nil)

        let rows = try database.query("SELECT observed_epoch_ms FROM usage_events")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].int("observed_epoch_ms"), 100_000, "已存在的更早记录不得被覆盖")
    }

    func testDedupeKeyCollisionBreaksFullTieByLowestEventSeq() throws {
        // 总量并列、观测时间并列，只 eventSeq 不同：全靠比较器的第三级决胜（更小 seq 胜）。
        // 先写大 seq 的那条，再写小 seq 的候选——候选必须替换掉它，留下 event_seq=2。
        // 删掉第三级后候选会因「并列不胜」被丢弃，先写入的 seq=5 留下，本断言变红。
        let database = try makeDatabase()
        let writer = UsageEventWriter(database: database, costCalculator: calculator())

        let highSeq = UsageEvent(eventSeq: 5, observedAt: Date(timeIntervalSince1970: 100), modelName: "claude-fable-5",
                                 messageId: "m1", dedupeKey: "m1", inputTokens: 1, sourceOffset: 10)
        let lowSeq = UsageEvent(eventSeq: 2, observedAt: Date(timeIntervalSince1970: 100), modelName: "claude-fable-5",
                                messageId: "m1", dedupeKey: "m1", inputTokens: 1, sourceOffset: 20)

        try writer.write(session([highSeq]), scanRootId: 1, sourceFileId: 1, runId: nil)
        try writer.write(session([lowSeq]), scanRootId: 1, sourceFileId: 2, runId: nil)

        let rows = try database.query("SELECT event_seq FROM usage_events")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].int("event_seq"), 2, "总量与时间都并列时，更小 eventSeq 的候选必须胜出")
    }

    func testDedupeKeyCollisionKeepsLargerTokensTotalRegardlessOfObservedAt() throws {
        // 比较器第一级（tokensTotal 最大者胜）在 writer 对已落库行的去重上也必须生效：
        // 先落库一条更晚但 token 更大的最终帧，再来一条更早但 token 更小的中间帧——
        // 尽管候选更早，也绝不能因「保留最早」而顶掉更完整的最终帧。
        let database = try makeDatabase()
        let writer = UsageEventWriter(database: database, costCalculator: calculator())

        let finalFrame = UsageEvent(eventSeq: 1, observedAt: Date(timeIntervalSince1970: 200), modelName: "claude-fable-5",
                                    messageId: "m1", dedupeKey: "m1", inputTokens: 1, outputTokens: 559, sourceOffset: 10)
        let earlierPartial = UsageEvent(eventSeq: 1, observedAt: Date(timeIntervalSince1970: 100), modelName: "claude-fable-5",
                                        messageId: "m1", dedupeKey: "m1", inputTokens: 1, outputTokens: 4, sourceOffset: 20)

        try writer.write(session([finalFrame]), scanRootId: 1, sourceFileId: 1, runId: nil)
        try writer.write(session([earlierPartial]), scanRootId: 1, sourceFileId: 2, runId: nil)

        let rows = try database.query("SELECT tokens_output FROM usage_events")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].int("tokens_output"), 559, "更完整（tokensTotal 更大）的帧必须留下，即便它观测时间更晚")
    }

    func testResumeOffsetIsPerSourceFile() throws {
        let database = try makeDatabase()
        let writer = UsageEventWriter(database: database, costCalculator: calculator())

        try writer.write(session([event(seq: 1, at: 1)]), scanRootId: 1, sourceFileId: 1, runId: nil)   // offset 100
        try writer.write(session([event(seq: 3, at: 3)]), scanRootId: 1, sourceFileId: 2, runId: nil)   // offset 300

        XCTAssertEqual(try writer.lastSourceOffset(sourceFileId: 1), 100)
        XCTAssertEqual(try writer.lastSourceOffset(sourceFileId: 2), 300)
        XCTAssertNil(try writer.lastSourceOffset(sourceFileId: 99))
    }

    func testRewritingTheSameFileIsIdempotent() throws {
        let database = try makeDatabase()
        let writer = UsageEventWriter(database: database, costCalculator: calculator())
        let parsed = session([1, 2].map { event(seq: $0, at: TimeInterval($0)) })

        try writer.write(parsed, scanRootId: 1, sourceFileId: 1, runId: nil)
        try writer.write(parsed, scanRootId: 1, sourceFileId: 1, runId: nil)

        XCTAssertEqual(try database.query("SELECT count(*) AS n FROM usage_events")[0].int("n"), 2)
        XCTAssertEqual(try database.query("SELECT count(*) AS n FROM agent_sessions")[0].int("n"), 1)
    }

    func testCreatesProjectFromPath() throws {
        let database = try makeDatabase()
        let writer = UsageEventWriter(database: database, costCalculator: calculator())

        try writer.write(session([event(seq: 1, at: 1)]), scanRootId: 1, sourceFileId: 1, runId: nil)

        let projects = try database.query("SELECT project_key, display_name FROM projects")
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0].string("project_key"), "/repo")
        XCTAssertEqual(projects[0].string("display_name"), "repo")

        let sessionRow = try database.query("SELECT project_id FROM agent_sessions")[0]
        XCTAssertNotNil(sessionRow.int("project_id"))
    }
}
