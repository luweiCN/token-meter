import XCTest
@testable import TokenMeterCore

final class ClaudeCodeSessionParserTests: XCTestCase {
    func testParsesSessionAndAssistantUsageWithoutBodyText() throws {
        let lines = [
            JSONLLine(text: #"{"type":"summary","summary":"Do not store this as message body","leafUuid":"claude-session-1"}"#, offset: 0, nextOffset: 1),
            JSONLLine(text: #"{"sessionId":"claude-session-1","cwd":"/repo","timestamp":"2026-07-03T02:00:00Z","version":"1.2.3","type":"assistant","requestId":"req-1","message":{"id":"msg-1","model":"claude-sonnet","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":3,"cache_creation_input_tokens":4},"content":[{"type":"text","text":"SECRET_RESPONSE"}]}}"#, offset: 1, nextOffset: 2)
        ]

        let parsed = try ClaudeCodeSessionParser().parse(lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/claude.jsonl"))

        XCTAssertEqual(parsed.sourceKind, .claudeJSONL)
        XCTAssertEqual(parsed.sessionKey, "claude-session-1")
        XCTAssertEqual(parsed.projectPath, "/repo")
        XCTAssertEqual(parsed.modelName, "claude-sonnet")
        XCTAssertEqual(parsed.cliVersion, "1.2.3")
        XCTAssertEqual(parsed.startedAt, ISO8601DateFormatter().date(from: "2026-07-03T02:00:00Z"))
        XCTAssertEqual(parsed.updatedAt, ISO8601DateFormatter().date(from: "2026-07-03T02:00:00Z"))
        XCTAssertEqual(parsed.usage?.inputTokens, 10)
        XCTAssertEqual(parsed.usage?.outputTokens, 20)
        XCTAssertEqual(parsed.usage?.cacheReadTokens, 3)
        XCTAssertEqual(parsed.usage?.cacheWriteTokens, 4)
        XCTAssertEqual(parsed.usageSequence, 1)
        XCTAssertEqual(parsed.sourceOffset, 1)
        XCTAssertEqual(parsed.rawMeta, ["source": "claude-code"])
        XCTAssertFalse(parsed.rawMeta.values.contains { $0.contains("SECRET_RESPONSE") || $0.contains("Do not store") })
    }

    func testUsesLeafUuidWhenSessionIdIsMissing() throws {
        let lines = [
            JSONLLine(text: #"{"type":"summary","summary":"PRIVATE_SUMMARY","leafUuid":"leaf-session"}"#, offset: 0, nextOffset: 1),
            JSONLLine(text: #"{"type":"assistant","timestamp":"2026-07-03T02:00:00Z","message":{"id":"msg-leaf","model":"claude-haiku","usage":{"input_tokens":1,"output_tokens":2}}}"#, offset: 1, nextOffset: 2)
        ]

        let parsed = try ClaudeCodeSessionParser().parse(lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/claude.jsonl"))

        XCTAssertEqual(parsed.sessionKey, "leaf-session")
        XCTAssertEqual(parsed.modelName, "claude-haiku")
        XCTAssertEqual(parsed.usage?.inputTokens, 1)
        XCTAssertFalse(parsed.rawMeta.values.contains { $0.contains("PRIVATE_SUMMARY") })
    }

    func testAcceptsNestedCacheCreationValues() throws {
        let lines = [
            JSONLLine(text: #"{"sessionId":"cache-session","type":"assistant","requestId":"req-cache","message":{"id":"msg-cache","model":"claude-sonnet","usage":{"input_tokens":8,"output_tokens":5,"cache_read_input_tokens":2,"cache_creation":{"ephemeral_5m_input_tokens":3,"ephemeral_1h_input_tokens":4}}}}"#, offset: 0, nextOffset: 1)
        ]

        let parsed = try ClaudeCodeSessionParser().parse(lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/claude.jsonl"))

        XCTAssertEqual(parsed.usage?.inputTokens, 8)
        XCTAssertEqual(parsed.usage?.outputTokens, 5)
        XCTAssertEqual(parsed.usage?.cacheReadTokens, 2)
        XCTAssertEqual(parsed.usage?.cacheWriteTokens, 7)
    }

    func testDeduplicatesMessageRequestPairsPreferringNonSidechain() throws {
        let lines = [
            JSONLLine(text: #"{"sessionId":"dedupe-session","type":"assistant","requestId":"req-1","isSidechain":true,"costUSD":0.010000,"message":{"id":"msg-1","model":"claude-sonnet","usage":{"input_tokens":100,"output_tokens":50}}}"#, offset: 0, nextOffset: 1),
            JSONLLine(text: #"{"sessionId":"dedupe-session","type":"assistant","requestId":"req-1","isSidechain":false,"costUSD":0.002000,"message":{"id":"msg-1","model":"claude-sonnet","usage":{"input_tokens":10,"output_tokens":5}}}"#, offset: 1, nextOffset: 2),
            JSONLLine(text: #"{"sessionId":"dedupe-session","type":"assistant","requestId":"req-2","costUSD":0.003000,"message":{"id":"msg-2","model":"claude-sonnet","usage":{"input_tokens":7,"output_tokens":8}}}"#, offset: 2, nextOffset: 3)
        ]

        let parsed = try ClaudeCodeSessionParser().parse(lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/claude.jsonl"))

        XCTAssertEqual(parsed.usage?.inputTokens, 17)
        XCTAssertEqual(parsed.usage?.outputTokens, 13)
        XCTAssertEqual(parsed.usage?.costUSDMicros, 5_000)
        XCTAssertEqual(parsed.usageSequence, 2)
        XCTAssertEqual(parsed.sourceOffset, 2)
    }

    func testDeduplicatesMessageRequestPairsRetainingLargerUsageWhenSidechainStatusDoesNotDecide() throws {
        let lines = [
            JSONLLine(text: #"{"sessionId":"dedupe-larger","type":"assistant","requestId":"req-1","isSidechain":false,"costUSD":0.001000,"message":{"id":"msg-1","model":"claude-sonnet","usage":{"input_tokens":1,"output_tokens":1}}}"#, offset: 0, nextOffset: 1),
            JSONLLine(text: #"{"sessionId":"dedupe-larger","type":"assistant","requestId":"req-1","isSidechain":false,"costUSD":0.009000,"message":{"id":"msg-1","model":"claude-sonnet","usage":{"input_tokens":9,"output_tokens":9}}}"#, offset: 1, nextOffset: 2)
        ]

        let parsed = try ClaudeCodeSessionParser().parse(lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/claude.jsonl"))

        XCTAssertEqual(parsed.usage?.inputTokens, 9)
        XCTAssertEqual(parsed.usage?.outputTokens, 9)
        XCTAssertEqual(parsed.usage?.costUSDMicros, 9_000)
        XCTAssertEqual(parsed.usageSequence, 1)
        XCTAssertEqual(parsed.sourceOffset, 1)
    }

    func testSkipsMalformedAndNonMatchingLinesAndParsesFractionalTimestamps() throws {
        let lines = [
            JSONLLine(text: #"{"sessionId":"time-session","cwd":"/repo","timestamp":"2026-05-13T09:00:00.000Z","type":"user","message":{"content":"SECRET_PROMPT"}}"#, offset: 0, nextOffset: 1),
            JSONLLine(text: #"not json"#, offset: 1, nextOffset: 2),
            JSONLLine(text: #"{"sessionId":"time-session","timestamp":"2026-05-13T09:01:02.123Z","type":"assistant","message":{"id":"msg-time","model":"claude-sonnet","usage":{"input_tokens":3,"output_tokens":4},"content":"SECRET_RESPONSE"}}"#, offset: 2, nextOffset: 3)
        ]

        let parsed = try ClaudeCodeSessionParser().parse(lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/claude.jsonl"))

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(parsed.startedAt, formatter.date(from: "2026-05-13T09:00:00.000Z"))
        XCTAssertEqual(parsed.updatedAt, formatter.date(from: "2026-05-13T09:01:02.123Z"))
        XCTAssertEqual(parsed.usage?.inputTokens, 3)
        XCTAssertFalse(parsed.rawMeta.values.contains { $0.contains("SECRET_PROMPT") || $0.contains("SECRET_RESPONSE") })
    }
}
