import XCTest
@testable import TokenMeterCore

final class CodexSessionParserTests: XCTestCase {
    func testParsesSessionMetaTurnContextAndLatestTokenCount() throws {
        let lines = [
            JSONLLine(text: #"{"type":"session_meta","payload":{"id":"session-1","timestamp":"2026-07-03T01:00:00Z","cwd":"/Users/luwei/code/ai/token-meter"}}"#, offset: 0, nextOffset: 1),
            JSONLLine(text: #"{"type":"turn_context","payload":{"model":"gpt-5.3","cwd":"/Users/luwei/code/ai/token-meter"}}"#, offset: 1, nextOffset: 2),
            JSONLLine(text: #"{"type":"event_msg","timestamp":"2026-07-03T01:05:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":30,"reasoning_output_tokens":7}}}}"#, offset: 2, nextOffset: 3)
        ]

        let parsed = try CodexSessionParser().parse(lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/codex.jsonl"))

        XCTAssertEqual(parsed.sourceKind, .codexJSONL)
        XCTAssertEqual(parsed.sessionKey, "session-1")
        XCTAssertEqual(parsed.projectPath, "/Users/luwei/code/ai/token-meter")
        XCTAssertEqual(parsed.modelName, "gpt-5.3")
        XCTAssertEqual(parsed.startedAt, ISO8601DateFormatter().date(from: "2026-07-03T01:00:00Z"))
        XCTAssertEqual(parsed.updatedAt, ISO8601DateFormatter().date(from: "2026-07-03T01:05:00Z"))
        XCTAssertEqual(parsed.usage?.inputTokens, 100)
        XCTAssertEqual(parsed.usage?.cacheReadTokens, 20)
        XCTAssertEqual(parsed.usage?.outputTokens, 30)
        XCTAssertEqual(parsed.usage?.reasoningTokens, 7)
        XCTAssertEqual(parsed.usageSequence, 1)
        XCTAssertEqual(parsed.sourceOffset, 2)
        XCTAssertEqual(parsed.rawMeta, ["source": "codex"])
    }

    func testUsesLastTokenUsageBeforeCumulativeTotals() throws {
        let lines = [
            JSONLLine(text: #"{"type":"session_meta","payload":{"id":"session-last","cwd":"/repo"}}"#, offset: 0, nextOffset: 1),
            JSONLLine(text: #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":25,"output_tokens":5,"cached_input_tokens":3,"reasoning_output_tokens":2},"total_token_usage":{"input_tokens":125,"output_tokens":55,"cached_input_tokens":30,"reasoning_output_tokens":12}}}}"#, offset: 1, nextOffset: 2)
        ]

        let parsed = try CodexSessionParser().parse(lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/codex.jsonl"))

        XCTAssertEqual(parsed.usage?.inputTokens, 25)
        XCTAssertEqual(parsed.usage?.outputTokens, 5)
        XCTAssertEqual(parsed.usage?.cacheReadTokens, 3)
        XCTAssertEqual(parsed.usage?.reasoningTokens, 2)
        XCTAssertEqual(parsed.usageSequence, 1)
        XCTAssertEqual(parsed.sourceOffset, 1)
    }

    func testComputesDeltaWhenOnlyCumulativeTotalsArePresent() throws {
        let lines = [
            JSONLLine(text: #"{"type":"session_meta","payload":{"id":"session-delta","cwd":"/repo"}}"#, offset: 0, nextOffset: 1),
            JSONLLine(text: #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20}}}}"#, offset: 1, nextOffset: 2),
            JSONLLine(text: #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"output_tokens":30}}}}"#, offset: 2, nextOffset: 3)
        ]

        let parsed = try CodexSessionParser().parse(lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/codex.jsonl"))

        XCTAssertEqual(parsed.usage?.inputTokens, 50)
        XCTAssertEqual(parsed.usage?.outputTokens, 10)
        XCTAssertEqual(parsed.usageSequence, 2)
        XCTAssertEqual(parsed.sourceOffset, 2)
    }

    func testAcceptsAlternateTokenNamesAndClampsCacheReadToInput() throws {
        let lines = [
            JSONLLine(text: #"{"type":"session_meta","payload":{"id":"session-alias","cwd":"/repo"}}"#, offset: 0, nextOffset: 1),
            JSONLLine(text: #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"prompt_tokens":"40","completion_tokens":10.0,"cache_read_input_tokens":45,"reasoning_tokens":"6"}}}}"#, offset: 1, nextOffset: 2),
            JSONLLine(text: #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input":8,"output":4,"cached_tokens":2}}}}"#, offset: 2, nextOffset: 3)
        ]

        let parsed = try CodexSessionParser().parse(lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/codex.jsonl"))

        XCTAssertEqual(parsed.usage?.inputTokens, 8)
        XCTAssertEqual(parsed.usage?.outputTokens, 4)
        XCTAssertEqual(parsed.usage?.cacheReadTokens, 2)
        XCTAssertEqual(parsed.usage?.reasoningTokens, nil)
        XCTAssertEqual(parsed.usageSequence, 2)
    }

    func testClampsCachedInputAliasToInputTokens() throws {
        let lines = [
            JSONLLine(text: #"{"type":"session_meta","payload":{"id":"session-clamp","cwd":"/repo"}}"#, offset: 0, nextOffset: 1),
            JSONLLine(text: #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"prompt_tokens":"40","completion_tokens":10.0,"cache_read_input_tokens":45,"reasoning_tokens":"6"}}}}"#, offset: 1, nextOffset: 2)
        ]

        let parsed = try CodexSessionParser().parse(lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/codex.jsonl"))

        XCTAssertEqual(parsed.usage?.inputTokens, 40)
        XCTAssertEqual(parsed.usage?.outputTokens, 10)
        XCTAssertEqual(parsed.usage?.cacheReadTokens, 40)
        XCTAssertEqual(parsed.usage?.reasoningTokens, 6)
    }

    func testReadsModelFromTokenCountPayloadAndInfoMetadata() throws {
        let lines = [
            JSONLLine(text: #"{"type":"session_meta","payload":{"id":"session-model","cwd":"/repo"}}"#, offset: 0, nextOffset: 1),
            JSONLLine(text: #"{"type":"event_msg","payload":{"type":"token_count","model_name":"gpt-from-payload","metadata":{"model":"gpt-from-payload-metadata"},"info":{"model":"gpt-from-info","metadata":{"model":"gpt-from-info-metadata"},"last_token_usage":{"input_tokens":10,"output_tokens":2}}}}"#, offset: 1, nextOffset: 2)
        ]

        let parsed = try CodexSessionParser().parse(lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/codex.jsonl"))

        XCTAssertEqual(parsed.modelName, "gpt-from-payload")
    }

    func testFallsBackToSourceFileNameWhenSessionMetadataOmitsId() throws {
        let lines = [
            JSONLLine(text: #"{"type":"turn_context","payload":{"model":"gpt-5","cwd":"/repo"}}"#, offset: 0, nextOffset: 1),
            JSONLLine(text: #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1,"output_tokens":2}}}}"#, offset: 1, nextOffset: 2)
        ]

        let parsed = try CodexSessionParser().parse(lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/session-from-path.jsonl"))

        XCTAssertEqual(parsed.sessionKey, "session-from-path")
    }

    func testSkipsDuplicateCumulativeSnapshotEvenWhenLastUsageExists() throws {
        let lines = [
            JSONLLine(text: #"{"type":"session_meta","payload":{"id":"session-duplicate","cwd":"/repo"}}"#, offset: 0, nextOffset: 1),
            JSONLLine(text: #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"output_tokens":20},"total_token_usage":{"input_tokens":100,"output_tokens":20}}}}"#, offset: 1, nextOffset: 2),
            JSONLLine(text: #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"output_tokens":20},"total_token_usage":{"input_tokens":100,"output_tokens":20}}}}"#, offset: 2, nextOffset: 3)
        ]

        let parsed = try CodexSessionParser().parse(lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/codex.jsonl"))

        XCTAssertEqual(parsed.usageSequence, 1)
        XCTAssertEqual(parsed.sourceOffset, 1)
    }

    func testParsesFractionalSecondTimestamps() throws {
        let lines = [
            JSONLLine(text: #"{"type":"session_meta","payload":{"id":"session-time","timestamp":"2026-05-13T09:00:00.000Z","cwd":"/repo"}}"#, offset: 0, nextOffset: 1),
            JSONLLine(text: #"{"type":"event_msg","timestamp":"2026-05-13T09:01:02.123Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1,"output_tokens":2}}}}"#, offset: 1, nextOffset: 2)
        ]

        let parsed = try CodexSessionParser().parse(lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/codex.jsonl"))

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(parsed.startedAt, formatter.date(from: "2026-05-13T09:00:00.000Z"))
        XCTAssertEqual(parsed.updatedAt, formatter.date(from: "2026-05-13T09:01:02.123Z"))
    }
}
