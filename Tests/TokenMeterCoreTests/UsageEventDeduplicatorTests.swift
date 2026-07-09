import XCTest
@testable import TokenMeterCore

final class UsageEventDeduplicatorTests: XCTestCase {
    private func event(
        seq: Int,
        at seconds: TimeInterval,
        messageId: String?,
        requestId: String?,
        input: Int64 = 1,
        output: Int64 = 0,
        isSidechain: Bool = false
    ) -> UsageEvent {
        UsageEvent(
            eventSeq: seq,
            observedAt: Date(timeIntervalSince1970: seconds),
            messageId: messageId,
            // dedupeKey 现由构造者提供；这里用 requestId 合成一个「同 messageId、不同 dedupeKey」
            // 的指纹，专为驱动规则二（byMessageId）——UsageEvent 本身已不再存 requestId。
            dedupeKey: messageId.flatMap { messageId in requestId.map { "\(messageId)\u{1F}\($0)" } },
            inputTokens: input,
            outputTokens: output,
            sourceOffset: Int64(seq),
            isSidechain: isSidechain
        )
    }

    func testKeepsEarliestOnExactKeyCollision() {
        let later = event(seq: 1, at: 200, messageId: "m1", requestId: "r1")
        let earlier = event(seq: 2, at: 100, messageId: "m1", requestId: "r1")

        let result = UsageEventDeduplicator.deduplicate([later, earlier])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].observedAt, Date(timeIntervalSince1970: 100))
    }

    func testKeepsLargestTotalFrameOfStreamedResponse() {
        // 同一次 API 调用（同 messageId+requestId，故 dedupeKey 相同）在流式过程中被多次
        // 落盘，output 单调增长：4 → 4 → 559。保留最早那条会记下最不完整的一帧（4），
        // 少算 output。规则一必须保留 tokensTotal 最大的那条（= 最终帧 559）。
        let frame1 = event(seq: 1, at: 100, messageId: "m1", requestId: "r1", output: 4)
        let frame2 = event(seq: 2, at: 200, messageId: "m1", requestId: "r1", output: 4)
        let frame3 = event(seq: 3, at: 300, messageId: "m1", requestId: "r1", output: 559)

        let result = UsageEventDeduplicator.deduplicate([frame1, frame2, frame3])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].outputTokens, 559)
    }

    func testExactCopiesCollapseToOneDeterministically() {
        // resume/fork 的逐字节副本：同 dedupeKey、所有 token 字段与时间都相等，只 eventSeq 不同。
        // 总量并列 → 时间并列 → 由 eventSeq 决出确定胜者（最小），结果恒为一条、且可重现。
        let copyA = event(seq: 3, at: 100, messageId: "m1", requestId: "r1", input: 10, output: 20)
        let copyB = event(seq: 1, at: 100, messageId: "m1", requestId: "r1", input: 10, output: 20)
        let copyC = event(seq: 2, at: 100, messageId: "m1", requestId: "r1", input: 10, output: 20)

        let result = UsageEventDeduplicator.deduplicate([copyA, copyB, copyC])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].eventSeq, 1)
        XCTAssertEqual(result[0].outputTokens, 20)
    }

    func testTotalOrderIsLoadBearingAtEveryLevel() {
        // 规则一的三级全序都必须在场，缺一级就会挑错 winner。所有事件同 dedupeKey，故都在
        // 规则一（byExactKey）里碰撞。输入刻意乱序，把并列的高 seq 帧排在最小 seq 之前，
        // 好让「删掉 eventSeq 级」这类退化在单次运行里就确定地失败。
        //
        // 预期 winner W：total=100、obs=10、seq=2。
        //   L1（total=50、obs=1、seq=9）  ：总量最小但时间最早——删掉「总量」级它就靠最早时间夺冠。
        //   L2（total=100、obs=20、seq=1）：总量并列但时间更晚、seq 最小——删掉「时间」级它就靠最小 seq 夺冠。
        //   L3a/L3b（total=100、obs=10、seq=5/7）：与 W 总量、时间都并列、seq 更大——
        //     删掉「eventSeq」级，且它们排在 W 之前，就会把先到的高 seq 帧留下。
        let w = event(seq: 2, at: 10, messageId: "m1", requestId: "r1", input: 100)
        let l1 = event(seq: 9, at: 1, messageId: "m1", requestId: "r1", input: 50)
        let l2 = event(seq: 1, at: 20, messageId: "m1", requestId: "r1", input: 100)
        let l3a = event(seq: 5, at: 10, messageId: "m1", requestId: "r1", input: 100)
        let l3b = event(seq: 7, at: 10, messageId: "m1", requestId: "r1", input: 100)

        // 乱序输入：L3a/L3b 在 W 之前，L1/L2 穿插其中。
        let result = UsageEventDeduplicator.deduplicate([l3a, l3b, l2, l1, w])

        XCTAssertEqual(result.count, 1)
        // 总量级：winner 总量必须是 100（否则 L1 的 50 会冒头）。
        XCTAssertEqual(result[0].totalTokens, 100)
        // 时间级：winner 时间必须是 10（否则 L2 的 20 会冒头）。
        XCTAssertEqual(result[0].observedAt, Date(timeIntervalSince1970: 10))
        // eventSeq 级：winner seq 必须是 2（否则先到的 L3a/L3b 会被留下）。
        XCTAssertEqual(result[0].eventSeq, 2)
    }

    func testDropsSidechainReplayOfSameMessageId() {
        // 同一条 message 被 sidechain 用新的 requestId 重放，必须丢弃重放副本
        let original = event(seq: 1, at: 100, messageId: "m1", requestId: "r1", isSidechain: false)
        let replay = event(seq: 2, at: 150, messageId: "m1", requestId: "r2", isSidechain: true)

        let result = UsageEventDeduplicator.deduplicate([original, replay])

        XCTAssertEqual(result.count, 1)
        XCTAssertFalse(result[0].isSidechain)
        XCTAssertEqual(result[0].eventSeq, 1) // 原件（seq 1）胜出，重放副本（seq 2）被丢弃
    }

    func testNonSidechainWinsEvenWhenSidechainIsEarlier() {
        // 非 sidechain 是原件，sidechain 是副本。原件胜出，与时间无关。
        let earlierSidechain = event(seq: 1, at: 100, messageId: "m1", requestId: "r1", isSidechain: true)
        let laterOriginal = event(seq: 2, at: 300, messageId: "m1", requestId: "r2", isSidechain: false)

        let result = UsageEventDeduplicator.deduplicate([earlierSidechain, laterOriginal])

        XCTAssertEqual(result.count, 1)
        XCTAssertFalse(result[0].isSidechain)
        XCTAssertEqual(result[0].observedAt, Date(timeIntervalSince1970: 300))
    }

    func testKeepsGenuineSidechainEventWithDistinctMessageId() {
        // 子 agent 自己的 API 响应是真实消耗，必须保留
        let parent = event(seq: 1, at: 100, messageId: "m1", requestId: "r1", isSidechain: false)
        let subagent = event(seq: 2, at: 150, messageId: "m2", requestId: "r2", isSidechain: true)

        let result = UsageEventDeduplicator.deduplicate([parent, subagent])

        XCTAssertEqual(result.count, 2)
    }

    func testKeepsAllEventsWithoutDedupeKey() {
        // Codex 没有 messageId，靠 sourceOffset 天然唯一，不参与去重
        let a = event(seq: 1, at: 100, messageId: nil, requestId: nil)
        let b = event(seq: 2, at: 200, messageId: nil, requestId: nil)

        XCTAssertEqual(UsageEventDeduplicator.deduplicate([a, b]).count, 2)
    }

    func testKeepsEventWithOnlyOneOfTheTwoIds() {
        // dedupeKey 需要两个 id 都在。只有一个时不参与去重。
        let a = event(seq: 1, at: 100, messageId: "m1", requestId: nil)
        let b = event(seq: 2, at: 200, messageId: "m1", requestId: nil)

        XCTAssertEqual(UsageEventDeduplicator.deduplicate([a, b]).count, 2)
    }

    func testPreservesEventSeqOrder() {
        let a = event(seq: 3, at: 300, messageId: "m3", requestId: "r3")
        let b = event(seq: 1, at: 100, messageId: "m1", requestId: "r1")
        let c = event(seq: 2, at: 200, messageId: "m2", requestId: "r2")

        let result = UsageEventDeduplicator.deduplicate([a, b, c])

        XCTAssertEqual(result.map(\.eventSeq), [1, 2, 3])
    }

    func testEmptyInputYieldsEmptyOutput() {
        XCTAssertTrue(UsageEventDeduplicator.deduplicate([]).isEmpty)
    }

    func testExactTieResolvesToLowestEventSeqRegardlessOfIterationOrder() {
        // 同 isSidechain、同 observedAt，只有 eventSeq 不同：全靠 eventSeq 这一级决胜。
        // 少了它，胜者取决于 Swift 每进程随机的字典迭代顺序——即哪条并列事件
        // 恰好第一个被迭代到。用足够多的并列事件把「最小 eventSeq 恰好排第一」的
        // 概率压到 ~1/N，让这个守卫在单次调用里也能稳定抓住缺失的决胜级。
        let seqs = [7, 3, 11, 5, 2, 9, 4, 12, 6, 10, 8]
        let events = seqs.map {
            event(seq: $0, at: 100, messageId: "m1", requestId: "r\($0)")
        }

        let result = UsageEventDeduplicator.deduplicate(events)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].eventSeq, 2)
    }
}
