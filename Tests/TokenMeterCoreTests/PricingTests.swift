import XCTest
@testable import TokenMeterCore

final class PricingTests: XCTestCase {
    func testLoadsBundledSnapshot() throws {
        let snapshot = try PricingSnapshot.loadBundled()
        XCTAssertFalse(snapshot.snapshotVersion.isEmpty)
        XCTAssertEqual(snapshot.source, "litellm")
        XCTAssertGreaterThan(snapshot.models.count, 50)
    }

    func testBundledSnapshotContainsModelsUsedOnThisMachine() throws {
        let snapshot = try PricingSnapshot.loadBundled()
        let canonicalKeys = Set(snapshot.models.keys.map(ModelNameNormalizer.canonical))
        XCTAssertTrue(canonicalKeys.contains { $0.contains("opus") }, "缺少 opus 系列定价")
        XCTAssertTrue(canonicalKeys.contains { $0.contains("sonnet") }, "缺少 sonnet 系列定价")
    }

    func testBundledSnapshotContainsGlmPricing() throws {
        let snapshot = try PricingSnapshot.loadBundled()
        let canonicalKeys = Set(snapshot.models.keys.map(ModelNameNormalizer.canonical))
        // OpenCode 在本机跑 glm-4.6，缺定价会让它的成本静默变成 unknown
        XCTAssertTrue(canonicalKeys.contains("glm-4.6"))
    }

    func testUsesPublishedOneHourCacheRateNotAHardcodedMultiple() throws {
        let snapshot = try PricingSnapshot.loadBundled()
        let ratios = snapshot.models.values
            .filter { $0.inputPerMTok > 0 }
            .map { $0.cacheWrite1hPerMTok / $0.inputPerMTok }
        // 若脚本硬编码 input*2，所有比值都会恰好是 2.0
        XCTAssertTrue(ratios.contains { abs($0 - 2.0) > 0.01 },
                      "全部模型的 1h 缓存价都恰好是 input×2，说明用的是硬编码倍率而不是 LiteLLM 发布的真实价格")
    }

    func testDecodesModelPricing() throws {
        let json = """
        {
          "snapshotVersion": "2026-07-09",
          "source": "litellm",
          "models": {
            "claude-opus-4-8": {
              "inputPerMTok": 15.0,
              "outputPerMTok": 75.0,
              "cacheReadPerMTok": 1.5,
              "cacheWrite5mPerMTok": 18.75,
              "cacheWrite1hPerMTok": 30.0
            }
          }
        }
        """
        let snapshot = try JSONDecoder().decode(PricingSnapshot.self, from: Data(json.utf8))
        let pricing = try XCTUnwrap(snapshot.models["claude-opus-4-8"])
        XCTAssertEqual(pricing.inputPerMTok, 15.0)
        XCTAssertEqual(pricing.cacheWrite1hPerMTok, 30.0)
    }
}
