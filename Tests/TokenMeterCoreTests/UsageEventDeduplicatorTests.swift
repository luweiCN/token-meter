import XCTest
@testable import TokenMeterCore

final class UsageEventDeduplicatorTests: XCTestCase {
    private func event(
        seq: Int,
        at seconds: TimeInterval,
        messageId: String?,
        requestId: String?,
        input: Int64 = 1,
        isSidechain: Bool = false
    ) -> UsageEvent {
        UsageEvent(
            eventSeq: seq,
            observedAt: Date(timeIntervalSince1970: seconds),
            messageId: messageId,
            requestId: requestId,
            inputTokens: input,
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

    func testDropsSidechainReplayOfSameMessageId() {
        // 同一条 message 被 sidechain 用新的 requestId 重放，必须丢弃重放副本
        let original = event(seq: 1, at: 100, messageId: "m1", requestId: "r1", isSidechain: false)
        let replay = event(seq: 2, at: 150, messageId: "m1", requestId: "r2", isSidechain: true)

        let result = UsageEventDeduplicator.deduplicate([original, replay])

        XCTAssertEqual(result.count, 1)
        XCTAssertFalse(result[0].isSidechain)
        XCTAssertEqual(result[0].requestId, "r1")
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
        XCTAssertEqual(result[0].requestId, "r2")
    }
}
