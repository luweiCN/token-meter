import XCTest
@testable import TokenMeterApp
import TokenMeterCore

final class PopoverUsageFormatTests: XCTestCase {
    func testAggregateAmountSeparatesCoverageFromUnits() {
        let partial = PopoverTokenAmount(tokens: 129_856_700_000, unreportedEvents: 224)
        XCTAssertEqual(partial.aggregateText, "129.86B")
        XCTAssertTrue(partial.detail.contains("129,856,700,000"))
        XCTAssertEqual(partial.detail, "129,856,700,000 Token")
        XCTAssertEqual(PopoverTokenAmount(tokens: 33_901_700_000).aggregateText, "33.90B")
        XCTAssertEqual(PopoverTokenAmount(tokens: 20_199_200_000).aggregateText, "20.20B")
        XCTAssertEqual(PopoverTokenAmount(tokens: 1_000_000_000_000).aggregateText, "1.00T")
        XCTAssertEqual(PopoverTokenAmount(tokens: 1_031_100_000).dailyText, "1031.1M")
        XCTAssertEqual(PopoverTokenAmount(tokens: 0, unreportedEvents: 1).aggregateText, "—")
        XCTAssertEqual(PopoverTokenAmount(tokens: 0).aggregateText, "0")
    }

    func testCacheRateDistinguishesMissingInputFromZeroHits() {
        XCTAssertEqual(PromptCacheUsage().percentText, "暂无数据")
        XCTAssertEqual(PromptCacheUsage(readTokens: 0, inputTokens: 100).percentText, "0.0%")
        XCTAssertEqual(PromptCacheUsage(readTokens: 999, inputTokens: 1000).percentText, "99.9%")
    }
}
