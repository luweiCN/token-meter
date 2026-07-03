import XCTest
@testable import TokenMeterCore

final class OmpSessionParserTests: XCTestCase {
    func testParsesSessionModelChangeAndUsage() throws {
        let lines = [
            JSONLLine(text: #"{"type":"session","id":"omp-session-1","cwd":"/repo","timestamp":"2026-07-03T03:00:00Z"}"#, offset: 0, nextOffset: 1),
            JSONLLine(text: #"{"type":"model_change","model":"gpt-5.5","timestamp":"2026-07-03T03:01:00Z"}"#, offset: 1, nextOffset: 2),
            JSONLLine(text: #"{"type":"message","timestamp":"2026-07-03T03:02:00Z","message":{"role":"assistant","content":"SECRET_OMP_RESPONSE","usage":{"inputTokens":11,"outputTokens":22,"reasoningTokens":1,"cacheReadTokens":5,"cacheWriteTokens":6,"totalTokens":44,"cost":{"total":0.012345}}}}"#, offset: 2, nextOffset: 3)
        ]

        let parsed = try OmpSessionParser().parse(lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/omp.jsonl"))

        XCTAssertEqual(parsed.sourceKind, .ompJSONL)
        XCTAssertEqual(parsed.sessionKey, "omp-session-1")
        XCTAssertEqual(parsed.projectPath, "/repo")
        XCTAssertEqual(parsed.modelName, "gpt-5.5")
        XCTAssertEqual(parsed.startedAt, ISO8601DateFormatter().date(from: "2026-07-03T03:00:00Z"))
        XCTAssertEqual(parsed.updatedAt, ISO8601DateFormatter().date(from: "2026-07-03T03:02:00Z"))
        XCTAssertEqual(parsed.usage?.inputTokens, 11)
        XCTAssertEqual(parsed.usage?.outputTokens, 22)
        XCTAssertEqual(parsed.usage?.reasoningTokens, 1)
        XCTAssertEqual(parsed.usage?.cacheReadTokens, 5)
        XCTAssertEqual(parsed.usage?.cacheWriteTokens, 6)
        XCTAssertEqual(parsed.usage?.costUSDMicros, 12_345)
        XCTAssertEqual(parsed.usageSequence, 1)
        XCTAssertEqual(parsed.sourceOffset, 2)
        XCTAssertEqual(parsed.rawMeta, ["source": "omp"])
        XCTAssertFalse(parsed.rawMeta.values.contains { $0.contains("SECRET_OMP_RESPONSE") })
    }

    func testParsesSnakeCaseUsageAndTopLevelCost() throws {
        let lines = [
            JSONLLine(text: #"{"type":"session","sessionId":"omp-session-2","cwd":"/repo","timestamp":"2026-07-03T03:00:00Z"}"#, offset: 0, nextOffset: 1),
            JSONLLine(text: #"{"type":"message","timestamp":"2026-07-03T03:01:00Z","message":{"usage":{"input_tokens":"10","output_tokens":20,"reasoning_tokens":"3","cache_read_tokens":4,"cache_write_tokens":5,"cost":0.000123},"content":"SECRET"}}"#, offset: 1, nextOffset: 2)
        ]

        let parsed = try OmpSessionParser().parse(lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/omp.jsonl"))

        XCTAssertEqual(parsed.sessionKey, "omp-session-2")
        XCTAssertEqual(parsed.usage?.inputTokens, 10)
        XCTAssertEqual(parsed.usage?.outputTokens, 20)
        XCTAssertEqual(parsed.usage?.reasoningTokens, 3)
        XCTAssertEqual(parsed.usage?.cacheReadTokens, 4)
        XCTAssertEqual(parsed.usage?.cacheWriteTokens, 5)
        XCTAssertEqual(parsed.usage?.costUSDMicros, 123)
    }

    func testUsesTotalTokensAsInputFallbackWhenUsageHasNoBreakdown() throws {
        let lines = [
            JSONLLine(text: #"{"type":"session","id":"omp-total","cwd":"/repo"}"#, offset: 0, nextOffset: 1),
            JSONLLine(text: #"{"type":"message","message":{"usage":{"totalTokens":99}}}"#, offset: 1, nextOffset: 2)
        ]

        let parsed = try OmpSessionParser().parse(lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/omp.jsonl"))

        XCTAssertEqual(parsed.usage?.inputTokens, 99)
        XCTAssertNil(parsed.usage?.outputTokens)
        XCTAssertEqual(parsed.usageSequence, 1)
    }

    func testSkipsMalformedAndNonUsageLinesAndParsesFractionalTimestamps() throws {
        let lines = [
            JSONLLine(text: #"{"type":"session","id":"omp-time","cwd":"/repo","timestamp":"2026-05-13T09:00:00.000Z"}"#, offset: 0, nextOffset: 1),
            JSONLLine(text: #"not json"#, offset: 1, nextOffset: 2),
            JSONLLine(text: #"{"type":"message","timestamp":"2026-05-13T09:01:02.123Z","message":{"content":"SECRET_NO_USAGE"}}"#, offset: 2, nextOffset: 3),
            JSONLLine(text: #"{"type":"message","timestamp":"2026-05-13T09:02:03.456Z","message":{"content":"SECRET_WITH_USAGE","usage":{"inputTokens":3,"outputTokens":4}}}"#, offset: 3, nextOffset: 4)
        ]

        let parsed = try OmpSessionParser().parse(lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/omp.jsonl"))

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(parsed.startedAt, formatter.date(from: "2026-05-13T09:00:00.000Z"))
        XCTAssertEqual(parsed.updatedAt, formatter.date(from: "2026-05-13T09:02:03.456Z"))
        XCTAssertEqual(parsed.usage?.inputTokens, 3)
        XCTAssertEqual(parsed.usage?.outputTokens, 4)
        XCTAssertEqual(parsed.usageSequence, 1)
        XCTAssertEqual(parsed.sourceOffset, 3)
        XCTAssertFalse(parsed.rawMeta.values.contains { $0.contains("SECRET_NO_USAGE") || $0.contains("SECRET_WITH_USAGE") })
    }

    func testFallsBackToSourceFileNameWhenSessionEventOmitsId() throws {
        let lines = [
            JSONLLine(text: #"{"type":"model_change","model":"gpt-5.5"}"#, offset: 0, nextOffset: 1),
            JSONLLine(text: #"{"type":"message","message":{"usage":{"inputTokens":1,"outputTokens":2}}}"#, offset: 1, nextOffset: 2)
        ]

        let parsed = try OmpSessionParser().parse(lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/omp-session-from-path.jsonl"))

        XCTAssertEqual(parsed.sessionKey, "omp-session-from-path")
        XCTAssertEqual(parsed.modelName, "gpt-5.5")
    }
}
