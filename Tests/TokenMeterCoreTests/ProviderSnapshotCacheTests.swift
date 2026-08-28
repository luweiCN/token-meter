import XCTest
@testable import TokenMeterCore

final class ProviderSnapshotCacheTests: XCTestCase {
    /// OpenCode Go 形状的主组：5h + Weekly + Monthly 三窗（弹窗环取前两只）。
    private static func opencodeSnapshot(
        fetchedAt: Date,
        fiveHour: UsageMetric? = nil,
        weeklyPercent: Double = 53.9,
        monthlyPercent: Double = 71.9
    ) -> ProviderUsageSnapshot {
        var items: [UsageMetric] = []
        if let fiveHour { items.append(fiveHour) }
        items.append(UsageMetric(
            id: "opencode-go-weekly", label: "7d", kind: .quota,
            usedPercent: weeklyPercent, remainingPercent: 100 - weeklyPercent,
            resetText: "5d13h", status: .ok, detail: nil,
            resetAt: fetchedAt.addingTimeInterval(5 * 86_400),
            windowDurationMinutes: 7 * 24 * 60
        ))
        items.append(UsageMetric(
            id: "opencode-go-monthly", label: "Monthly", kind: .quota,
            usedPercent: monthlyPercent, remainingPercent: 100 - monthlyPercent,
            resetText: "9d19h", status: .ok, detail: nil,
            resetAt: fetchedAt.addingTimeInterval(10 * 86_400),
            windowDurationMinutes: 30 * 24 * 60
        ))
        return ProviderUsageSnapshot(
            providerId: "opencode-go",
            displayName: "OpenCode Go",
            status: .ok,
            fetchedAt: fetchedAt,
            summary: nil,
            message: nil,
            groups: [UsageGroup(id: "opencode-go", title: "OpenCode Go", subtitle: nil, items: items)]
        )
    }

    private static func fiveHourMetric(
        remaining: Double,
        resetAt: Date
    ) -> UsageMetric {
        UsageMetric(
            id: "opencode-go-5h", label: "5h", kind: .quota,
            usedPercent: 100 - remaining, remainingPercent: remaining,
            resetText: "1h49m", status: .ok, detail: nil,
            resetAt: resetAt,
            windowDurationMinutes: 5 * 60
        )
    }

    func testVanishedWindowWithFutureResetIsCarriedOverWithOriginalValues() {
        // 实测场景：额度还剩 ~19% 时 dashboard 某轮整行漏渲染。必须沿用上一轮数值，
        // 而不是武断标成用尽；且要插回 Weekly 前的原位。
        let now = Date(timeIntervalSince1970: 1_000_000)
        let previous = Self.opencodeSnapshot(
            fetchedAt: now.addingTimeInterval(-300),
            fiveHour: Self.fiveHourMetric(remaining: 18.7, resetAt: now.addingTimeInterval(6_500))
        )
        let refreshed = Self.opencodeSnapshot(fetchedAt: now)

        let merged = ProviderSnapshotCache.merge(previous: [previous], refreshed: [refreshed], now: now)

        let group = merged[0].groups[0]
        XCTAssertEqual(group.items.count, 3, "消失的 5h 必须被沿用回来")
        XCTAssertEqual(group.items[0].id, "opencode-go-5h", "按时长插回最前")
        XCTAssertEqual(group.items[0].remainingPercent, 18.7, "沿用上一轮真实剩余，不得改写成用尽")
        XCTAssertEqual(group.items[0].status, .ok)
        XCTAssertEqual(group.items[0].resetText, "1h49m")
        // 其余窗口不受影响。
        XCTAssertEqual(group.items[1].id, "opencode-go-weekly")
        XCTAssertEqual(group.items[2].id, "opencode-go-monthly")
    }

    func testVanishedWindowWhoseResetAlreadyPassedIsNotCarriedOver() {
        // 重置时刻已过仍不见该行 → 视作真的没有此窗口，不再沿用。
        let now = Date(timeIntervalSince1970: 1_000_000)
        let previous = Self.opencodeSnapshot(
            fetchedAt: now.addingTimeInterval(-300),
            fiveHour: Self.fiveHourMetric(remaining: 40, resetAt: now.addingTimeInterval(-60))
        )
        let refreshed = Self.opencodeSnapshot(fetchedAt: now)

        let merged = ProviderSnapshotCache.merge(previous: [previous], refreshed: [refreshed], now: now)

        XCTAssertFalse(merged[0].groups[0].items.contains { $0.id == "opencode-go-5h" })
    }

