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

    func testDetectsResetCreditDecreaseAsConsumed() {
        let previous = snapshot(resetCredits: ResetCreditSummary(availableCount: 3, credits: []))
        let current = snapshot(resetCredits: ResetCreditSummary(availableCount: 2, credits: []))

        let events = UsageNotificationEventDetector.events(previous: [previous], current: [current])

        XCTAssertEqual(events, [
            .resetCreditsConsumed(providerId: "codex", providerName: "Codex", removedCount: 1, remainingCount: 2)
        ])
    }

    func testThresholdCrossingFiresOnceOnTheWayUp() {
        // 用量 80% → 88% 跨过 85% 阈值：告警一次。
        let events = UsageNotificationEventDetector.events(
            previous: [snapshot(remainingPercent: 20)],
            current: [snapshot(remainingPercent: 12)],
            usedThresholdPercent: 85
        )
        XCTAssertEqual(events, [
            .quotaThresholdCrossed(providerId: "codex", providerName: "Codex", metricLabel: "5h", usedPercent: 88, thresholdPercent: 85)
        ])

        // 已在阈值之上继续涨（88% → 92%）：不重复告警。
        XCTAssertTrue(
            UsageNotificationEventDetector.events(
                previous: [snapshot(remainingPercent: 12)],
                current: [snapshot(remainingPercent: 8)],
                usedThresholdPercent: 85
            ).isEmpty
        )
    }

    func testThresholdDisabledWhenZero() {
        XCTAssertTrue(
            UsageNotificationEventDetector.events(
                previous: [snapshot(remainingPercent: 20)],
                current: [snapshot(remainingPercent: 12)],
                usedThresholdPercent: 0
            ).isEmpty
        )
    }

    func testDepletionOwnsTheZeroCrossingWithoutDoubleFiring() {
        // 一步跨过阈值又到 0：只发 depleted，不再叠一条阈值告警。
        let events = UsageNotificationEventDetector.events(
            previous: [snapshot(remainingPercent: 20)],
            current: [snapshot(remainingPercent: 0)],
            usedThresholdPercent: 85
        )
        XCTAssertEqual(events, [
            .quotaDepleted(providerId: "codex", providerName: "Codex", metricLabel: "5h")
        ])
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
