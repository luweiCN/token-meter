import XCTest
@testable import TokenMeterCore

final class ResetCreditDisplayTests: XCTestCase {
    func testFiltersExpiredCredits() {
        let now = Date(timeIntervalSince1970: 200)
        let summary = ResetCreditSummary(
            availableCount: 2,
            credits: [
                ResetCredit(
                    issuedAt: Date(timeIntervalSince1970: 0),
                    expiresAt: Date(timeIntervalSince1970: 100)
                ),
                ResetCredit(
                    issuedAt: Date(timeIntervalSince1970: 100),
                    expiresAt: Date(timeIntervalSince1970: 300)
                )
            ]
        )

        let display = ResetCreditDisplay.items(for: summary, now: now)

        XCTAssertEqual(display.count, 1)
        XCTAssertEqual(display[0].index, 1)
        XCTAssertEqual(display[0].credit.expiresAt, Date(timeIntervalSince1970: 300))
    }

    func testComputesProgressAndRemainingDays() {
        let now = Date(timeIntervalSince1970: 15 * 86_400)
        let credit = ResetCredit(
            issuedAt: Date(timeIntervalSince1970: 0),
            expiresAt: Date(timeIntervalSince1970: 30 * 86_400)
        )

        let display = ResetCreditDisplay.item(index: 1, credit: credit, now: now)

        XCTAssertEqual(display.progress, 0.5, accuracy: 0.001)
        XCTAssertEqual(display.remainingText, "剩 15 天")
        XCTAssertEqual(display.tone, .ok)
    }

    func testProgressShowsRemainingLifetime() {
        let now = Date(timeIntervalSince1970: 24 * 86_400)
        let credit = ResetCredit(
            issuedAt: Date(timeIntervalSince1970: 0),
            expiresAt: Date(timeIntervalSince1970: 30 * 86_400)
        )

        let display = ResetCreditDisplay.item(index: 1, credit: credit, now: now)

        XCTAssertEqual(display.progress, 0.2, accuracy: 0.001)
        XCTAssertEqual(display.remainingText, "剩 6 天")
    }

    func testMarksCreditExpiringWithinSevenDaysAsWarning() {
        let now = Date(timeIntervalSince1970: 23 * 86_400)
        let credit = ResetCredit(
            issuedAt: Date(timeIntervalSince1970: 0),
            expiresAt: Date(timeIntervalSince1970: 30 * 86_400)
        )

        let display = ResetCreditDisplay.item(index: 1, credit: credit, now: now)

        XCTAssertEqual(display.remainingText, "剩 7 天")
        XCTAssertEqual(display.tone, .warning)
    }

    func testMarksCreditExpiringTodayAsBad() {
        let now = Date(timeIntervalSince1970: 29.5 * 86_400)
        let credit = ResetCredit(
            issuedAt: Date(timeIntervalSince1970: 0),
            expiresAt: Date(timeIntervalSince1970: 30 * 86_400)
        )

        let display = ResetCreditDisplay.item(index: 1, credit: credit, now: now)

        XCTAssertEqual(display.remainingText, "今天到期")
        XCTAssertEqual(display.tone, .bad)
    }
}