    func testPresentWindowsUseFreshDataAndVanishedOnesAreCarriedBack() {
        // 本轮还在的窗口必须用本轮新数据；同轮消失的另一窗口则从上一轮沿回。
        let now = Date(timeIntervalSince1970: 1_000_000)
        let previous = Self.opencodeSnapshot(
            fetchedAt: now.addingTimeInterval(-300),
            fiveHour: Self.fiveHourMetric(remaining: 80, resetAt: now.addingTimeInterval(3_600))
        )
        // 本轮快照缺 monthly 行（模拟同轮漏渲染）。
        var refreshed = Self.opencodeSnapshot(fetchedAt: now, fiveHour: Self.fiveHourMetric(remaining: 75, resetAt: now.addingTimeInterval(3_600)))
        let staleMonthly = refreshed.groups[0].items.first { $0.id == "opencode-go-monthly" }
        let trimmedItems = refreshed.groups[0].items.filter { $0.id != "opencode-go-monthly" }
        refreshed = ProviderUsageSnapshot(
            providerId: refreshed.providerId,
            displayName: refreshed.displayName,
            status: refreshed.status,
            fetchedAt: refreshed.fetchedAt,
            summary: refreshed.summary,
            message: refreshed.message,
            groups: [UsageGroup(id: "opencode-go", title: "OpenCode Go", subtitle: nil, items: trimmedItems)],
            resetCredits: refreshed.resetCredits
        )

        let merged = ProviderSnapshotCache.merge(previous: [previous], refreshed: [refreshed], now: now)

        let items = merged[0].groups[0].items
        XCTAssertEqual(items.first { $0.id == "opencode-go-5h" }?.remainingPercent, 75, "本轮还在的窗口用本轮数据")
        XCTAssertEqual(items.first { $0.id == "opencode-go-monthly" }?.remainingPercent,
                       staleMonthly?.remainingPercent, "同轮消失的窗口沿用上一轮")
    }

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

    func testKeepsPreviousRemainingWhenFailedRefreshUsesDummyErrorGroup() {
        // 生产路径 providerErrorSnapshot 会塞一条无百分比的「状态」组，不是空 groups。
        // 菜单栏环只认 usedPercent；若合并把这条当成新数据，12% 会从菜单栏消失。
        let previous = ProviderUsageSnapshot(
            providerId: "grok",
            displayName: "Grok Build",
            status: .ok,
            fetchedAt: Date(timeIntervalSince1970: 100),
            summary: "7d 12%",
            message: nil,
            groups: [
                UsageGroup(
                    id: "grok",
                    title: "Grok Build",
                    subtitle: nil,
                    items: [
                        UsageMetric(
                            id: "grok-7d",
                            label: "7d",
                            kind: .quota,
                            usedPercent: 88,
                            remainingPercent: 12,
                            resetText: "5d",
                            status: .ok,
                            detail: nil,
                            windowDurationMinutes: 10_080
                        )
                    ]
                )
            ]
        )
        let failed = providerErrorSnapshot(
            providerId: "grok",
            displayName: "Grok Build",
            message: "未检测到 Grok 命令行"
        )

        let merged = ProviderSnapshotCache.merge(previous: [previous], refreshed: [failed])

        XCTAssertEqual(merged[0].status, .warning)
        XCTAssertEqual(merged[0].groups[0].items[0].remainingPercent, 12)
        XCTAssertEqual(merged[0].message, "未检测到 Grok 命令行")
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

    func testDoesNotPersistDummyErrorGroupsWithoutPercents() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cacheURL = directory.appendingPathComponent("snapshots.json")
        let dummyError = providerErrorSnapshot(
            providerId: "grok",
            displayName: "Grok Build",
            message: "未检测到 Grok 命令行"
        )
        XCTAssertFalse(dummyError.groups.isEmpty, "生产 error 快照带占位组，不能靠 groups.isEmpty 过滤")

        try ProviderSnapshotDiskCache.write([dummyError], to: cacheURL)

        XCTAssertEqual(try ProviderSnapshotDiskCache.read(from: cacheURL), [])
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
