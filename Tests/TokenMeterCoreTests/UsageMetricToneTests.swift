import XCTest
@testable import TokenMeterCore

final class UsageMetricToneTests: XCTestCase {
    func testKeepsHighRemainingShortWindowGreenEvenWhenSlightlyAheadOfPace() {
        let now = Date(timeIntervalSince1970: 1_000)
        let metric = UsageMetric(
            id: "codex-5h",
            label: "5h",
            kind: .quota,
            usedPercent: 8,
            remainingPercent: 92,
            resetText: "4h38m",
            status: .ok,
            detail: nil,
            resetAt: now.addingTimeInterval((4 * 60 + 38) * 60),
            windowDurationMinutes: 300
        )

        XCTAssertEqual(UsageMetricToneResolver.tone(for: metric, now: now), .ok)
    }

    func testUsesPacedWindowWhenResetAndWindowAreKnown() {
        let now = Date(timeIntervalSince1970: 1_000)
        let metric = UsageMetric(
            id: "codex-5h",
            label: "5h",
            kind: .quota,
            usedPercent: 50,
            remainingPercent: 50,
            resetText: "4h",
            status: .ok,
            detail: nil,
            resetAt: now.addingTimeInterval(4 * 60 * 60),
            windowDurationMinutes: 300
        )

        XCTAssertEqual(UsageMetricToneResolver.tone(for: metric, now: now), .bad)
    }

    func testFallsBackToUsedPercentThresholdWhenWindowIsUnknown() {
        let metric = UsageMetric(
            id: "manual",
            label: "额度",
            kind: .quota,
            usedPercent: 35,
            remainingPercent: 65,
            resetText: nil,
            status: .ok,
            detail: nil
        )

        XCTAssertEqual(UsageMetricToneResolver.tone(for: metric, now: Date(timeIntervalSince1970: 0)), .warning)
    }
}
