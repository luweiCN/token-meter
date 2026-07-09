import XCTest
@testable import TokenMeterCore

final class PricingTests: XCTestCase {
    func testLoadsBundledSnapshot() throws {
        let snapshot = try PricingSnapshot.loadBundled()
        XCTAssertFalse(snapshot.snapshotVersion.isEmpty)
        XCTAssertEqual(snapshot.source, "litellm")
        // 353 个模型。掉到 300 以下说明过滤条件坏了。
        XCTAssertGreaterThan(snapshot.models.count, 300)
    }

    func testBundledSnapshotPricesTheModelsThisMachineActuallyUses() throws {
        let snapshot = try PricingSnapshot.loadBundled()
        var byCanonical: [String: ModelPricing] = [:]
        for (key, pricing) in snapshot.models {
            byCanonical[ModelNameNormalizer.canonical(key)] = pricing
        }

        // 本机四个 agent 实际上报的模型名
        for model in ["claude-fable-5", "glm-4.6"] {
            let pricing = try XCTUnwrap(byCanonical[model], "\(model) 缺定价，成本会静默变成 unknown")
            XCTAssertGreaterThan(pricing.inputPerMTok, 0, "\(model) 的 input 价必须为正")
            XCTAssertGreaterThan(pricing.outputPerMTok, 0, "\(model) 的 output 价必须为正")
        }
    }

    func testEveryBundledModelHasPositiveBasePrices() throws {
        let snapshot = try PricingSnapshot.loadBundled()
        // 转换脚本会跳过没有基础价的条目，快照里不该有零价模型
        for (key, pricing) in snapshot.models {
            XCTAssertGreaterThan(pricing.inputPerMTok, 0, "\(key) 的 inputPerMTok 为零")
            XCTAssertGreaterThan(pricing.outputPerMTok, 0, "\(key) 的 outputPerMTok 为零")
        }
    }

    func testDecodesModelPricing() throws {
        let json = """
        {
          "snapshotVersion": "abc123",
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
