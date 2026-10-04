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
        XCTAssertEqual(display.remainingText, "15 天")
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
        XCTAssertEqual(display.remainingText, "6 天")
    }

    func testMarksCreditExpiringWithinSevenDaysAsWarning() {
        let now = Date(timeIntervalSince1970: 23 * 86_400)
        let credit = ResetCredit(
            issuedAt: Date(timeIntervalSince1970: 0),
            expiresAt: Date(timeIntervalSince1970: 30 * 86_400)
        )

        let display = ResetCreditDisplay.item(index: 1, credit: credit, now: now)

        XCTAssertEqual(display.remainingText, "7 天")
        XCTAssertEqual(display.tone, .warning)
    }

    func testShowsHoursForCreditExpiringWithinADay() {
        let now = Date(timeIntervalSince1970: 29.5 * 86_400)
        let credit = ResetCredit(
            issuedAt: Date(timeIntervalSince1970: 0),
            expiresAt: Date(timeIntervalSince1970: 30 * 86_400)
        )

        let display = ResetCreditDisplay.item(index: 1, credit: credit, now: now)

        XCTAssertEqual(display.remainingText, "12 小时")
        XCTAssertEqual(display.tone, .bad)
    }

    func testRemainingTimeUsesDaysHoursAndMinutesAtTheirBoundaries() {
        let now = Date(timeIntervalSince1970: 0)
        let cases: [(seconds: TimeInterval, text: String)] = [
            (2 * 86_400 + 3_600, "2 天"),
            (86_401, "1 天"),
            (86_400, "24 小时"),
            (86_399, "23 小时"),
            (18 * 3_600 + 4 * 60, "18 小时"),
            (3_600, "1 小时"),
            (3_599, "59 分钟"),
            (60, "1 分钟"),
            (59, "不足 1 分钟"),
            (0, "已到期"),
            (-1, "已到期")
        ]

        for (seconds, text) in cases {
            let credit = ResetCredit(issuedAt: now, expiresAt: now.addingTimeInterval(seconds))
            let display = ResetCreditDisplay.item(index: 1, credit: credit, now: now)
            XCTAssertEqual(display.remainingText, text, "remaining seconds: \(seconds)")
        }
    }

    func testCreditExpiringTomorrowUsesRemainingHours() throws {
        let formatter = ISO8601DateFormatter()
        let now = try XCTUnwrap(formatter.date(from: "2026-01-01T18:00:00+08:00"))
        let expiresAt = try XCTUnwrap(formatter.date(from: "2026-01-02T12:05:00+08:00"))
        let credit = ResetCredit(issuedAt: nil, expiresAt: expiresAt)

        let display = ResetCreditDisplay.item(index: 1, credit: credit, now: now)

        XCTAssertEqual(display.remainingText, "18 小时")
        XCTAssertEqual(display.tone, .bad)
        XCTAssertEqual(display.credit.expiresAt, expiresAt)
    }

    func testUnknownExpirationDoesNotInventRemainingTime() {
        let display = ResetCreditDisplay.item(
            index: 1,
            credit: ResetCredit(issuedAt: nil, expiresAt: nil)
        )

        XCTAssertEqual(display.remainingText, "--")
        XCTAssertEqual(display.progress, 0)
    }

    func testSummaryUsesSoonestUnexpiredCard() {
        let now = Date(timeIntervalSince1970: 20 * 86_400)
        let summary = ResetCreditSummary(
            availableCount: 2,
            credits: [30, 25, 10].map { days in
                ResetCredit(
                    issuedAt: Date(timeIntervalSince1970: 0),
                    expiresAt: Date(timeIntervalSince1970: TimeInterval(days) * 86_400)
                )
            }
        )

        let earliest = ResetCreditDisplay.items(for: summary, now: now).first

        XCTAssertEqual(earliest?.credit.expiresAt, Date(timeIntervalSince1970: 25 * 86_400))
        XCTAssertEqual(earliest?.remainingText, "5 天")
        XCTAssertEqual(earliest?.tone, .warning)
    }

    func testCountdownChangesUnitsAndExcludesCardAtExpiration() {
        let now = Date(timeIntervalSince1970: 0)
        let expiresAt = now.addingTimeInterval(25 * 3_600)
        let summary = ResetCreditSummary(
            availableCount: 1,
            credits: [ResetCredit(issuedAt: now, expiresAt: expiresAt)]
        )

        XCTAssertEqual(ResetCreditDisplay.items(for: summary, now: now).first?.remainingText, "1 天")
        XCTAssertEqual(
            ResetCreditDisplay.items(for: summary, now: now.addingTimeInterval(2 * 3_600))
                .first?.remainingText,
            "23 小时"
        )
        XCTAssertTrue(ResetCreditDisplay.items(for: summary, now: expiresAt).isEmpty)
    }
}
