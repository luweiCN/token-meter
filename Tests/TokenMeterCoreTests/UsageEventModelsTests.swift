import XCTest
@testable import TokenMeterCore

final class UsageEventModelsTests: XCTestCase {
    func testTotalTokensExcludesReasoning() {
        let event = UsageEvent(
            eventSeq: 1,
            observedAt: Date(timeIntervalSince1970: 0),
            dedupeKey: nil,
            inputTokens: 100,
            outputTokens: 50,
            reasoningTokens: 20,
            cacheReadTokens: 900,
            sourceOffset: 0
        )
        // reasoning 是 output 的子集，不参与求和
        XCTAssertEqual(event.totalTokens, 1050)
    }

    func testTotalTokensSumsBothCacheWriteTiers() {
        let event = UsageEvent(
            eventSeq: 1,
            observedAt: Date(timeIntervalSince1970: 0),
            dedupeKey: nil,
            inputTokens: 10,
            outputTokens: 5,
            cacheWrite5mTokens: 100,
            cacheWrite1hTokens: 200,
            sourceOffset: 0
        )
        XCTAssertEqual(event.totalTokens, 315)
    }

    func testObservedEpochMillisecondsRoundsToNearestMillisecond() {
        let event = UsageEvent(
            eventSeq: 1,
            observedAt: Date(timeIntervalSince1970: 1_782_940_713.4996),
            dedupeKey: nil,
            sourceOffset: 0
        )
        // 1782940713.4996 * 1000 = 1782940713499.6 -> rounds to ...500
        XCTAssertEqual(event.observedEpochMilliseconds, 1_782_940_713_500)
    }

    func testObservedEpochMillisecondsAtEpochIsZero() {
        let event = UsageEvent(
            eventSeq: 1,
            observedAt: Date(timeIntervalSince1970: 0),
            dedupeKey: nil,
            sourceOffset: 0
        )
        XCTAssertEqual(event.observedEpochMilliseconds, 0)
    }

    func testParserStateRoundTripsThroughJSON() throws {
        let state = ParserState(
            lastEventSeq: 7,
            lastCumulative: CumulativeTokenTotals(inputTokens: 100, cachedInputTokens: 90, outputTokens: 10, reasoningTokens: 2)
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(ParserState.self, from: data)
        XCTAssertEqual(decoded, state)
    }
}
