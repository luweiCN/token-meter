import XCTest
@testable import TokenMeterCore

final class MultiTierPricingTests: XCTestCase {
    private func rate(_ multiplier: Double) -> [String: Any] {
        ["inputPerMTok": multiplier, "outputPerMTok": multiplier * 2,
         "cacheReadPerMTok": multiplier * 3, "cacheWrite5mPerMTok": multiplier * 4,
         "cacheWrite1hPerMTok": multiplier * 5]
    }

    private func snapshot(tiers: Any? = nil, schemaVersion: Int? = 2,
                          base: [String: Any]? = nil) throws -> PricingSnapshot {
        var model = base ?? rate(1)
        model["longContext"] = tiers
        var payload: [String: Any] = ["snapshotVersion": "fixture", "source": "litellm", "models": ["context-model": model]]
        payload["schemaVersion"] = schemaVersion
        return try PricingSnapshot.decode(JSONSerialization.data(withJSONObject: payload))
    }

    private var tiers: [[String: Any]] {
        [["thresholdTokens": 32_000, "rate": rate(10)], ["thresholdTokens": 256_000, "rate": rate(100)]]
    }

    private func event(input: Int64, output: Int64 = 100, cache: Int64 = 0,
                       write5m: Int64 = 0, write1h: Int64 = 0, reported: Int64? = nil) -> UsageEvent {
        UsageEvent(eventSeq: 1, observedAt: Date(timeIntervalSince1970: 0), modelName: "context-model",
                   dedupeKey: nil, inputTokens: input, outputTokens: output, cacheReadTokens: cache,
                   cacheWrite5mTokens: write5m, cacheWrite1hTokens: write1h,
                   reportedCostUSDMicros: reported, sourceOffset: 0)
    }

    func testEachRequestUsesHighestExceededThresholdForAllTokens() throws {
        let snapshot = try snapshot(tiers: tiers)
        try snapshot.validate()
        let calculator = CostCalculator(snapshot: snapshot)
        for (input, expected): (Int64, Int64) in [(32_000, 32_200), (32_001, 322_010),
                                                  (256_000, 2_562_000), (256_001, 25_620_100)] {
            let result = calculator.cost(for: event(input: input))
            XCTAssertEqual(result.source, .computed)
            XCTAssertEqual(result.micros, expected, "输入 \(input) 应选择对应完整价格档")
        }
        XCTAssertEqual(calculator.cost(for: event(input: 1, output: 1_000_000)).micros, 2_000_001,
                       "输出量不能触发输入上下文档位")
    }

    func testThresholdIncludesAllCacheTokensAndUsesTheirIndependentRates() throws {
        let calculator = CostCalculator(snapshot: try snapshot(tiers: tiers))
        let result = calculator.cost(for: event(input: 100_000, cache: 100_000, write5m: 56_000, write1h: 1))
        XCTAssertEqual(result.micros, 62_420_500)
    }

    func testMissingCachePriceOnlyMakesConsumedCategoryUnknown() throws {
        var base = rate(1)
        base["cacheReadPerMTok"] = NSNull()
        base.removeValue(forKey: "cacheWrite5mPerMTok")
        let snapshot = try snapshot(base: base)
        try snapshot.validate()
        let calculator = CostCalculator(snapshot: snapshot)
        XCTAssertEqual(calculator.cost(for: event(input: 10, output: 3)).micros, 16)
        XCTAssertEqual(calculator.cost(for: event(input: 10, cache: 1)).source, .unknown)
        XCTAssertNil(calculator.cost(for: event(input: 10, write5m: 1)).micros)
        XCTAssertEqual(calculator.cost(for: event(input: 10, cache: 1, reported: 123)).micros, 123)
        base["cacheReadPerMTok"] = 0
        let free = CostCalculator(snapshot: try self.snapshot(base: base))
        XCTAssertEqual(free.cost(for: event(input: 10, output: 3, cache: 100)).micros, 16)
    }

