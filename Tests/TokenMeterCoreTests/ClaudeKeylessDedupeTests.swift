import XCTest
@testable import TokenMeterCore

/// Task 14e：Claude 的去重指纹改为 messageId 本身（requestId 不参与）。
/// 这些用例走真实 parser + deduplicator，红/绿由 parser 的 dedupeKey 变化驱动。
final class ClaudeKeylessDedupeTests: XCTestCase {
    private func line(_ text: String, offset: Int64) -> JSONLLine {
        JSONLLine(text: text, offset: offset, nextOffset: offset + 1)
    }

    private func deduped(_ jsonl: [String]) throws -> [UsageEvent] {
        let lines = jsonl.enumerated().map { line($0.element, offset: Int64($0.offset)) }
        let (session, _) = try ClaudeCodeUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/x.jsonl"), resuming: nil
        )
        return UsageEventDeduplicator.deduplicate(session.events)
    }

    /// 测试 1：同一 messageId 出现两次，一次带 requestId、一次不带（同 session）。
    /// 一条 assistant 响应只应计一次。旧代码把不带 requestId 的那条给了 nil 指纹、彻底
    /// 绕过去重 → 计两次（红）。改为 messageId 指纹后 → 计一次（绿）。
    func testSameMessageIdWithAndWithoutRequestIdCountsOnce() throws {
        let events = try deduped([
            #"{"type":"assistant","timestamp":"2026-07-08T01:00:00Z","sessionId":"s1","requestId":"req-1","message":{"id":"m1","role":"assistant","model":"m","usage":{"input_tokens":10,"output_tokens":5}}}"#,
            #"{"type":"assistant","timestamp":"2026-07-08T01:00:01Z","sessionId":"s1","isSidechain":true,"message":{"id":"m1","role":"assistant","model":"m","usage":{"input_tokens":10,"output_tokens":5}}}"#
        ])
        XCTAssertEqual(events.count, 1, "同一 messageId=一次 API 计费，只能算一条；缺 requestId 的那份不得绕过去重")
        XCTAssertEqual(events.reduce(Int64(0)) { $0 + $1.totalTokens }, 15)
    }

    /// 测试 2：子 agent（sidechain）自己的响应是真实消耗，其 messageId 不在任何其他文件里
    /// 出现（见 finding 3），必须原样保留。这是对"灾难版修复"（把子 agent 用量并进父级）的守卫。
    func testGenuineSubagentUsageIsRetainedInFull() throws {
        // 真实情形：sidechain 事件的 messageId 独一无二 + 一条不同 messageId 的主链事件 → 两条都在。
        let events = try deduped([
            #"{"type":"assistant","timestamp":"2026-07-08T01:00:00Z","sessionId":"s1","requestId":"r-main","message":{"id":"m-main","role":"assistant","model":"m","usage":{"input_tokens":100,"output_tokens":10}}}"#,
            #"{"type":"assistant","timestamp":"2026-07-08T01:00:02Z","sessionId":"s1","isSidechain":true,"message":{"id":"m-sub","role":"assistant","model":"m","usage":{"input_tokens":7,"cache_read_input_tokens":3000}}}"#
        ])
        XCTAssertEqual(events.count, 2, "不同 messageId 不得合并——子 agent 用量必须保留")
        let sidechain = events.first { $0.isSidechain }
        XCTAssertEqual(sidechain?.totalTokens, 3007, "子 agent 事件必须带全额 token")

        // 露牙：若两条真的撞上同一 dedupeKey（一 main 一 sidechain），deduplicator 会把它们
        // 合成一条——子 agent 用量就被吞掉。finding 3 证明真实语料里 messageId 绝不跨越
        // main/sidechain 边界，所以上面的"保留"不是空断言：撞 key 的确会塌缩。
        let collapsed = UsageEventDeduplicator.deduplicate([
            UsageEvent(eventSeq: 1, observedAt: Date(timeIntervalSince1970: 100),
                       messageId: "shared", dedupeKey: "shared", inputTokens: 100, sourceOffset: 0, isSidechain: false),
            UsageEvent(eventSeq: 2, observedAt: Date(timeIntervalSince1970: 200),
                       messageId: "shared", dedupeKey: "shared", inputTokens: 999, sourceOffset: 1, isSidechain: true)
        ])
        XCTAssertEqual(collapsed.count, 1, "撞 key 会塌缩——正因如此，保留独立 messageId 才有意义")
    }

    /// 测试 3：同 session 内两个不同 messageId、同一时间戳 —— 两条都要计。
    /// 守护"修复不会过度合并"：messageId 不同就是不同响应。
    func testDistinctMessageIdsAtSameTimestampBothSurvive() throws {
        let events = try deduped([
            #"{"type":"assistant","timestamp":"2026-07-08T01:00:00Z","sessionId":"s1","requestId":"r1","message":{"id":"m1","role":"assistant","model":"m","usage":{"input_tokens":10,"output_tokens":1}}}"#,
            #"{"type":"assistant","timestamp":"2026-07-08T01:00:00Z","sessionId":"s1","requestId":"r2","message":{"id":"m2","role":"assistant","model":"m","usage":{"input_tokens":20,"output_tokens":2}}}"#
        ])
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(Set(events.map(\.messageId)), ["m1", "m2"])
    }
}
