import XCTest
@testable import TokenMeterCore

final class UsageNotificationEventDetectorTests: XCTestCase {
    func testDetectsResetCreditIncrease() {
        let previous = snapshot(resetCredits: ResetCreditSummary(availableCount: 1, credits: []))
        let current = snapshot(resetCredits: ResetCreditSummary(availableCount: 3, credits: []))

        let events = UsageNotificationEventDetector.events(previous: [previous], current: [current])

        XCTAssertEqual(events, [
            .resetCreditsAdded(providerId: "codex", providerName: "Codex", addedCount: 2, totalCount: 3)
        ])
    }

    func testDoesNotRepeatWhenResetCreditCountIsUnchanged() {
        let previous = snapshot(resetCredits: ResetCreditSummary(availableCount: 3, credits: []))
        let current = snapshot(resetCredits: ResetCreditSummary(availableCount: 3, credits: []))

        XCTAssertTrue(UsageNotificationEventDetector.events(previous: [previous], current: [current]).isEmpty)
    }

    func testDetectsQuotaRefreshFromLowRemainingToFull() {
        let previous = snapshot(remainingPercent: 12)
        let current = snapshot(remainingPercent: 100)

        let events = UsageNotificationEventDetector.events(previous: [previous], current: [current])

        XCTAssertEqual(events, [
            .quotaRefreshed(providerId: "codex", providerName: "Codex", metricLabel: "5h")
        ])
    }

    func testDoesNotRepeatWhenQuotaStaysFull() {
        let previous = snapshot(remainingPercent: 100)
        let current = snapshot(remainingPercent: 100)

        XCTAssertTrue(UsageNotificationEventDetector.events(previous: [previous], current: [current]).isEmpty)
    }

    func testDetectsQuotaDepletedCrossingZero() {
        let previous = snapshot(remainingPercent: 1)
        let current = snapshot(remainingPercent: 0)

        let events = UsageNotificationEventDetector.events(previous: [previous], current: [current])

        XCTAssertEqual(events, [
            .quotaDepleted(providerId: "codex", providerName: "Codex", metricLabel: "5h")
        ])
    }

    func testDoesNotRepeatWhenQuotaStaysZero() {
        let previous = snapshot(remainingPercent: 0)
        let current = snapshot(remainingPercent: 0)

        XCTAssertTrue(UsageNotificationEventDetector.events(previous: [previous], current: [current]).isEmpty)
    }

    func testIgnoresNonOkSnapshots() {
        let previous = snapshot(remainingPercent: 12)
        let current = snapshot(status: .warning, remainingPercent: 100)

        XCTAssertTrue(UsageNotificationEventDetector.events(previous: [previous], current: [current]).isEmpty)
    }

    private func snapshot(
        status: UsageStatus = .ok,
        remainingPercent: Double = 50,
        resetCredits: ResetCreditSummary? = nil
    ) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            providerId: "codex",
            displayName: "Codex",
            status: status,
            fetchedAt: Date(timeIntervalSince1970: 100),
            summary: nil,
            message: nil,
            groups: [
                UsageGroup(
                    id: "codex",
                    title: "Codex",
                    subtitle: nil,
                    items: [
                        UsageMetric(
                            id: "codex-5h",
                            label: "5h",
                            kind: .quota,
                            usedPercent: 100 - remainingPercent,
                            remainingPercent: remainingPercent,
                            resetText: nil,
                            status: .ok,
                            detail: nil
                        )
                    ]
                )
            ],
            resetCredits: resetCredits
        )
    }
}
