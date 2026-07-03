import XCTest
@testable import TokenMeterCore

final class ProviderSnapshotCacheTests: XCTestCase {
    func testKeepsPreviousSuccessfulSnapshotDataWhenRefreshFails() {
        let previous = ProviderUsageSnapshot(
            providerId: "claude-code",
            displayName: "Claude Code",
            status: .ok,
            fetchedAt: Date(timeIntervalSince1970: 100),
            summary: "5h 90%",
            message: nil,
            groups: [
                UsageGroup(
                    id: "claude",
                    title: "Claude Code",
                    subtitle: nil,
                    items: [
                        UsageMetric(
                            id: "claude-5h",
                            label: "5h",
                            kind: .quota,
                            usedPercent: 10,
                            remainingPercent: 90,
                            resetText: "4h",
                            status: .ok,
                            detail: nil
                        )
                    ]
                )
            ]
        )
        let failed = ProviderUsageSnapshot(
            providerId: "claude-code",
            displayName: "Claude Code",
            status: .error,
            fetchedAt: Date(timeIntervalSince1970: 200),
            summary: nil,
            message: "Claude 接口限流",
            groups: []
        )

        let merged = ProviderSnapshotCache.merge(previous: [previous], refreshed: [failed])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].providerId, "claude-code")
        XCTAssertEqual(merged[0].status, .warning)
        XCTAssertEqual(merged[0].fetchedAt, previous.fetchedAt)
        XCTAssertEqual(merged[0].summary, previous.summary)
        XCTAssertEqual(merged[0].message, "Claude 接口限流")
        XCTAssertEqual(merged[0].groups, previous.groups)
    }

    func testKeepsCachedSnapshotDataAcrossRepeatedRefreshFailures() {
        let cachedWarning = ProviderUsageSnapshot(
            providerId: "claude-code",
            displayName: "Claude Code",
            status: .warning,
            fetchedAt: Date(timeIntervalSince1970: 100),
            summary: "5h 90%",
            message: "Claude 接口限流",
            groups: [
                UsageGroup(
                    id: "claude",
                    title: "Claude Code",
                    subtitle: nil,
                    items: [
                        UsageMetric(
                            id: "claude-5h",
                            label: "5h",
                            kind: .quota,
                            usedPercent: 10,
                            remainingPercent: 90,
                            resetText: "4h",
                            status: .ok,
                            detail: nil
                        )
                    ]
                )
            ]
        )
        let failedAgain = ProviderUsageSnapshot(
            providerId: "claude-code",
            displayName: "Claude Code",
            status: .error,
            fetchedAt: Date(timeIntervalSince1970: 300),
            summary: nil,
            message: "Claude 接口返回 500",
            groups: []
        )

        let merged = ProviderSnapshotCache.merge(previous: [cachedWarning], refreshed: [failedAgain])

        XCTAssertEqual(merged.first?.status, .warning)
        XCTAssertEqual(merged.first?.summary, cachedWarning.summary)
        XCTAssertEqual(merged.first?.message, "Claude 接口返回 500")
        XCTAssertEqual(merged.first?.groups, cachedWarning.groups)
    }

    func testReadsAndWritesSuccessfulSnapshots() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cacheURL = directory.appendingPathComponent("snapshots.json")
        let snapshot = ProviderUsageSnapshot(
            providerId: "codex",
            displayName: "Codex",
            status: .ok,
            fetchedAt: Date(timeIntervalSince1970: 100),
            summary: "5h 80%",
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
                            usedPercent: 20,
                            remainingPercent: 80,
                            resetText: "4h",
                            status: .ok,
                            detail: nil,
                            resetAt: Date(timeIntervalSince1970: 1_000),
                            windowDurationMinutes: 300
                        )
                    ]
                )
            ]
        )

        try ProviderSnapshotDiskCache.write([snapshot], to: cacheURL)

        XCTAssertEqual(try ProviderSnapshotDiskCache.read(from: cacheURL), [snapshot])
    }

    func testWritesWarningSnapshotsWhenTheyStillHaveCachedGroups() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cacheURL = directory.appendingPathComponent("snapshots.json")
        let cachedWarning = ProviderUsageSnapshot(
            providerId: "claude-code",
            displayName: "Claude Code",
            status: .warning,
            fetchedAt: Date(timeIntervalSince1970: 100),
            summary: "5h 90%",
            message: "Claude 接口限流",
            groups: [
                UsageGroup(
                    id: "claude",
                    title: "Claude Code",
                    subtitle: nil,
                    items: [
                        UsageMetric(
                            id: "claude-5h",
                            label: "5h",
                            kind: .quota,
                            usedPercent: 10,
                            remainingPercent: 90,
                            resetText: "4h",
                            status: .ok,
                            detail: nil
                        )
                    ]
                )
            ]
        )
        let pureError = ProviderUsageSnapshot(
            providerId: "zhipu",
            displayName: "智谱",
            status: .error,
            fetchedAt: Date(timeIntervalSince1970: 120),
            summary: nil,
            message: "智谱接口失败",
            groups: []
        )

        try ProviderSnapshotDiskCache.write([cachedWarning, pureError], to: cacheURL)

        XCTAssertEqual(try ProviderSnapshotDiskCache.read(from: cacheURL), [cachedWarning])
    }

    func testMergePreservesResetCreditsWhenRefreshFails() {
        let previous = ProviderUsageSnapshot(
            providerId: "codex",
            displayName: "Codex",
            status: .ok,
            fetchedAt: Date(timeIntervalSince1970: 100),
            summary: "5h 90%",
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
                            usedPercent: 10,
                            remainingPercent: 90,
                            resetText: "4h",
                            status: .ok,
                            detail: nil
                        )
                    ]
                )
            ],
            resetCredits: ResetCreditSummary(
                availableCount: 1,
                credits: [
                    ResetCredit(
                        issuedAt: Date(timeIntervalSince1970: 10),
                        expiresAt: Date(timeIntervalSince1970: 20)
                    )
                ]
            )
        )
        let failed = ProviderUsageSnapshot(
            providerId: "codex",
            displayName: "Codex",
            status: .error,
            fetchedAt: Date(timeIntervalSince1970: 200),
            summary: nil,
            message: "Codex 接口失败",
            groups: []
        )

        let merged = ProviderSnapshotCache.merge(previous: [previous], refreshed: [failed])

        XCTAssertEqual(merged.first?.status, .warning)
        XCTAssertEqual(merged.first?.resetCredits?.availableCount, 1)
        XCTAssertEqual(merged.first?.resetCredits?.credits.count, 1)
    }

    func testMergePreservesResetCreditsWhenRefreshSucceedsWithoutResetCredits() {
        let previous = ProviderUsageSnapshot(
            providerId: "codex",
            displayName: "Codex",
            status: .ok,
            fetchedAt: Date(timeIntervalSince1970: 100),
            summary: "5h 90%",
            message: nil,
            groups: [],
            resetCredits: ResetCreditSummary(
                availableCount: 2,
                credits: [
                    ResetCredit(
                        issuedAt: Date(timeIntervalSince1970: 10),
                        expiresAt: Date(timeIntervalSince1970: 20)
                    )
                ]
            )
        )
        let refreshed = ProviderUsageSnapshot(
            providerId: "codex",
            displayName: "Codex",
            status: .ok,
            fetchedAt: Date(timeIntervalSince1970: 200),
            summary: "5h 100%",
            message: nil,
            groups: []
        )

        let merged = ProviderSnapshotCache.merge(previous: [previous], refreshed: [refreshed])

        XCTAssertEqual(merged.first?.status, .ok)
        XCTAssertEqual(merged.first?.summary, "5h 100%")
        XCTAssertEqual(merged.first?.resetCredits?.availableCount, 2)
    }
}
