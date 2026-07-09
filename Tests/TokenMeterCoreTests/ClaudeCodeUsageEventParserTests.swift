import XCTest
@testable import TokenMeterCore

final class ClaudeCodeUsageEventParserTests: XCTestCase {
    private func line(_ text: String, offset: Int64) -> JSONLLine {
        JSONLLine(text: text, offset: offset, nextOffset: offset + 1)
    }

    func testEmitsOneEventPerAssistantMessage() throws {
        let lines = [
            line(#"{"type":"assistant","timestamp":"2026-07-08T01:00:00Z","sessionId":"s1","cwd":"/repo","requestId":"req_1","version":"2.1.0","message":{"id":"msg_1","role":"assistant","model":"claude-fable-5","usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":900,"cache_creation":{"ephemeral_5m_input_tokens":50,"ephemeral_1h_input_tokens":20}}}}"#, offset: 0),
            line(#"{"type":"assistant","timestamp":"2026-07-08T02:00:00Z","sessionId":"s1","requestId":"req_2","message":{"id":"msg_2","role":"assistant","model":"claude-opus-4-8","usage":{"input_tokens":200,"output_tokens":20}}}"#, offset: 1)
        ]

        let (session, state) = try ClaudeCodeUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/a.jsonl"), resuming: nil
        )

        XCTAssertEqual(session.sessionKey, "s1")
        XCTAssertEqual(session.projectPath, "/repo")
        XCTAssertEqual(session.cliVersion, "2.1.0")
        XCTAssertEqual(session.events.count, 2)

        XCTAssertEqual(session.events[0].modelName, "claude-fable-5")
        XCTAssertEqual(session.events[0].inputTokens, 100)
        XCTAssertEqual(session.events[0].cacheReadTokens, 900)
        XCTAssertEqual(session.events[0].cacheWrite5mTokens, 50)
        XCTAssertEqual(session.events[0].cacheWrite1hTokens, 20)
        XCTAssertEqual(session.events[0].dedupeKey, "msg_1")

        // 同一会话内换了模型，各归各的
        XCTAssertEqual(session.events[1].modelName, "claude-opus-4-8")
        XCTAssertEqual(session.events[1].inputTokens, 200)

        XCTAssertEqual(state.lastEventSeq, 2)
    }

    func testEventTimestampsArePreservedPerMessage() throws {
        let lines = [
            line(#"{"type":"assistant","timestamp":"2026-07-06T23:30:00Z","sessionId":"s1","requestId":"r1","message":{"id":"m1","role":"assistant","model":"m","usage":{"input_tokens":1}}}"#, offset: 0),
            line(#"{"type":"assistant","timestamp":"2026-07-08T00:30:00Z","sessionId":"s1","requestId":"r2","message":{"id":"m2","role":"assistant","model":"m","usage":{"input_tokens":1}}}"#, offset: 1)
        ]

        let (session, _) = try ClaudeCodeUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/a.jsonl"), resuming: nil
        )

        // 跨天会话：两条事件必须各自保留时间戳，不能都归到最后一天
        let formatter = ISO8601DateFormatter()
        XCTAssertEqual(session.events[0].observedAt, formatter.date(from: "2026-07-06T23:30:00Z"))
        XCTAssertEqual(session.events[1].observedAt, formatter.date(from: "2026-07-08T00:30:00Z"))
    }

    func testFallsBackToLegacyCacheCreationField() throws {
        let lines = [
            line(#"{"type":"assistant","timestamp":"2026-07-08T01:00:00Z","sessionId":"s1","requestId":"r1","message":{"id":"m1","role":"assistant","model":"m","usage":{"input_tokens":1,"cache_creation_input_tokens":300}}}"#, offset: 0)
        ]

        let (session, _) = try ClaudeCodeUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/a.jsonl"), resuming: nil
        )

        // 没有 5m/1h 明细时，整笔算作 5m 档
        XCTAssertEqual(session.events[0].cacheWrite5mTokens, 300)
        XCTAssertEqual(session.events[0].cacheWrite1hTokens, 0)
    }

    func testMarksSidechainEvents() throws {
        let lines = [
            line(#"{"type":"assistant","timestamp":"2026-07-08T01:00:00Z","sessionId":"s1","requestId":"r1","isSidechain":true,"message":{"id":"m1","role":"assistant","model":"m","usage":{"input_tokens":1}}}"#, offset: 0)
        ]

        let (session, _) = try ClaudeCodeUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/a.jsonl"), resuming: nil
        )

        XCTAssertTrue(session.events[0].isSidechain)
    }

    func testSkipsNonAssistantAndUsagelessLines() throws {
        let lines = [
            line(#"{"type":"user","timestamp":"2026-07-08T01:00:00Z","sessionId":"s1","message":{"role":"user","content":"hi"}}"#, offset: 0),
            line(#"{"type":"assistant","timestamp":"2026-07-08T01:00:01Z","sessionId":"s1","message":{"id":"m1","role":"assistant","model":"m"}}"#, offset: 1)
        ]

        let (session, _) = try ClaudeCodeUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/a.jsonl"), resuming: nil
        )

        XCTAssertEqual(session.sessionKey, "s1")
        XCTAssertTrue(session.events.isEmpty)
    }

    func testResumingContinuesEventSeq() throws {
        let lines = [
            line(#"{"type":"assistant","timestamp":"2026-07-08T01:00:00Z","sessionId":"s1","requestId":"r9","message":{"id":"m9","role":"assistant","model":"m","usage":{"input_tokens":1}}}"#, offset: 500)
        ]

        let (session, state) = try ClaudeCodeUsageEventParser.parse(
            lines: lines,
            sourceURL: URL(fileURLWithPath: "/tmp/a.jsonl"),
            resuming: ParserState(lastEventSeq: 7)
        )

        XCTAssertEqual(session.events[0].eventSeq, 8)
        XCTAssertEqual(session.events[0].sourceOffset, 500)
        XCTAssertEqual(state.lastEventSeq, 8)
    }

    func testThrowsWhenSessionKeyMissing() {
        let lines = [line(#"{"type":"assistant","message":{"role":"assistant"}}"#, offset: 0)]
        XCTAssertThrowsError(
            try ClaudeCodeUsageEventParser.parse(lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/a.jsonl"), resuming: nil)
        ) { error in
            XCTAssertEqual(error as? LocalAgentParserError, .missingSessionKey)
        }
    }
}
