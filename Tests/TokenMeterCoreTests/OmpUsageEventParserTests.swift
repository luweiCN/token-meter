import XCTest
@testable import TokenMeterCore

final class OmpUsageEventParserTests: XCTestCase {
    private func line(_ text: String, offset: Int64) -> JSONLLine {
        JSONLLine(text: text, offset: offset, nextOffset: offset + 1)
    }

    private let meta = #"{"type":"session","version":3,"id":"omp-1","timestamp":"2026-07-08T01:00:00Z","cwd":"/repo","title":"t","titleSource":"auto"}"#

    func testDoesNotSubtractCacheFromInput() throws {
        // omp: total = input + output + cacheRead。cache 独立于 input，
        // 与 Codex 正好相反。照抄 Codex 的减法会把 input 减成负数再截断到 0。
        let lines = [
            line(meta, offset: 0),
            line(#"{"type":"message","id":"m1","timestamp":"2026-07-08T01:05:00Z","message":{"role":"assistant","provider":"openai-codex","model":"gpt-5.5","usage":{"input":1000,"output":50,"cacheRead":900,"cacheWrite":0,"reasoningTokens":10,"totalTokens":1950,"cost":{"total":0.5}}}}"#, offset: 1)
        ]

        let (session, _) = try OmpUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/o.jsonl"), resuming: nil
        )

        XCTAssertEqual(session.events.count, 1)
        let event = session.events[0]
        XCTAssertEqual(event.inputTokens, 1000, "omp 的 input 不含 cache，不得做减法")
        XCTAssertEqual(event.cacheReadTokens, 900)
        XCTAssertEqual(event.outputTokens, 50)
        XCTAssertEqual(event.reasoningTokens, 10)
        XCTAssertEqual(event.totalTokens, 1950)
        XCTAssertNil(event.dedupeKey)
        XCTAssertEqual(event.modelName, "gpt-5.5")
    }

    func testReasoningIsNotAddedToTotal() throws {
        let lines = [
            line(meta, offset: 0),
            line(#"{"type":"message","id":"m1","timestamp":"2026-07-08T01:05:00Z","message":{"role":"assistant","model":"m","usage":{"input":100,"output":80,"reasoningTokens":60}}}"#, offset: 1)
        ]

        let (session, _) = try OmpUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/o.jsonl"), resuming: nil
        )

        // reasoning 是 output 的子集：100 + 80 = 180，不是 240
        XCTAssertEqual(session.events[0].totalTokens, 180)
        XCTAssertEqual(session.events[0].reasoningTokens, 60)
    }

    func testUsesReportedCostWhenPositive() throws {
        let lines = [
            line(meta, offset: 0),
            line(#"{"type":"message","id":"m1","timestamp":"2026-07-08T01:05:00Z","message":{"role":"assistant","model":"gpt-5.5","usage":{"input":10,"output":1,"cost":{"total":0.19055}}}}"#, offset: 1)
        ]

        let (session, _) = try OmpUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/o.jsonl"), resuming: nil
        )

        // 0.19055 USD -> 190550 micros
        XCTAssertEqual(session.events[0].reportedCostUSDMicros, 190_550)
    }

    func testZeroCostFallsThroughToComputed() throws {
        // cost == 0 说明 omp 不知道单价（套餐制），交给 CostCalculator 自算。
        // 存 0 会让它看起来像一个事实。
        let lines = [
            line(meta, offset: 0),
            line(#"{"type":"message","id":"m1","timestamp":"2026-07-08T01:05:00Z","message":{"role":"assistant","model":"gpt-5.5","usage":{"input":10,"output":1,"cost":{"total":0}}}}"#, offset: 1)
        ]

        let (session, _) = try OmpUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/o.jsonl"), resuming: nil
        )

        XCTAssertNil(session.events[0].reportedCostUSDMicros)
    }

    func testCacheWriteGoesToFiveMinuteTier() throws {
        let lines = [
            line(meta, offset: 0),
            line(#"{"type":"message","id":"m1","timestamp":"2026-07-08T01:05:00Z","message":{"role":"assistant","model":"m","usage":{"input":1,"cacheWrite":300}}}"#, offset: 1)
        ]

        let (session, _) = try OmpUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/o.jsonl"), resuming: nil
        )

        XCTAssertEqual(session.events[0].cacheWrite5mTokens, 300)
        XCTAssertEqual(session.events[0].cacheWrite1hTokens, 0)
    }

