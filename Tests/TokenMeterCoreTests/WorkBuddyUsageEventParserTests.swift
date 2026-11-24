import XCTest
@testable import TokenMeterCore

final class WorkBuddyUsageEventParserTests: XCTestCase {
    private func line(_ text: String, offset: Int64) -> JSONLLine {
        JSONLLine(text: text, offset: offset, nextOffset: offset + Int64(text.utf8.count) + 1)
    }

    func testUsesLatestRequestTokenSnapshotAndDeduplicatesCreditStages() throws {
        let parser = WorkBuddyUsageEventParser(resuming: nil, fallbackCredits: [:])
        parser.consume(line(#"{"sessionId":"wb-session","timestamp":1789898400000,"update":{"id":"stage-a","_meta":{"codebuddy.ai/requestId":"request-1","usage":{"promptTokens":100,"completionTokens":10,"reasoningTokens":4,"promptCacheHitTokens":20}},"providerData":{"responseModelId":"claude-sonnet","rawUsage":{"credit":0.1}},"cost":{"amount":0.1}}}"#, offset: 0))
        // 同一 stage id 重放：Credit 不能再加；Token 用最后一份完整快照。
        parser.consume(line(#"{"sessionId":"wb-session","timestamp":1789898460000,"update":{"id":"stage-a","_meta":{"codebuddy.ai":{"requestId":"request-1"},"usage":{"promptTokens":120,"completionTokens":15,"reasoningTokens":6,"promptCacheHitTokens":30}},"cost":{"amount":0.1}}}"#, offset: 200))
        parser.consume(line(#"{"sessionId":"wb-session","timestamp":1789898520000,"update":{"id":"stage-b","_meta":{"codebuddy.ai/requestId":"request-1"},"cost":{"amount":0.2}}}"#, offset: 400))

        let session = try XCTUnwrap(try parser.finish(
            sourceURL: URL(fileURLWithPath: "/tmp/.workbuddy/projects/wb-session.jsonl")
        ).session)
        XCTAssertEqual(session.providerId, "workbuddy")
        XCTAssertEqual(session.events.count, 1)
        let event = session.events[0]
        XCTAssertEqual(event.inputTokens, 90, "promptTokens 包含缓存命中，应投影为不重叠输入")
        XCTAssertEqual(event.cacheReadTokens, 30)
        XCTAssertEqual(event.outputTokens, 15)
        XCTAssertEqual(event.reasoningTokens, 6)
        XCTAssertTrue(event.tokensReported)
        XCTAssertEqual(event.creditUsage?.actualPicos, 300_000_000_000)
    }

    func testContextUsageUpdateAndEstimatedCostAreNotCounted() throws {
        let parser = WorkBuddyUsageEventParser(resuming: nil, fallbackCredits: [:])
        parser.consume(line(#"{"sessionId":"wb-session","timestamp":1789898400000,"update":{"sessionUpdate":"usage_update","used":1234,"size":64000}}"#, offset: 0))
        parser.consume(line(#"{"sessionId":"wb-session","timestamp":1789898460000,"update":{"id":"estimate","_meta":{"requestId":"request-1"},"estimatedCost":{"amount":8.5}}}"#, offset: 100))

        let session = try XCTUnwrap(try parser.finish(
            sourceURL: URL(fileURLWithPath: "/tmp/.workbuddy/projects/wb-session.jsonl")
        ).session)
        XCTAssertTrue(session.events.isEmpty, "used/size 是上下文快照，estimatedCost 不是实际消耗")
    }

    func testDatabaseCreditsOnlyFillMissingActualRequests() throws {
        let parser = WorkBuddyUsageEventParser(
            resuming: nil,
            fallbackCredits: [
                "request-jsonl": WorkBuddyCreditFallback(amount: 9, observedAt: nil),
                "request-db": WorkBuddyCreditFallback(
                    amount: 0.4,
                    observedAt: Date(timeIntervalSince1970: 1_789_898_500)
                ),
                "req-12345": WorkBuddyCreditFallback(amount: 7, observedAt: nil),
            ]
        )
        parser.consume(line(#"{"sessionId":"wb-session","timestamp":1789898400000,"update":{"id":"actual","_meta":{"requestId":"request-jsonl"},"cost":{"amount":0.25}}}"#, offset: 0))

        let session = try XCTUnwrap(try parser.finish(
            sourceURL: URL(fileURLWithPath: "/tmp/.workbuddy/projects/wb-session.jsonl")
        ).session)
        let byRequest = Dictionary(uniqueKeysWithValues: session.events.map { ($0.messageId, $0) })
        XCTAssertEqual(byRequest["request-jsonl"]?.creditUsage?.actualPicos, 250_000_000_000,
                       "JSONL 实际值必须压过数据库累计投影")
        XCTAssertEqual(byRequest["request-db"]?.creditUsage?.actualPicos, 400_000_000_000)
        XCTAssertEqual(byRequest["request-db"]?.observedAt, Date(timeIntervalSince1970: 1_789_898_500))
        XCTAssertNil(byRequest["req-12345"], "纯数字 req-* 是 UI 乐观记录，不得当真实 Request")
        XCTAssertFalse(try XCTUnwrap(byRequest["request-db"]).tokensReported)
    }

    func testSubagentDoesNotReceiveSessionDatabaseFallback() throws {
        let parser = WorkBuddyUsageEventParser(
            resuming: nil,
            fallbackCredits: ["request-db": WorkBuddyCreditFallback(amount: 1, observedAt: nil)]
        )
        parser.consume(line(#"{"sessionId":"root-session","timestamp":1789898400000,"update":{"id":"child","_meta":{"requestId":"child-request"},"usage":{"details":{"promptTokens":5}}}}"#, offset: 0))

        let session = try XCTUnwrap(try parser.finish(
            sourceURL: URL(fileURLWithPath: "/tmp/.workbuddy/projects/root-session/subagents/child.jsonl")
        ).session)
        XCTAssertEqual(session.events.count, 1)
        XCTAssertTrue(session.events[0].isSidechain)
        XCTAssertNil(session.events[0].creditUsage)
    }
}
