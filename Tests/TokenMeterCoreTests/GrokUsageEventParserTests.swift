import XCTest
@testable import TokenMeterCore

final class GrokUsageEventParserTests: XCTestCase {
    private func line(_ text: String, offset: Int64) -> JSONLLine {
        JSONLLine(text: text, offset: offset, nextOffset: offset + Int64(text.utf8.count) + 1)
    }

    private func parse(
        _ lines: [JSONLLine],
        sourceURL: URL = URL(fileURLWithPath: "/tmp/proj-enc/sess-1/updates.jsonl"),
        resuming: ParserState? = nil
    ) throws -> (session: ParsedSession?, state: ParserState) {
        let parser = GrokUsageEventParser(resuming: resuming)
        for line in lines { parser.consume(line) }
        return try parser.finish(sourceURL: sourceURL)
    }

    func testTurnCompletedSplitsInclusiveBuckets() throws {
        let json = """
        {"timestamp":1787744223,"method":"_x.ai/session/update","params":{"sessionId":"sess-1","update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":1332007,"outputTokens":10990,"totalTokens":1342997,"cachedReadTokens":1196416,"cacheCreationTokens":0,"reasoningTokens":9148,"modelUsage":{"grok-4.6-build":{"inputTokens":1332007}}}},"_meta":{"eventId":"sess-1-1224","agentTimestampMs":1787744223003}}}
        """
        let result = try parse([line(json, offset: 42)])
        let session = try XCTUnwrap(result.session)
        XCTAssertEqual(session.sourceKind, .grokJSONL)
        XCTAssertEqual(session.sessionKey, "sess-1")
        XCTAssertEqual(session.events.count, 1)
        let event = session.events[0]
        XCTAssertEqual(event.inputTokens, 135591)
        XCTAssertEqual(event.cacheReadTokens, 1_196_416)
        XCTAssertEqual(event.cacheWrite5mTokens, 0)
        XCTAssertEqual(event.outputTokens, 10990)
        XCTAssertEqual(event.reasoningTokens, 9148)
        XCTAssertEqual(event.totalTokens, 1_342_997)
        XCTAssertEqual(event.modelName, "grok-4.6-build")
        XCTAssertNil(event.reportedCostUSDMicros)
        XCTAssertEqual(event.dedupeKey, "grok:sess-1:sess-1-1224:42")
        XCTAssertEqual(event.sourceOffset, 42)
        XCTAssertEqual(event.observedEpochMilliseconds, 1_787_744_223_003)
        XCTAssertEqual(result.state.grokSawUsage, true)
        XCTAssertEqual(result.state.requiresFullReplay, nil)
    }

    func testDuplicateEventIdDifferentOffsetAreDistinct() throws {
        func record(_ eventId: String, offset: Int64) -> JSONLLine {
            line(
                """
                {"params":{"sessionId":"sess-1","update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":100,"outputTokens":10,"totalTokens":110,"cachedReadTokens":0,"reasoningTokens":0}},"_meta":{"eventId":"\(eventId)","agentTimestampMs":1700000000000}}}
                """,
                offset: offset
            )
        }
        let session = try XCTUnwrap(try parse([record("same", offset: 10), record("same", offset: 99)]).session)
        XCTAssertEqual(session.events.map(\.dedupeKey), [
            "grok:sess-1:same:10",
            "grok:sess-1:same:99"
        ])
    }

    func testZeroUsageProducesNoEvent() throws {
        let json = #"{"params":{"sessionId":"sess-1","update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":0,"outputTokens":0,"totalTokens":0}}}}"#
        let result = try parse([line(json, offset: 0)])
        XCTAssertNil(result.session)
    }
}