    func testSkipsMessagesWithoutAnyTokens() throws {
        let lines = [
            line(meta, offset: 0),
            line(#"{"type":"message","id":"m1","timestamp":"2026-07-08T01:05:00Z","message":{"role":"assistant","model":"m","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0}}}"#, offset: 1)
        ]

        let (session, _) = try OmpUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/o.jsonl"), resuming: nil
        )

        XCTAssertTrue(session.events.isEmpty)
    }

    func testExtractsSessionIdAndProjectPathFromSessionLine() throws {
        // 真实 omp 用 "type":"session"。若只匹配 "session_meta"，
        // sessionKey 会回落到文件名、projectPath 会永远是 nil，
        // omp 的用量就无法归属任何项目——而且没有任何测试会红。
        let lines = [
            line(meta, offset: 0),
            line(#"{"type":"message","id":"m1","timestamp":"2026-07-08T01:05:00Z","message":{"role":"assistant","model":"m","usage":{"input":1}}}"#, offset: 1)
        ]

        let (session, _) = try OmpUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/should-not-be-used.jsonl"), resuming: nil
        )

        XCTAssertEqual(session.sessionKey, "omp-1", "必须用 session 行的 id，而不是文件名")
        XCTAssertEqual(session.projectPath, "/repo", "必须从 session 行的 cwd 取项目路径")
    }

    func testSessionInitDoesNotClobberTheSessionId() throws {
        // 943/1002 个真实 omp 文件是子 agent 文件：先一行 session（UUID + cwd），
        // 再一行 session_init（8 位短 spawn id、无 cwd）。若两者共用一个 case 分支，
        // 后者会把 sessionKey 从 UUID 覆盖成短串。
        let lines = [
            line(#"{"type":"session","version":3,"id":"019f247b-3a29-7000-9fcd-9677ee2fec1e","timestamp":"2026-07-08T01:00:00Z","cwd":"/repo"}"#, offset: 0),
            line(#"{"type":"session_init","id":"8baf4900"}"#, offset: 1),
            line(#"{"type":"message","id":"m1","timestamp":"2026-07-08T01:05:00Z","message":{"role":"assistant","model":"m","usage":{"input":1}}}"#, offset: 2)
        ]

        let (session, _) = try OmpUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/o.jsonl"), resuming: nil
        )

        XCTAssertEqual(session.sessionKey, "019f247b-3a29-7000-9fcd-9677ee2fec1e",
                       "session_init 的短 spawn id 不得覆盖 session 行的 UUID")
        XCTAssertEqual(session.projectPath, "/repo")
    }

    func testFallsBackToFileNameForSessionKey() throws {
        let lines = [
            line(#"{"type":"message","id":"m1","timestamp":"2026-07-08T01:05:00Z","message":{"role":"assistant","model":"m","usage":{"input":1}}}"#, offset: 0)
        ]

        let (session, _) = try OmpUsageEventParser.parse(
            lines: lines,
            sourceURL: URL(fileURLWithPath: "/tmp/2026-07-01T11-20-18-498Z_019f1d68.jsonl"),
            resuming: nil
        )

        XCTAssertEqual(session.sessionKey, "2026-07-01T11-20-18-498Z_019f1d68")
    }

    func testResumingContinuesEventSeq() throws {
        let lines = [
            line(meta, offset: 0),
            line(#"{"type":"message","id":"m1","timestamp":"2026-07-08T01:05:00Z","message":{"role":"assistant","model":"m","usage":{"input":1}}}"#, offset: 42)
        ]

        let (session, state) = try OmpUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/o.jsonl"), resuming: ParserState(lastEventSeq: 3)
        )

        XCTAssertEqual(session.events[0].eventSeq, 4)
        XCTAssertEqual(session.events[0].sourceOffset, 42)
        XCTAssertEqual(state.lastEventSeq, 4)
    }
}
