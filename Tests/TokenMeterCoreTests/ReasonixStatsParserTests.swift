import XCTest
@testable import TokenMeterCore

final class ReasonixStatsParserTests: XCTestCase {
    private let sourceURL = URL(fileURLWithPath: "/Users/luwei/.reasonix/stats/2026-08-06.jsonl")

    private func line(_ text: String, offset: Int64 = 0) -> JSONLLine {
        JSONLLine(text: text, offset: offset, nextOffset: offset + Int64(text.count) + 1)
    }

    private func parse(
        _ lines: [JSONLLine],
        resuming state: ParserState? = nil
    ) throws -> (session: ParsedSession?, state: ParserState) {
        let parser = ReasonixStatsParser(resuming: state)
        for line in lines { parser.consume(line) }
        return try parser.finish(sourceURL: sourceURL)
    }

    func testParsesRequestRowsWithFieldMapping() throws {
        let result = try parse([
            line("""
            {"ts":"2026-08-06T13:41:56.164497+08:00","model":"go-flash/deepseek-v4-flash","source":"cli","prompt":14881,"completion":20,"reasoning":18,"cache_miss":14881,"total":14901,"requests":1}
            """),
            line("""
            {"ts":"2026-08-06T13:43:34.996153+08:00","model":"opencode/deepseek-v4-flash","source":"cli","prompt":14881,"completion":16,"reasoning":14,"cache_hit":14848,"cache_miss":33,"total":14897,"requests":1}
            """)
        ])

        let session = try XCTUnwrap(result.session)
        XCTAssertEqual(session.sourceKind, .reasonixStats)
        XCTAssertEqual(session.sessionKey, "2026-08-06.jsonl")
        XCTAssertEqual(session.rawMeta["source"], "reasonix")
        XCTAssertEqual(session.events.count, 2)

        // 无缓存行：input = cache_miss，cacheRead = 0
        let first = session.events[0]
        XCTAssertEqual(first.modelName, "go-flash/deepseek-v4-flash")
        XCTAssertEqual(first.inputTokens, 14881)
        XCTAssertEqual(first.outputTokens, 20)
        XCTAssertEqual(first.reasoningTokens, 18)
        XCTAssertEqual(first.cacheReadTokens, 0)
        XCTAssertEqual(first.totalTokens, 14901)

        // 有缓存行：input = cache_miss，cacheRead = cache_hit
        let second = session.events[1]
        XCTAssertEqual(second.inputTokens, 33)
        XCTAssertEqual(second.cacheReadTokens, 14848)
        XCTAssertEqual(second.outputTokens, 16)
        XCTAssertEqual(second.totalTokens, 14897)

        // 时区正确解析（+08:00 微秒时间戳 → UTC 05:41:56）
        XCTAssertEqual(
            Int(session.events[0].observedAt.timeIntervalSince1970),
            1_785_994_916
        )
        XCTAssertEqual(session.startedAt, session.events[0].observedAt)
        XCTAssertEqual(session.updatedAt, session.events[1].observedAt)
    }

    func testSkipsTurnRowsAndMalformedLines() throws {
        let result = try parse([
            line(#"{"ts":"2026-08-06T13:41:56.182201+08:00","source":"cli","turn":true}"#),
            line("not-json"),
            line("")
        ])

        XCTAssertNil(result.session)
    }

    func testTurnRowsAroundRequestRowsDoNotBreakParsing() throws {
        let result = try parse([
            line(#"{"ts":"2026-08-06T13:41:56.182201+08:00","source":"cli","turn":true}"#),
            line("""
            {"ts":"2026-08-06T13:41:56.164497+08:00","model":"deepseek-v4-flash","source":"cli","prompt":100,"completion":5,"cache_miss":100,"total":105,"requests":1}
            """)
        ])

        let session = try XCTUnwrap(result.session)
        XCTAssertEqual(session.events.count, 1)
    }

    func testRowsWithoutTokensAreSkipped() throws {
        let result = try parse([
            line(#"{"ts":"2026-08-06T13:41:56.164497+08:00","model":"x","source":"cli","prompt":0,"completion":0,"total":0,"requests":1}"#)
        ])

        XCTAssertNil(result.session)
    }

    func testResumeContinuesEventSeq() throws {
        let first = try parse([
            line("""
            {"ts":"2026-08-06T13:41:56.164497+08:00","model":"m1","source":"cli","prompt":10,"completion":5,"cache_miss":10,"total":15,"requests":1}
            """)
        ])
        XCTAssertEqual(first.session?.events.first?.eventSeq, 1)

        let second = try parse([
            line("""
            {"ts":"2026-08-06T13:42:06.749497+08:00","model":"m2","source":"cli","prompt":20,"completion":5,"cache_miss":20,"total":25,"requests":1}
            """)
        ], resuming: first.state)
        XCTAssertEqual(second.session?.events.first?.eventSeq, 2)
    }

    func testDedupeKeyIsStablePerRow() throws {
        let row = line("""
        {"ts":"2026-08-06T13:41:56.164497+08:00","model":"go-flash/deepseek-v4-flash","source":"cli","prompt":14881,"completion":20,"reasoning":18,"cache_miss":14881,"total":14901,"requests":1}
        """)
        let result = try parse([row])
        let key = result.session?.events.first?.dedupeKey
        XCTAssertEqual(key, "2026-08-06T13:41:56.164497+08:00-go-flash/deepseek-v4-flash-14901")
    }
}
