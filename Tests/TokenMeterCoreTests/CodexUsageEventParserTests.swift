import XCTest
@testable import TokenMeterCore

final class CodexUsageEventParserTests: XCTestCase {
    private func line(_ text: String, offset: Int64) -> JSONLLine {
        JSONLLine(text: text, offset: offset, nextOffset: offset + 1)
    }

    private let meta = #"{"type":"session_meta","payload":{"id":"s1","timestamp":"2026-07-08T01:00:00Z","cwd":"/repo"}}"#
    private let turnContext = #"{"type":"turn_context","payload":{"model":"gpt-5.5"}}"#

    func testSubtractsCachedInputFromInput() throws {
        // Codex 的 input_tokens 已包含 cached_input_tokens
        let lines = [
            line(meta, offset: 0),
            line(turnContext, offset: 1),
            line(#"{"type":"event_msg","timestamp":"2026-07-08T01:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":900,"output_tokens":50,"reasoning_output_tokens":10,"total_tokens":1050}}}}"#, offset: 2)
        ]

        let (session, _) = try CodexUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/c.jsonl"), resuming: nil
        )

        XCTAssertEqual(session.events.count, 1)
        let event = session.events[0]
        XCTAssertEqual(event.inputTokens, 100, "input 必须减去 cached，否则缓存 token 被计两遍")
        XCTAssertEqual(event.cacheReadTokens, 900)
        XCTAssertEqual(event.outputTokens, 50)
        XCTAssertEqual(event.reasoningTokens, 10)
        // 900 不能算两遍；reasoning 也不能加进去
        XCTAssertEqual(event.totalTokens, 1050)
        XCTAssertEqual(event.modelName, "gpt-5.5")
    }

    func testReasoningIsNotAddedToTotal() throws {
        let lines = [
            line(meta, offset: 0),
            line(#"{"type":"event_msg","timestamp":"2026-07-08T01:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":80,"reasoning_output_tokens":60}}}}"#, offset: 1)
        ]

        let (session, _) = try CodexUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/c.jsonl"), resuming: nil
        )

        // reasoning 是 output 的子集：100 + 80 = 180，不是 240
        XCTAssertEqual(session.events[0].totalTokens, 180)
        XCTAssertEqual(session.events[0].reasoningTokens, 60)
    }

    func testPrefersLastTokenUsageOverCumulativeDiff() throws {
        let lines = [
            line(meta, offset: 0),
            line(#"{"type":"event_msg","timestamp":"2026-07-08T01:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":25,"cached_input_tokens":5,"output_tokens":5},"total_token_usage":{"input_tokens":125,"cached_input_tokens":30,"output_tokens":55}}}}"#, offset: 1)
        ]

        let (session, _) = try CodexUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/c.jsonl"), resuming: nil
        )

        XCTAssertEqual(session.events[0].inputTokens, 20)
        XCTAssertEqual(session.events[0].cacheReadTokens, 5)
        XCTAssertEqual(session.events[0].outputTokens, 5)
    }

    func testDiffsCumulativeTotalsWhenLastUsageMissing() throws {
        let lines = [
            line(meta, offset: 0),
            line(#"{"type":"event_msg","timestamp":"2026-07-08T01:05:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":20}}}}"#, offset: 1),
            line(#"{"type":"event_msg","timestamp":"2026-07-08T01:06:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":60,"output_tokens":30}}}}"#, offset: 2)
        ]

        let (session, state) = try CodexUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/c.jsonl"), resuming: nil
        )

        XCTAssertEqual(session.events.count, 2)
        // 第一条：input 100 - cached 40 = 60
        XCTAssertEqual(session.events[0].inputTokens, 60)
        XCTAssertEqual(session.events[0].cacheReadTokens, 40)
        // 第二条差分：input Δ50 - cached Δ20 = 30
        XCTAssertEqual(session.events[1].inputTokens, 30)
        XCTAssertEqual(session.events[1].cacheReadTokens, 20)
        XCTAssertEqual(session.events[1].outputTokens, 10)

        XCTAssertEqual(state.lastCumulative?.inputTokens, 150)
        XCTAssertEqual(state.lastCumulative?.cachedInputTokens, 60)
    }

    func testResumesCumulativeBaselineFromParserState() throws {
        let lines = [
            line(meta, offset: 0),
            line(#"{"type":"event_msg","timestamp":"2026-07-08T01:06:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":60,"output_tokens":30}}}}"#, offset: 900)
        ]

        let previous = ParserState(
            lastEventSeq: 4,
            lastCumulative: CumulativeTokenTotals(inputTokens: 100, cachedInputTokens: 40, outputTokens: 20, reasoningTokens: 0)
        )
        let (session, state) = try CodexUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/c.jsonl"), resuming: previous
        )

        XCTAssertEqual(session.events[0].eventSeq, 5)
        XCTAssertEqual(session.events[0].inputTokens, 30)
        XCTAssertEqual(session.events[0].cacheReadTokens, 20)
        XCTAssertEqual(state.lastEventSeq, 5)
    }

    func testTreatsCumulativeResetAsFreshBaseline() throws {
        // 累计值变小时（理论上的 compacted 场景），新值本身就是增量
        let lines = [
            line(meta, offset: 0),
            line(#"{"type":"event_msg","timestamp":"2026-07-08T01:05:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500,"cached_input_tokens":100,"output_tokens":50}}}}"#, offset: 1),
            line(#"{"type":"event_msg","timestamp":"2026-07-08T01:06:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":80,"cached_input_tokens":20,"output_tokens":10}}}}"#, offset: 2)
        ]

        let (session, _) = try CodexUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/c.jsonl"), resuming: nil
        )

        XCTAssertEqual(session.events.count, 2)
        XCTAssertEqual(session.events[1].inputTokens, 60)   // 80 - 20，不是负数
        XCTAssertEqual(session.events[1].outputTokens, 10)
    }

    func testSkipsStatusOnlyEventWithZeroInputAndOutput() throws {
        // 真实数据里 5366 条事件有 49 条长这样。那个 total_tokens 是当前上下文
        // 窗口大小，不是消耗——此时累计计数器也一动没动。绝不能把它当成 output。
        let lines = [
            line(meta, offset: 0),
            line(#"{"type":"event_msg","timestamp":"2026-07-08T01:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":24505}}}}"#, offset: 1)
        ]

        let (session, _) = try CodexUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/c.jsonl"), resuming: nil
        )

        XCTAssertTrue(session.events.isEmpty, "纯状态汇报事件必须跳过，不得凭空造出 24505 个 token")
    }

    func testCodexEventsHaveNoDedupeKey() throws {
        let lines = [
            line(meta, offset: 0),
            line(#"{"type":"event_msg","timestamp":"2026-07-08T01:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"output_tokens":1}}}}"#, offset: 1)
        ]

        let (session, _) = try CodexUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/c.jsonl"), resuming: nil
        )

        XCTAssertNil(session.events[0].dedupeKey)
        XCTAssertEqual(session.events[0].sourceOffset, 1)
    }

    func testThrowsWhenSessionKeyMissing() {
        let lines = [line(#"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1}}}}"#, offset: 0)]
        XCTAssertThrowsError(
            try CodexUsageEventParser.parse(lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/c.jsonl"), resuming: nil)
        ) { error in
            XCTAssertEqual(error as? LocalAgentParserError, .missingSessionKey)
        }
    }
}
