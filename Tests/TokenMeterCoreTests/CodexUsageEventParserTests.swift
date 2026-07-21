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

    func testCumulativeResetWithoutLastUsageMovesBaselineWithoutChargingSnapshot() throws {
        // 只有 total、没有 last 时，累计值回退既可能是 compact，也可能是乱序旧快照。
        // 保守口径：回退行只移动基线、不直接计费；下一条从新基线正常做差。
        let lines = [
            line(meta, offset: 0),
            line(#"{"type":"event_msg","timestamp":"2026-07-08T01:05:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500,"cached_input_tokens":100,"output_tokens":50}}}}"#, offset: 1),
            line(#"{"type":"event_msg","timestamp":"2026-07-08T01:06:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":80,"cached_input_tokens":20,"output_tokens":10}}}}"#, offset: 2),
            line(#"{"type":"event_msg","timestamp":"2026-07-08T01:07:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":25,"output_tokens":14}}}}"#, offset: 3)
        ]

        let (session, _) = try CodexUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/c.jsonl"), resuming: nil
        )

        XCTAssertEqual(session.events.count, 2)
        XCTAssertEqual(session.events[1].inputTokens, 15)   // Δinput 20 - Δcache 5
        XCTAssertEqual(session.events[1].cacheReadTokens, 5)
        XCTAssertEqual(session.events[1].outputTokens, 4)
    }

    func testBuffersModelLessUsageUntilLaterTurnContext() throws {
        let lines = [
            line(meta, offset: 0),
            line(#"{"type":"event_msg","timestamp":"2026-07-08T01:05:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":3},"last_token_usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":3}}}}"#, offset: 1),
            line(#"{"type":"turn_context","payload":{"model_info":{"slug":"gpt-5.6-sol"}}}"#, offset: 2)
        ]

        let (session, state) = try CodexUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/c.jsonl"), resuming: nil
        )

        XCTAssertEqual(session.events.count, 1)
        XCTAssertEqual(session.events[0].modelName, "gpt-5.6-sol")
        XCTAssertFalse(state.requiresFullReplay ?? false)
    }

    func testUnresolvedModelRequestsFullReplayOnNextAppend() throws {
        let lines = [
            line(meta, offset: 0),
            line(#"{"type":"event_msg","timestamp":"2026-07-08T01:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"output_tokens":3}}}}"#, offset: 1)
        ]

        let (session, state) = try CodexUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/c.jsonl"), resuming: nil
        )

        XCTAssertNil(session.events[0].modelName)
        XCTAssertEqual(state.requiresFullReplay, true)
    }

    func testForkedChildSkipsInheritedReplayAndPostContextBaseline() throws {
        let lines = [
            line(#"{"type":"session_meta","timestamp":"2026-07-08T01:00:00Z","payload":{"id":"019f8178-5e10-7000-8000-000000000001","forked_from_id":"019f54c2-0000-7000-8000-000000000001","cwd":"/child","source":{"subagent":{"thread_spawn":{"parent_thread_id":"019f54c2-0000-7000-8000-000000000001","agent_role":"worker"}}}}}"#, offset: 0),
            line(#"{"type":"session_meta","timestamp":"2026-07-08T01:00:01Z","payload":{"id":"019f54c2-0000-7000-8000-000000000001","cwd":"/parent"}}"#, offset: 1),
            line(#"{"type":"turn_context","payload":{"turn_id":"019f54c2-1000-7000-8000-000000000001","model":"gpt-parent"}}"#, offset: 2),
            line(#"{"type":"event_msg","timestamp":"2026-07-08T01:00:02Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":116000,"cached_input_tokens":114000,"output_tokens":1000,"total_tokens":117000},"last_token_usage":{"input_tokens":73000,"cached_input_tokens":72000,"output_tokens":500}}}}"#, offset: 3),
            line(#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"019f8178-5e10-7000-8000-000000000002","started_at":1783472400}}"#, offset: 4),
            line(#"{"type":"turn_context","payload":{"turn_id":"019f8178-5e10-7000-8000-000000000002","model":"gpt-5.6-sol","cwd":"/child"}}"#, offset: 5),
            // Codex 可能在首个 child context 后再写一次继承快照；仍应跳过。
            line(#"{"type":"event_msg","timestamp":"2026-07-08T01:00:03Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":116000,"cached_input_tokens":114000,"output_tokens":1000,"total_tokens":117000},"last_token_usage":{"input_tokens":73000,"cached_input_tokens":72000,"output_tokens":500}}}}"#, offset: 6),
            line(#"{"type":"event_msg","timestamp":"2026-07-08T01:00:04Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":117500,"cached_input_tokens":115000,"output_tokens":1200,"reasoning_output_tokens":50,"total_tokens":118700},"last_token_usage":{"input_tokens":1500,"cached_input_tokens":1000,"output_tokens":200,"reasoning_output_tokens":50}}}}"#, offset: 7)
        ]

        let (session, state) = try CodexUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/child.jsonl"), resuming: nil
        )

        XCTAssertEqual(session.sessionKey, "019f8178-5e10-7000-8000-000000000001")
        XCTAssertEqual(session.rootSessionKey, "019f54c2-0000-7000-8000-000000000001")
        XCTAssertEqual(session.events.count, 1, "父历史与继承基线都不得落成 child 用量")
        XCTAssertEqual(session.events[0].modelName, "gpt-5.6-sol")
        XCTAssertEqual(session.events[0].inputTokens, 500)
        XCTAssertEqual(session.events[0].cacheReadTokens, 1_000)
        XCTAssertEqual(session.events[0].outputTokens, 200)
        XCTAssertEqual(session.events[0].dedupeScopeKey, "codex:019f54c2-0000-7000-8000-000000000001")
        XCTAssertEqual(state.codexWaitingForTurnContext, false)
    }

    func testRepeatedChildSessionMetaDoesNotReopenReplayGate() throws {
        let childMeta = #"{"type":"session_meta","payload":{"id":"019f8178-5e10-7000-8000-000000000001","forked_from_id":"parent","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent"}}}}}"#
        let lines = [
            line(childMeta, offset: 0),
            line(#"{"type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#, offset: 1),
            line(childMeta, offset: 2),
            line(#"{"type":"event_msg","timestamp":"2026-07-08T01:00:04Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"output_tokens":2},"last_token_usage":{"input_tokens":10,"output_tokens":2}}}}"#, offset: 3)
        ]

        let (session, _) = try CodexUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/child.jsonl"), resuming: nil
        )

        XCTAssertEqual(session.events.count, 1)
    }

    func testReadsModelAndCacheAliasesAndClampsMalformedUsage() throws {
        let lines = [
            line(meta, offset: 0),
            line(#"{"type":"event_msg","timestamp":"2026-07-08T01:05:00Z","payload":{"type":"token_count","model_name":"gpt-5.6-sol","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":2,"cache_read_input_tokens":20,"output_tokens":-3,"reasoning_output_tokens":-1}}}}"#, offset: 1)
        ]

        let (session, _) = try CodexUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/c.jsonl"), resuming: nil
        )

        XCTAssertEqual(session.events.count, 1)
        XCTAssertEqual(session.events[0].modelName, "gpt-5.6-sol")
        XCTAssertEqual(session.events[0].inputTokens, 0)
        XCTAssertEqual(session.events[0].cacheReadTokens, 10, "cache 不得超过原始 input")
        XCTAssertEqual(session.events[0].outputTokens, 0)
        XCTAssertEqual(session.events[0].reasoningTokens, 0)
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

    func testDedupeKeyFallsBackToTimestampWhenTotalsMissing() throws {
        // 没有 total_token_usage 的事件退回旧指纹：timestamp + 原始四元组。
        // （真实数据里 token_count 都带 total；这是防御性回退。）
        let lines = [
            line(meta, offset: 0),
            line(#"{"type":"event_msg","timestamp":"2026-07-08T01:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"output_tokens":1}}}}"#, offset: 1)
        ]

        let (session, _) = try CodexUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/c.jsonl"), resuming: nil
        )

        let event = session.events[0]
        XCTAssertEqual(
            event.dedupeKey,
            "last\u{1F}unknown\u{1F}\(event.observedEpochMilliseconds)\u{1F}10\u{1F}0\u{1F}1\u{1F}0",
            "回退指纹 = 类型 + 模型 + 毫秒时间戳 + 原始四元组"
        )
        XCTAssertEqual(event.sourceOffset, 1)
    }

    func testReplayedRowsWithRewrittenTimestampShareTheDedupeKey() throws {
        // Codex resume/fork 会把整段历史重放进新 rollout 文件：payload（含
        // total_token_usage）逐字节相同，但外层 timestamp 会被刷成 resume 那一刻。
        // 实测 2026-07-13：一个会话被 resume 6 次 → 历史被计 7 遍、虚增 18 亿 token。
        // 指纹必须锚在 total 四元组上（重放不变量），不能锚在 timestamp 上。
        let original = #"{"type":"event_msg","timestamp":"2026-07-13T10:06:20.704Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20065,"cached_input_tokens":9984,"output_tokens":334,"reasoning_output_tokens":181,"total_tokens":20399},"last_token_usage":{"input_tokens":20065,"cached_input_tokens":9984,"output_tokens":334,"reasoning_output_tokens":181,"total_tokens":20399}}}}"#
        let replayed = original.replacingOccurrences(of: "2026-07-13T10:06:20.704Z", with: "2026-07-13T10:08:00.899Z")

        let (sessionA, _) = try CodexUsageEventParser.parse(
            lines: [line(meta, offset: 0), line(original, offset: 1)],
            sourceURL: URL(fileURLWithPath: "/tmp/a.jsonl"), resuming: nil
        )
        let (sessionB, _) = try CodexUsageEventParser.parse(
            lines: [line(meta, offset: 0), line(replayed, offset: 1)],
            sourceURL: URL(fileURLWithPath: "/tmp/b.jsonl"), resuming: nil
        )

        XCTAssertNotNil(sessionA.events[0].dedupeKey)
        XCTAssertEqual(
            sessionA.events[0].dedupeKey, sessionB.events[0].dedupeKey,
            "重放行（payload 相同、timestamp 被改写）必须撞上同一指纹，否则每 resume 一次历史就被重计一遍"
        )
    }

    func testDistinctRealEventsInOneSessionGetDistinctDedupeKeys() throws {
        // 同一会话里两个真实事件：累计 total 严格递增（入库前提是 Δinput>0 或
        // Δoutput>0），所以 total 四元组必不同——真实用量不会被误去重。
        let lines = [
            line(meta, offset: 0),
            line(#"{"type":"event_msg","timestamp":"2026-07-08T01:05:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":20},"last_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":20}}}}"#, offset: 1),
            line(#"{"type":"event_msg","timestamp":"2026-07-08T01:05:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":60,"output_tokens":30},"last_token_usage":{"input_tokens":50,"cached_input_tokens":20,"output_tokens":10}}}}"#, offset: 2)
        ]

        let (session, _) = try CodexUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/c.jsonl"), resuming: nil
        )

        XCTAssertEqual(session.events.count, 2)
        XCTAssertNotEqual(
            session.events[0].dedupeKey, session.events[1].dedupeKey,
            "同一时间戳下的两个真实事件也必须有不同指纹（total 递增保证）"
        )
    }

    func testFlagsSubagentSessionFromParentThreadId() throws {
        let subMeta = #"{"type":"session_meta","payload":{"id":"child-1","cwd":"/repo","parent_thread_id":"parent-1","agent_role":"worker","agent_nickname":"swift-otter"}}"#
        let lines = [
            line(subMeta, offset: 0),
            line(turnContext, offset: 1),
            line(#"{"type":"event_msg","timestamp":"2026-07-08T01:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5}}}}"#, offset: 2)
        ]
        let (session, _) = try CodexUsageEventParser.parse(lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/c.jsonl"), resuming: nil)

        XCTAssertEqual(session.rootSessionKey, "parent-1")
        XCTAssertEqual(session.subagentLabel, "worker · swift-otter")
        XCTAssertTrue(session.events.allSatisfy { $0.isSidechain }, "子代理会话的事件应全部标为 sidechain")
    }

    func testFlagsSubagentSessionFromNestedThreadSpawnShape() throws {
        let subMeta = #"{"type":"session_meta","payload":{"id":"child-2","cwd":"/repo","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent-2","agent_role":"explorer","agent_nickname":"deep-fox"}}}}}"#
        let lines = [
            line(subMeta, offset: 0),
            line(turnContext, offset: 1),
            line(#"{"type":"event_msg","timestamp":"2026-07-08T01:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5}}}}"#, offset: 2)
        ]
        let (session, _) = try CodexUsageEventParser.parse(lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/c.jsonl"), resuming: nil)
        XCTAssertEqual(session.rootSessionKey, "parent-2")
        XCTAssertEqual(session.subagentLabel, "explorer · deep-fox")
        XCTAssertTrue(session.events.allSatisfy { $0.isSidechain })
    }

    func testMainSessionHasNoRootAndNoSidechain() throws {
        let lines = [
            line(meta, offset: 0),
            line(turnContext, offset: 1),
            line(#"{"type":"event_msg","timestamp":"2026-07-08T01:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5}}}}"#, offset: 2)
        ]
        let (session, _) = try CodexUsageEventParser.parse(lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/c.jsonl"), resuming: nil)

        XCTAssertNil(session.rootSessionKey)
        XCTAssertNil(session.subagentLabel)
        XCTAssertTrue(session.events.allSatisfy { !$0.isSidechain })
    }

    func testSubagentFlagSurvivesResume() throws {
        let firstMeta = #"{"type":"session_meta","payload":{"id":"child-1","parent_thread_id":"parent-1","agent_role":"explorer","agent_nickname":"n"}}"#
        let (_, state) = try CodexUsageEventParser.parse(
            lines: [line(firstMeta, offset: 0), line(turnContext, offset: 1)],
            sourceURL: URL(fileURLWithPath: "/tmp/c.jsonl"), resuming: nil
        )
        let (session, _) = try CodexUsageEventParser.parse(
            lines: [line(#"{"type":"event_msg","timestamp":"2026-07-08T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":3,"cached_input_tokens":0,"output_tokens":1}}}}"#, offset: 2)],
            sourceURL: URL(fileURLWithPath: "/tmp/c.jsonl"), resuming: state
        )
        XCTAssertEqual(session.rootSessionKey, "parent-1")
        XCTAssertEqual(session.subagentLabel, "explorer · n")
        XCTAssertTrue(session.events.allSatisfy { $0.isSidechain })
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
