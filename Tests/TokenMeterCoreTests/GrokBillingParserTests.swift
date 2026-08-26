import XCTest
@testable import TokenMeterCore

final class GrokBillingParserTests: XCTestCase {
    func testWeeklyWindowFromPeriodDates() throws {
        let json = """
        {"creditUsagePercent":12.5,"billingCycle":{"billingPeriodStart":"2026-08-01T00:00:00Z","billingPeriodEnd":"2026-08-08T00:00:00Z"}}
        """
        let snapshot = try GrokBillingParser.parse(
            data: Data(json.utf8),
            providerId: "grok",
            displayName: "Grok Build",
            fetchedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.groups.count, 1)
        XCTAssertEqual(snapshot.groups[0].title, "Grok Build")
        let metric = snapshot.groups[0].items[0]
        XCTAssertEqual(metric.label, "7d")
        XCTAssertEqual(metric.windowDurationMinutes, 10_080)
        XCTAssertEqual(metric.usedPercent, 12.5)
        XCTAssertEqual(metric.remainingPercent, 87.5)
        XCTAssertEqual(metric.resetAt, ISO8601DateFormatter().date(from: "2026-08-08T00:00:00Z"))
    }

    func testMonthlyWindowFromThirtyDaySpan() throws {
        let json = """
        {"usedPercent":40,"billingCycle":{"billingPeriodStart":"2026-07-01T00:00:00Z","billingPeriodEnd":"2026-07-31T00:00:00Z"}}
        """
        let metric = try GrokBillingParser.parse(data: Data(json.utf8), providerId: "grok", displayName: "Grok Build").groups[0].items[0]
        XCTAssertEqual(metric.label, "30d")
        XCTAssertEqual(metric.windowDurationMinutes, 43_200)
    }

    func testPercentOnlyDefaultsToWeekly() throws {
        let json = #"{"config":{"creditUsagePercent":{"val":8}}}"#
        let metric = try GrokBillingParser.parse(data: Data(json.utf8), providerId: "grok", displayName: "Grok Build").groups[0].items[0]
        XCTAssertEqual(metric.label, "7d")
        XCTAssertEqual(metric.usedPercent, 8)
    }

    func testUsedOverLimitRatio() throws {
        let json = #"{"monthlyLimit":{"val":10000},"usage":{"totalUsed":{"val":2500}}}"#
        let metric = try GrokBillingParser.parse(data: Data(json.utf8), providerId: "grok", displayName: "Grok Build").groups[0].items[0]
        XCTAssertEqual(metric.usedPercent, 25)
        XCTAssertEqual(metric.label, "7d")
    }

    func testMissingPercentThrows() {
        XCTAssertThrowsError(try GrokBillingParser.parse(data: Data(#"{}"#.utf8), providerId: "grok", displayName: "Grok Build"))
    }

    func testDoesNotDuplicateOnePercentIntoTwoWindows() throws {
        let json = #"{"creditUsagePercent":10,"billingCycle":{"billingPeriodStart":"2026-08-01T00:00:00Z","billingPeriodEnd":"2026-08-08T00:00:00Z"}}"#
        let items = try GrokBillingParser.parse(data: Data(json.utf8), providerId: "grok", displayName: "Grok Build").groups[0].items
        XCTAssertEqual(items.count, 1)
    }
}