    func testUnknownCacheRateInOneTierDoesNotBorrowAnotherTiersPrice() throws {
        var contextRate = rate(10)
        contextRate["cacheReadPerMTok"] = NSNull()
        let calculator = CostCalculator(snapshot: try snapshot(tiers: [["thresholdTokens": 32_000, "rate": contextRate]]))
        XCTAssertEqual(calculator.cost(for: event(input: 31_000, cache: 1_000)).micros, 34_200)
        XCTAssertNil(calculator.cost(for: event(input: 31_001, cache: 1_000)).micros)
    }

    func testRejectsUnorderedDuplicateOrInvalidTiers() throws {
        for invalid in [Array(tiers.reversed()), [tiers[0], tiers[0]],
                        [["thresholdTokens": 0, "rate": rate(1)]],
                        [["thresholdTokens": 32_000, "rate": rate(-1)]]] {
            XCTAssertThrowsError(try snapshot(tiers: invalid).validate())
        }
    }

    func testLegacySingleTierIsReadAndEncodedAsCurrentList() throws {
        let snapshot = try snapshot(tiers: tiers[0], schemaVersion: nil)
        try snapshot.validate()
        XCTAssertEqual(CostCalculator(snapshot: snapshot).cost(for: event(input: 32_001)).micros, 322_010)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        XCTAssertEqual(encoded["schemaVersion"] as? Int, 2)
        let models = try XCTUnwrap(encoded["models"] as? [String: [String: Any]])
        XCTAssertEqual((models["context-model"]?["longContext"] as? [[String: Any]])?.count, 1)
    }

    func testRejectsUnknownSnapshotSchema() {
        XCTAssertThrowsError(try snapshot(schemaVersion: 3))
    }

    func testUserOverridesInheritReplaceOrDisableAllContextTiers() throws {
        let bundled = try snapshot(tiers: tiers)
        let replacement = [LongContextPricing(thresholdTokens: 500, rate: RateCard(
            inputPerMTok: 7, outputPerMTok: 8, cacheReadPerMTok: nil,
            cacheWrite5mPerMTok: nil, cacheWrite1hPerMTok: nil))]
        for (entry, count, cost) in [
            (CustomPricingEntry(ignoreReported: true), 2, Int64(322_010)),
            (CustomPricingEntry(longContext: replacement), 1, Int64(224_807)),
            (CustomPricingEntry(longContext: []), 0, Int64(32_201)),
        ] {
            let overrides = CustomPricingOverrides(models: ["context-model": entry], fingerprint: "test",
                                                   canonicalKeys: ["context-model"])
            let (resolved, dropped) = overrides.resolvedModels(bundled: bundled)
            XCTAssertTrue(dropped.isEmpty)
            XCTAssertEqual(resolved["context-model"]?.longContext.count, count)
            XCTAssertEqual(CostCalculator(snapshot: bundled.merging(userOverrides: resolved))
                .cost(for: event(input: 32_001)).micros, cost)
        }
        let legacy = try JSONDecoder().decode(CustomPricingEntry.self, from: JSONSerialization.data(
            withJSONObject: ["longContext": tiers[0]]))
        XCTAssertEqual(legacy.longContext?.count, 1)
    }

    func testLegacyClientCannotSilentlyReadCurrentContextArrayAsFlatPrice() throws {
        struct LegacyModel: Decodable {
            let inputPerMTok: Double
            let outputPerMTok: Double
            let longContext: LongContextPricing?
        }
        struct LegacySnapshot: Decodable { let models: [String: LegacyModel] }
        let data = try JSONEncoder().encode(snapshot(tiers: tiers))
        XCTAssertThrowsError(try JSONDecoder().decode(LegacySnapshot.self, from: data))
        XCTAssertTrue(PricingSnapshotUpdater.snapshotURL.lastPathComponent.contains("-v2.json"))
    }
}
