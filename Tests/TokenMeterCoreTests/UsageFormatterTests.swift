import XCTest
@testable import TokenMeterCore

final class UsageFormatterTests: XCTestCase {
    func testDailyTokenLabelsContainOneUnit() {
        XCTAssertEqual(UsageFormatter.compactTokens(0), "0")
        XCTAssertEqual(UsageFormatter.compactTokens(775), "775")
        XCTAssertEqual(UsageFormatter.compactTokens(3_400), "3.4K")
        XCTAssertEqual(UsageFormatter.compactTokens(521_319_916), "521.3M")
        XCTAssertEqual(UsageFormatter.compactTokens(2_398_499_879), "2398.5M")
    }

    func testAggregatedTokenLabelsScaleAcrossDays() {
        XCTAssertEqual(UsageFormatter.compactTokensAggregated(521_319_916), "521.32M")
        XCTAssertEqual(UsageFormatter.compactTokensAggregated(2_398_499_879), "2.40B")
        XCTAssertEqual(UsageFormatter.compactTokensAggregated(1_254_200_000_000), "1.25T")
    }
}
