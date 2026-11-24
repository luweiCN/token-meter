import XCTest
@testable import TokenMeterCore

final class QoderUsageEventParserTests: XCTestCase {
    private func line(_ text: String, offset: Int64 = 0) -> JSONLLine {
        JSONLLine(text: text, offset: offset, nextOffset: offset + Int64(text.utf8.count) + 1)
    }

    func testParsesRequestTokensCreditsAndDesktopAttribution() throws {
        let parser = QoderUsageEventParser(
            resuming: nil,
            desktopSessionIDs: ["desktop-session"]
        )
        parser.consume(line(#"{"type":"assistant","sessionId":"desktop-session","cwd":"/repo","version":"1.1.58","timestamp":"2026-09-20T10:00:00Z","message":{"id":"message-1","model":"qwen3-coder","usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation":{"ephemeral_5m_input_tokens":4,"ephemeral_1h_input_tokens":5},"credits":0.25,"original_credits":0.5,"billable":true,"request_id":"request-1"}}}"#, offset: 42))

        let session = try XCTUnwrap(try parser.finish(
            sourceURL: URL(fileURLWithPath: "/tmp/projects/repo/desktop-session.jsonl")
        ).session)
        XCTAssertEqual(session.providerId, "qoder-desktop")
        XCTAssertEqual(session.sessionKey, "desktop-session")
        XCTAssertEqual(session.projectPath, "/repo")
        XCTAssertEqual(session.cliVersion, "1.1.58")

        let event = try XCTUnwrap(session.events.first)
        XCTAssertEqual(event.modelName, "qwen3-coder")
        XCTAssertEqual(event.inputTokens, 100)
        XCTAssertEqual(event.outputTokens, 20)
        XCTAssertEqual(event.cacheReadTokens, 30)
        XCTAssertEqual(event.cacheWrite5mTokens, 4)
        XCTAssertEqual(event.cacheWrite1hTokens, 5)
        XCTAssertTrue(event.tokensReported)
        XCTAssertEqual(event.creditUsage?.actualPicos, 250_000_000_000)
        XCTAssertEqual(event.creditUsage?.originalPicos, 500_000_000_000)
        XCTAssertEqual(event.creditUsage?.billable, true)
        XCTAssertEqual(event.dedupeKey, "request:request-1")
        XCTAssertEqual(event.sourceOffset, 42)
    }

    func testDistinguishesReportedZeroTokensFromMissingOrWithheldTokens() throws {
        let parser = QoderUsageEventParser(resuming: nil, desktopSessionIDs: [])
        parser.consume(line(#"{"type":"assistant","sessionId":"cli-session","timestamp":"2026-09-20T10:00:00Z","message":{"id":"m-zero","model":"qwen3-coder","usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"credits":0}}}"#))
        parser.consume(line(#"{"type":"assistant","sessionId":"cli-session","timestamp":"2026-09-20T10:01:00Z","message":{"id":"m-credit","model":"qwen3-coder","usage":{"credits":0.125,"request_id":"credit-only"}}}"#, offset: 200))
        parser.consume(line(#"{"type":"assistant","sessionId":"cli-session","timestamp":"2026-09-20T10:02:00Z","message":{"id":"m-withheld","model":"qmodel_38max","usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"credits":1.25,"original_credits":2.5,"request_id":"withheld"}}}"#, offset: 400))

        let session = try XCTUnwrap(try parser.finish(
            sourceURL: URL(fileURLWithPath: "/tmp/projects/cli-session.jsonl")
        ).session)
        XCTAssertEqual(session.providerId, "qoder-cli")
        XCTAssertEqual(session.events.count, 3)
        XCTAssertTrue(session.events[0].tokensReported, "明确上报的 0 不是缺失")
        XCTAssertFalse(session.events[1].tokensReported, "只有 Credits 时不得伪造 0 Token")
        XCTAssertEqual(session.events[1].creditUsage?.actualPicos, 125_000_000_000)
        XCTAssertFalse(
            session.events[2].tokensReported,
            "正数 Credits 搭配全零 Token 计数器表示 Token 未提供，不能向用户声称实际消耗为 0"
        )
        XCTAssertEqual(session.events[2].modelName, "qmodel_38max")
        XCTAssertEqual(session.events[2].creditUsage?.actualPicos, 1_250_000_000_000)
    }

    func testIgnoresCumulativeResultCreditsAndMarksSubagentSource() throws {
        let parser = QoderUsageEventParser(
            resuming: nil,
            desktopSessionIDs: [],
            isSubagentSource: true
        )
        parser.consume(line(#"{"type":"result","sessionId":"root-session","timestamp":"2026-09-20T10:00:00Z","total_credits":99.5}"#))
        parser.consume(line(#"{"type":"assistant","sessionId":"root-session","timestamp":"2026-09-20T10:01:00Z","message":{"id":"child-message","usage":{"input_tokens":1}}}"#, offset: 100))

        let session = try XCTUnwrap(try parser.finish(
            sourceURL: URL(fileURLWithPath: "/tmp/projects/root-session/subagents/worker.jsonl")
        ).session)
        XCTAssertEqual(session.sessionKey, "root-session")
        XCTAssertEqual(session.events.count, 1, "result.total_credits 是累计值，不得另生事件")
        XCTAssertTrue(session.events[0].isSidechain)
        XCTAssertNil(session.events[0].creditUsage)
    }
}
