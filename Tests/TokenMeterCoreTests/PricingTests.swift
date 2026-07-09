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
