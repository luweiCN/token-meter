import XCTest
@testable import TokenMeterCore

final class CostCalculatorTests: XCTestCase {
    private func makeCalculator() -> CostCalculator {
        let snapshot = PricingSnapshot(
            snapshotVersion: "test",
            source: "litellm",
            models: [
                "claude-opus-4-8": ModelPricing(
                    inputPerMTok: 10.0,
                    outputPerMTok: 100.0,
                    cacheReadPerMTok: 1.0,
                    cacheWrite5mPerMTok: 12.5,
                    cacheWrite1hPerMTok: 20.0
                )
            ]
        )
        return CostCalculator(snapshot: snapshot)
    }

    private func event(
        model: String?,
        input: Int64 = 0,
        output: Int64 = 0,
        cacheRead: Int64 = 0,
        write5m: Int64 = 0,
        write1h: Int64 = 0,
        reported: Int64? = nil
    ) -> UsageEvent {
        UsageEvent(
            eventSeq: 1,
            observedAt: Date(timeIntervalSince1970: 0),
            modelName: model,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWrite5mTokens: write5m,
            cacheWrite1hTokens: write1h,
            reportedCostUSDMicros: reported,
            sourceOffset: 0
        )
    }

    func testReportedCostWins() {
        let result = makeCalculator().cost(for: event(model: "claude-opus-4-8", input: 1_000_000, reported: 42))
        XCTAssertEqual(result.micros, 42)
        XCTAssertEqual(result.source, .reported)
    }

    func testComputesFromTokens() {
        // 1M input @ $10 + 1M output @ $100 = $110 = 110_000_000 micros
        let result = makeCalculator().cost(for: event(model: "claude-opus-4-8", input: 1_000_000, output: 1_000_000))
        XCTAssertEqual(result.micros, 110_000_000)
        XCTAssertEqual(result.source, .computed)
    }

    func testCacheTiersArePricedSeparately() {
        // 1M cacheRead @ $1 + 1M write5m @ $12.5 + 1M write1h @ $20 = $33.5
        let result = makeCalculator().cost(for: event(
            model: "claude-opus-4-8", cacheRead: 1_000_000, write5m: 1_000_000, write1h: 1_000_000
        ))
        XCTAssertEqual(result.micros, 33_500_000)
    }

    func testResolvesViaNormalizedName() {
        let result = makeCalculator().cost(for: event(model: "anthropic/claude-opus-4-8-20260101", input: 1_000_000))
        XCTAssertEqual(result.micros, 10_000_000)
        XCTAssertEqual(result.source, .computed)
    }

    func testDoesNotFallBackToFamilyPricing() {
        // fixture 里没有 claude-opus-4-9。真实快照里 opus 家族价格跨度 3 倍、
        // gpt-5 家族跨度 100 倍。借一个价格算出来的金额会被标成 computed，
        // 用户看到精确到分的数字却无从分辨它来自哪个模型。宁可说不知道。
        let result = makeCalculator().cost(for: event(model: "claude-opus-4-9", input: 1_000_000))
        XCTAssertNil(result.micros)
        XCTAssertEqual(result.source, .unknown)
    }

    func testUnknownModelYieldsNilNotZero() {
        let result = makeCalculator().cost(for: event(model: "some-unlisted-model", input: 1_000_000))
        XCTAssertNil(result.micros)
        XCTAssertEqual(result.source, .unknown)
    }

    func testNilModelNameYieldsUnknown() {
        let result = makeCalculator().cost(for: event(model: nil, input: 1_000_000))
        XCTAssertNil(result.micros)
        XCTAssertEqual(result.source, .unknown)
    }

