import XCTest
@testable import TokenMeterCore

final class OpenCodeUsageEventAdapterTests: XCTestCase {
    private func makeDatabase() throws -> SQLiteDatabase {
        let database = try SQLiteDatabase(path: ":memory:")
        try database.execute(
            """
            CREATE TABLE message (
              id TEXT PRIMARY KEY,
              session_id TEXT NOT NULL,
              time_created INTEGER NOT NULL,
              time_updated INTEGER NOT NULL,
              data TEXT NOT NULL
            )
            """
        )
        return database
    }

    private func insert(_ database: SQLiteDatabase, id: String, sessionId: String, createdMs: Int64, data: String) throws {
        try database.execute(
            "INSERT INTO message(id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?)",
            [.text(id), .text(sessionId), .int(createdMs), .int(createdMs), .text(data)]
        )
    }

    func testEmitsOneEventPerMessageInsteadOfMerging() throws {
        let database = try makeDatabase()
        try insert(database, id: "m1", sessionId: "s1", createdMs: 1_000,
            data: #"{"id":"m1","sessionID":"s1","role":"assistant","modelID":"glm-4.6","providerID":"zhipuai-coding-plan","cost":0,"time":{"created":1000},"tokens":{"input":100,"output":10,"reasoning":0,"cache":{"read":900,"write":0}}}"#)
        try insert(database, id: "m2", sessionId: "s1", createdMs: 2_000,
            data: #"{"id":"m2","sessionID":"s1","role":"assistant","modelID":"glm-4.6","cost":0.5,"time":{"created":2000},"tokens":{"input":200,"output":20,"reasoning":5,"cache":{"read":0,"write":300}}}"#)

        let sessions = try OpenCodeUsageEventAdapter(sourceDatabase: database).changedSessions(after: nil)

        XCTAssertEqual(sessions.count, 1)
        let session = sessions[0]
        XCTAssertEqual(session.sessionKey, "s1")
        XCTAssertEqual(session.events.count, 2, "两条消息必须是两个事件，不能合并成一条")

        XCTAssertEqual(session.events[0].inputTokens, 100, "cache 独立于 input，不做减法")
        XCTAssertEqual(session.events[0].cacheReadTokens, 900)
        XCTAssertEqual(session.events[0].totalTokens, 1010)
        XCTAssertEqual(session.events[0].eventSeq, 1)

        XCTAssertEqual(session.events[1].cacheWrite5mTokens, 300)
        XCTAssertEqual(session.events[1].reasoningTokens, 5)
        // OpenCode 的 output 不含 reasoning，adapter 归一：outputTokens = 20 + 5 = 25。
        // totalTokens = input(200) + output(25) + cacheWrite(300) = 525。
        XCTAssertEqual(session.events[1].outputTokens, 25)
        XCTAssertEqual(session.events[1].totalTokens, 525)
        XCTAssertEqual(session.events[1].eventSeq, 2)
    }

    func testOutputIncludesReasoningWhenReasoningExceedsOutput() throws {
        // 实测 OpenCode 有 716 条 output < reasoning（如 output=53, reasoning=226, glm-5.1）：
        // 子集不可能大于超集，故 OpenCode 的 output **不含** reasoning，违反 spec §4.3.1。
        // adapter 必须在边界处归一：outputTokens = output + reasoning，reasoning 仅留作展示子集。
        let database = try makeDatabase()
        try insert(database, id: "m1", sessionId: "s1", createdMs: 1_000,
            data: #"{"id":"m1","sessionID":"s1","role":"assistant","modelID":"glm-5.1","cost":0,"time":{"created":1000},"tokens":{"input":100,"output":53,"reasoning":226,"cache":{"read":0,"write":0}}}"#)

        let sessions = try OpenCodeUsageEventAdapter(sourceDatabase: database).changedSessions(after: nil)
        let event = sessions[0].events[0]

        XCTAssertEqual(event.outputTokens, 279, "output(53) + reasoning(226)")
        XCTAssertEqual(event.reasoningTokens, 226, "reasoning 仍作信息性子集保留")
        // totalTokens = input(100) + output(279) + cacheRead(0) + write(0)
        XCTAssertEqual(event.totalTokens, 379)
    }

    func testReasoningZeroDoesNotInflateOutput() throws {
        // reasoning == 0：归一是加法，加 0 不改变 output，绝不重复计数。
        let database = try makeDatabase()
        try insert(database, id: "m1", sessionId: "s1", createdMs: 1_000,
            data: #"{"id":"m1","sessionID":"s1","role":"assistant","modelID":"glm-4.6","cost":0,"time":{"created":1000},"tokens":{"input":100,"output":40,"reasoning":0,"cache":{"read":0,"write":0}}}"#)

        let sessions = try OpenCodeUsageEventAdapter(sourceDatabase: database).changedSessions(after: nil)
        let event = sessions[0].events[0]

        XCTAssertEqual(event.outputTokens, 40)
        XCTAssertEqual(event.reasoningTokens, 0)
        XCTAssertEqual(event.totalTokens, 140)
    }

    func testZeroCostFallsThroughToComputed() throws {
        let database = try makeDatabase()
        try insert(database, id: "m1", sessionId: "s1", createdMs: 1_000,
            data: #"{"id":"m1","sessionID":"s1","role":"assistant","modelID":"glm-4.6","cost":0,"time":{"created":1000},"tokens":{"input":100,"output":10,"cache":{"read":0,"write":0}}}"#)

        let sessions = try OpenCodeUsageEventAdapter(sourceDatabase: database).changedSessions(after: nil)

        // 套餐制下 OpenCode 报 0，那是「不知道单价」，不是「免费」
        XCTAssertNil(sessions[0].events[0].reportedCostUSDMicros)
    }

    func testPositiveCostIsReported() throws {
        let database = try makeDatabase()
        try insert(database, id: "m1", sessionId: "s1", createdMs: 1_000,
            data: #"{"id":"m1","sessionID":"s1","role":"assistant","modelID":"glm-4.6","cost":0.25,"time":{"created":1000},"tokens":{"input":100,"output":10,"cache":{"read":0,"write":0}}}"#)

        let sessions = try OpenCodeUsageEventAdapter(sourceDatabase: database).changedSessions(after: nil)

        XCTAssertEqual(sessions[0].events[0].reportedCostUSDMicros, 250_000)
    }

    func testEventTimestampsComeFromMessageCreatedTime() throws {
        let database = try makeDatabase()
        try insert(database, id: "m1", sessionId: "s1", createdMs: 1_765_980_154_045,
            data: #"{"id":"m1","sessionID":"s1","role":"assistant","modelID":"glm-4.6","cost":0,"time":{"created":1765980154045},"tokens":{"input":1,"output":1,"cache":{"read":0,"write":0}}}"#)

        let sessions = try OpenCodeUsageEventAdapter(sourceDatabase: database).changedSessions(after: nil)

        XCTAssertEqual(sessions[0].events[0].observedEpochMilliseconds, 1_765_980_154_045)
    }

    func testSkipsMessagesWithoutTokens() throws {
        let database = try makeDatabase()
        try insert(database, id: "m1", sessionId: "s1", createdMs: 1_000,
            data: #"{"id":"m1","sessionID":"s1","role":"user","time":{"created":1000}}"#)

        let sessions = try OpenCodeUsageEventAdapter(sourceDatabase: database).changedSessions(after: nil)

        XCTAssertTrue(sessions.isEmpty)
    }

    func testV1RowWithoutAssistantRoleIsNotCounted() throws {
        let database = try makeDatabase()
        try insert(database, id: "m1", sessionId: "s1", createdMs: 1_000,
            data: #"{"id":"m1","sessionID":"s1","modelID":"m","time":{"created":1000},"tokens":{"input":10,"output":2,"cache":{"read":0,"write":0}}}"#)

        let sessions = try OpenCodeUsageEventAdapter(sourceDatabase: database).changedSessions(after: nil)

        XCTAssertTrue(sessions.isEmpty, "v1 必须由 JSON role 明确认定 assistant；缺 role 不能猜测")
    }

    func testEventsAreOrderedByCreationTimeWithinASession() throws {
        let database = try makeDatabase()
        // 插入顺序与时间顺序相反
        try insert(database, id: "mB", sessionId: "s1", createdMs: 2_000,
            data: #"{"id":"mB","sessionID":"s1","role":"assistant","modelID":"m","cost":0,"time":{"created":2000},"tokens":{"input":2,"output":0,"cache":{"read":0,"write":0}}}"#)
        try insert(database, id: "mA", sessionId: "s1", createdMs: 1_000,
            data: #"{"id":"mA","sessionID":"s1","role":"assistant","modelID":"m","cost":0,"time":{"created":1000},"tokens":{"input":1,"output":0,"cache":{"read":0,"write":0}}}"#)

        let sessions = try OpenCodeUsageEventAdapter(sourceDatabase: database).changedSessions(after: nil)

        XCTAssertEqual(sessions[0].events.map(\.eventSeq), [1, 2])
        XCTAssertEqual(sessions[0].events[0].inputTokens, 1, "eventSeq 必须按 time.created 排序")
        XCTAssertEqual(sessions[0].events[1].inputTokens, 2)
    }

    func testSeparatesSessions() throws {
        let database = try makeDatabase()
        try insert(database, id: "m1", sessionId: "s1", createdMs: 1_000,
            data: #"{"id":"m1","sessionID":"s1","role":"assistant","modelID":"m","cost":0,"time":{"created":1000},"tokens":{"input":1,"output":0,"cache":{"read":0,"write":0}}}"#)
        try insert(database, id: "m2", sessionId: "s2", createdMs: 2_000,
            data: #"{"id":"m2","sessionID":"s2","role":"assistant","modelID":"m","cost":0,"time":{"created":2000},"tokens":{"input":1,"output":0,"cache":{"read":0,"write":0}}}"#)

        let sessions = try OpenCodeUsageEventAdapter(sourceDatabase: database).changedSessions(after: nil)

        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.map(\.sessionKey).sorted(), ["s1", "s2"])
        // 每个 session 的 eventSeq 各自从 1 开始
        XCTAssertEqual(sessions[0].events[0].eventSeq, 1)
        XCTAssertEqual(sessions[1].events[0].eventSeq, 1)
    }

    func testAttributesSubSessionToParentViaParentId() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try database.execute(
            """
            CREATE TABLE session (
              id TEXT PRIMARY KEY,
              parent_id TEXT,
              directory TEXT,
              agent TEXT
            )
            """
        )
        try database.execute(
            """
            CREATE TABLE message (
              id TEXT PRIMARY KEY,
              session_id TEXT NOT NULL,
              time_created INTEGER NOT NULL,
              time_updated INTEGER NOT NULL,
              data TEXT NOT NULL
            )
            """
        )
        try database.execute(
            "INSERT INTO session(id, parent_id, directory, agent) VALUES (?, ?, ?, ?)",
            [.text("main-1"), .null, .text("/repo"), .null]
        )
        try database.execute(
            "INSERT INTO session(id, parent_id, directory, agent) VALUES (?, ?, ?, ?)",
            [.text("sub-1"), .text("main-1"), .text("/repo"), .text("reviewer")]
        )
        try insert(database, id: "m1", sessionId: "main-1", createdMs: 1_000,
            data: #"{"id":"m1","sessionID":"main-1","role":"assistant","tokens":{"input":100,"output":10}}"#)
        try insert(database, id: "m2", sessionId: "sub-1", createdMs: 2_000,
            data: #"{"id":"m2","sessionID":"sub-1","role":"assistant","tokens":{"input":50,"output":5}}"#)

        let sessions = try OpenCodeUsageEventAdapter(sourceDatabase: database).changedSessions(after: nil)
        let sub = try XCTUnwrap(sessions.first(where: { $0.sessionKey == "sub-1" }))
        let main = try XCTUnwrap(sessions.first(where: { $0.sessionKey == "main-1" }))

        XCTAssertEqual(sub.rootSessionKey, "main-1")
        XCTAssertEqual(sub.subagentLabel, "reviewer")
        XCTAssertNil(main.rootSessionKey, "主会话不应有 root")
        XCTAssertNil(main.subagentLabel)
    }

    func testDeduplicatesForkedHistoryByStableFingerprint() throws {
        let database = try makeDatabase()
        try database.execute("CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT, agent TEXT)")
        try database.execute("INSERT INTO session(id, parent_id, directory) VALUES ('root', NULL, '/repo'), ('fork', 'root', '/repo')")
        let copied = #"{"role":"assistant","modelID":"gpt-5.5","providerID":"openai","cost":0.25,"time":{"created":1000,"completed":1100},"tokens":{"input":100,"output":10,"reasoning":2,"cache":{"read":50,"write":0}}}"#
        try insert(database, id: "root-row", sessionId: "root", createdMs: 1_000, data: copied)
        try insert(database, id: "fork-copy-row", sessionId: "fork", createdMs: 1_000, data: copied)
        try insert(database, id: "fork-new-row", sessionId: "fork", createdMs: 2_000,
            data: #"{"role":"assistant","modelID":"gpt-5.5","providerID":"openai","time":{"created":2000},"tokens":{"input":20,"output":3,"reasoning":0,"cache":{"read":0,"write":0}}}"#)

        let sessions = try OpenCodeUsageEventAdapter(sourceDatabase: database).changedSessions(after: nil)
        let events = sessions.flatMap(\.events)

        XCTAssertEqual(events.count, 2, "fork 复制的 root 历史只能计一次")
        XCTAssertEqual(events.reduce(Int64(0)) { $0 + $1.totalTokens }, 185)
        let copiedEvent = try XCTUnwrap(events.first { $0.observedEpochMilliseconds == 1_000 })
        XCTAssertEqual(copiedEvent.dedupeScopeKey, "opencode")
        XCTAssertNotNil(copiedEvent.dedupeKey)
    }

    func testDeduplicatesCopiedMessageWhenParentSessionMetadataIsMissing() throws {
        let database = try makeDatabase()
        let copied = #"{"id":"original-message","role":"assistant","modelID":"gpt-5.5","providerID":"openai","time":{"created":1000},"tokens":{"input":100,"output":10,"reasoning":0,"cache":{"read":50,"write":0}}}"#
        try insert(database, id: "first-row", sessionId: "first-session", createdMs: 1_000, data: copied)
        try insert(database, id: "copied-row", sessionId: "detached-fork", createdMs: 1_000, data: copied)

        let events = try OpenCodeUsageEventAdapter(sourceDatabase: database).changedSessions(after: nil).flatMap(\.events)

        XCTAssertEqual(events.count, 1, "复制消息即使缺 parent_id，也应凭相同 embedded id 与指纹全局折叠")
    }

    func testKeepsDistinctEmbeddedMessageIDsWithIdenticalFingerprint() throws {
        let database = try makeDatabase()
        let first = #"{"id":"message-a","role":"assistant","modelID":"gpt-5.5","providerID":"openai","time":{"created":1000},"tokens":{"input":100,"output":10,"reasoning":0,"cache":{"read":50,"write":0}}}"#
        let second = #"{"id":"message-b","role":"assistant","modelID":"gpt-5.5","providerID":"openai","time":{"created":1000},"tokens":{"input":100,"output":10,"reasoning":0,"cache":{"read":50,"write":0}}}"#
        try insert(database, id: "first-row", sessionId: "first-session", createdMs: 1_000, data: first)
        try insert(database, id: "second-row", sessionId: "second-session", createdMs: 1_000, data: second)

        let events = try OpenCodeUsageEventAdapter(sourceDatabase: database).changedSessions(after: nil).flatMap(\.events)

        XCTAssertEqual(events.count, 2, "不同 embedded id 是真实不同消息，不能只因计费字段相同而合并")
    }

    func testMissingEmbeddedIDPromotesToFirstConcreteIDBeforeFurtherDeduplication() throws {
        let database = try makeDatabase()
        let noID = #"{"role":"assistant","modelID":"gpt-5.5","providerID":"openai","time":{"created":1000},"tokens":{"input":100,"output":10,"reasoning":0,"cache":{"read":50,"write":0}}}"#
        let messageA = #"{"id":"message-a","role":"assistant","modelID":"gpt-5.5","providerID":"openai","time":{"created":1000},"tokens":{"input":100,"output":10,"reasoning":0,"cache":{"read":50,"write":0}}}"#
        let messageB = #"{"id":"message-b","role":"assistant","modelID":"gpt-5.5","providerID":"openai","time":{"created":1000},"tokens":{"input":100,"output":10,"reasoning":0,"cache":{"read":50,"write":0}}}"#
        try insert(database, id: "a-no-id", sessionId: "s1", createdMs: 1_000, data: noID)
        try insert(database, id: "b-message-a", sessionId: "s1", createdMs: 1_000, data: messageA)
        try insert(database, id: "c-message-b", sessionId: "s1", createdMs: 1_000, data: messageB)

        let events = try OpenCodeUsageEventAdapter(sourceDatabase: database).changedSessions(after: nil).flatMap(\.events)

        XCTAssertEqual(events.count, 2,
                       "无 id 副本应归入首个具体 id；后续不同 id 必须保留为独立消息")
        XCTAssertEqual(Set(events.compactMap(\.messageId)), Set(["message-a", "message-b"]))
    }

    func testIncrementalChangeStillDeduplicatesAgainstOlderParentHistory() throws {
        let database = try makeDatabase()
        try database.execute("CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT, agent TEXT)")
        try database.execute("INSERT INTO session(id, parent_id, directory) VALUES ('root', NULL, '/repo'), ('fork', 'root', '/repo')")
        let copied = #"{"role":"assistant","modelID":"gpt-5.5","providerID":"openai","time":{"created":1000},"tokens":{"input":100,"output":10,"reasoning":0,"cache":{"read":0,"write":0}}}"#
        try insert(database, id: "root-row", sessionId: "root", createdMs: 1_000, data: copied)
        try insert(database, id: "fork-row", sessionId: "fork", createdMs: 2_000, data: copied)

        let sessions = try OpenCodeUsageEventAdapter(sourceDatabase: database).changedSessions(after: "1500")

        XCTAssertEqual(sessions.flatMap(\.events).count, 1)
        XCTAssertEqual(sessions.first?.sessionKey, "root", "增量也必须用全库快照裁决，保留原始父记录")
    }

    func testReadsV2SessionMessageWithNestedModel() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try database.execute("CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT, agent TEXT)")
        try database.execute("INSERT INTO session(id, directory) VALUES ('s1', '/repo')")
        try database.execute(
            "CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)"
        )
        try database.execute(
            "INSERT INTO session_message(id, session_id, type, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?, ?)",
            [.text("row-1"), .text("s1"), .text("assistant"), .int(1_000), .int(1_100),
             .text(#"{"model":{"id":"glm-5.2","providerID":"zhipuai-coding-plan"},"cost":0,"time":{"created":1000},"tokens":{"input":10,"output":3,"reasoning":2,"cache":{"read":7,"write":1}}}"#)]
        )

        let sessions = try OpenCodeUsageEventAdapter(sourceDatabase: database).changedSessions(after: nil)
        let event = try XCTUnwrap(sessions.first?.events.first)

        XCTAssertEqual(event.modelName, "glm-5.2")
        XCTAssertEqual(event.totalTokens, 23)
    }

    func testFlattensNestedParentAttributionToUltimateRoot() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try database.execute("CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT, agent TEXT)")
        try database.execute("INSERT INTO session(id, parent_id, directory, agent) VALUES ('root', NULL, '/repo', NULL), ('child', 'root', '/repo', 'worker'), ('grandchild', 'child', '/repo', 'reviewer')")
        try database.execute("CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)")
        try insert(database, id: "m1", sessionId: "grandchild", createdMs: 1_000,
            data: #"{"id":"m1","sessionID":"grandchild","role":"assistant","modelID":"m","time":{"created":1000},"tokens":{"input":1,"output":0,"cache":{"read":0,"write":0}}}"#)

        let session = try XCTUnwrap(
            OpenCodeUsageEventAdapter(sourceDatabase: database).changedSessions(after: nil).first
        )

        XCTAssertEqual(session.rootSessionKey, "root")
        XCTAssertEqual(session.subagentLabel, "reviewer")
        XCTAssertTrue(session.events[0].isSidechain)
    }
}