    func testCanonicalCollisionResolvesToLexicographicallyFirstKey() {
        // 三组撞名，每组四个原始 key，只有字典序最小的那个价格独特。
        //
        // 用三组而不是一组，是为了让这个测试真的守得住 init 里的 sorted(by:)。
        // 去掉 sorted 后，Swift 字典的迭代顺序随进程哈希种子变化，单组撞名
        // 只有 1/4 概率选错，测试有 25% 概率放过。三组同时蒙对的概率是
        // (1/4)^3 ≈ 1.6%，测试会以 98.4% 的概率变红。
        func priced(_ input: Double) -> ModelPricing {
            ModelPricing(inputPerMTok: input, outputPerMTok: 0, cacheReadPerMTok: 0,
                         cacheWrite5mPerMTok: 0, cacheWrite1hPerMTok: 0)
        }
        let snapshot = PricingSnapshot(snapshotVersion: "test", source: "litellm", models: [
            "alpha-1": priced(1), "alpha-1-20240101": priced(90),
            "vertex_ai/alpha-1": priced(91), "zai/alpha-1": priced(92),

            "beta-2": priced(2), "beta-2-20240101": priced(93),
            "vertex_ai/beta-2": priced(94), "zai/beta-2": priced(95),

            "gamma-3": priced(3), "gamma-3-20240101": priced(96),
            "vertex_ai/gamma-3": priced(97), "zai/gamma-3": priced(98)
        ])
        let calculator = CostCalculator(snapshot: snapshot)

        XCTAssertEqual(calculator.cost(for: event(model: "alpha-1", input: 1_000_000)).micros, 1_000_000)
        XCTAssertEqual(calculator.cost(for: event(model: "beta-2", input: 1_000_000)).micros, 2_000_000)
        XCTAssertEqual(calculator.cost(for: event(model: "gamma-3", input: 1_000_000)).micros, 3_000_000)
    }

    func testResolvesGlmThroughZaiPrefix() {
        // OpenCode 上报裸 glm-4.6；快照 key 是 zai/glm-4.6
        let snapshot = PricingSnapshot(snapshotVersion: "test", source: "litellm", models: [
            "zai/glm-4.6": ModelPricing(inputPerMTok: 0.6, outputPerMTok: 2.2, cacheReadPerMTok: 0.11,
                                        cacheWrite5mPerMTok: 0, cacheWrite1hPerMTok: 1.2)
        ])
        let result = CostCalculator(snapshot: snapshot).cost(for: event(model: "glm-4.6", input: 1_000_000))
        XCTAssertEqual(result.micros, 600_000)
        XCTAssertEqual(result.source, .computed)
    }

    func testFreeCacheWriteCostsNothing() {
        // glm-4.6 的 cacheWrite5m 是 0，不是「未知」
        let snapshot = PricingSnapshot(snapshotVersion: "test", source: "litellm", models: [
            "zai/glm-4.6": ModelPricing(inputPerMTok: 0.6, outputPerMTok: 2.2, cacheReadPerMTok: 0.11,
                                        cacheWrite5mPerMTok: 0, cacheWrite1hPerMTok: 1.2)
        ])
        let result = CostCalculator(snapshot: snapshot).cost(for: event(model: "glm-4.6", write5m: 10_000_000))
        XCTAssertEqual(result.micros, 0)
        XCTAssertEqual(result.source, .computed, "免费不等于未知")
    }

    func testReasoningTokensAreNotPricedSeparately() {
        // reasoning 已包含在 output 里，不得再计一次
        let withReasoning = UsageEvent(
            eventSeq: 1,
            observedAt: Date(timeIntervalSince1970: 0),
            modelName: "claude-opus-4-8",
            outputTokens: 1_000_000,
            reasoningTokens: 500_000,
            sourceOffset: 0
        )
        XCTAssertEqual(makeCalculator().cost(for: withReasoning).micros, 100_000_000)
    }

    func testReportedZeroCostIsReportedNotRecomputed() {
        // omp/OpenCode 在套餐制下可能上报 0。0 是一个事实，不是缺失。
        let result = makeCalculator().cost(for: event(model: "claude-opus-4-8", input: 1_000_000, reported: 0))
        XCTAssertEqual(result.micros, 0)
        XCTAssertEqual(result.source, .reported)
    }
}
