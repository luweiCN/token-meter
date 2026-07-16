import XCTest
@testable import TokenMeterCore

final class UsageFormatterTests: XCTestCase {
    func testMenuBarTitleShowsTodayTokensCompactly() {
        // 菜单栏主标题 = 今日 token 总量的 K/M 缩写（用户裁定：不显示「服务商 剩余%」）。
        // 单日数字永远停在 M——1 位小数的 B 会把百万级变化吞掉（用户裁定）。
        XCTAssertEqual(UsageFormatter.menuBarTitle(todayTokens: 775), "775")
        XCTAssertEqual(UsageFormatter.menuBarTitle(todayTokens: 3_400), "3.4K")
        XCTAssertEqual(UsageFormatter.menuBarTitle(todayTokens: 521_319_916), "521.3M")
        XCTAssertEqual(UsageFormatter.menuBarTitle(todayTokens: 2_398_499_879), "2398.5M")
    }

    func testMenuBarTitleFallsBackToProductNameWhenNoTokensToday() {
        // 0（刚过午夜/库为空）不显示孤零零的 "0"，回落到产品名。
        XCTAssertEqual(UsageFormatter.menuBarTitle(todayTokens: 0), "TokenMeter")
    }

    func testMenuBarTitleUsesPrimaryProvider() {
        let snapshots = [
            UsageSnapshot(
                providerId: "codex",
                displayName: "Codex",
                status: .ok,
                label: "今日",
                used: 1200,
                remaining: 8800,
                total: 10000,
                unit: "tokens",
                fetchedAt: Date(timeIntervalSince1970: 0),
                message: nil
            ),
            UsageSnapshot(
                providerId: "zhipu",
                displayName: "智谱",
                status: .ok,
                label: "余额",
                used: 12.3,
                remaining: 87.7,
                total: 100,
                unit: "CNY",
                fetchedAt: Date(timeIntervalSince1970: 0),
                message: nil
            )
        ]

        let title = UsageFormatter.menuBarTitle(for: snapshots, primaryProviderId: "zhipu")

        XCTAssertEqual(title, "智谱 87.7 CNY")
    }

    func testMenuBarTitleFallsBackWhenNoSnapshotsExist() {
        XCTAssertEqual(UsageFormatter.menuBarTitle(for: [UsageSnapshot](), primaryProviderId: nil), "TokenMeter")
    }

    func testMenuBarTitleShowsProblemStatus() {
        let snapshots = [
            UsageSnapshot(
                providerId: "zhipu",
                displayName: "智谱",
                status: .error,
                label: "余额",
                used: nil,
                remaining: nil,
                total: nil,
                unit: nil,
                fetchedAt: Date(timeIntervalSince1970: 0),
                message: "missing credential"
            )
        ]

        let title = UsageFormatter.menuBarTitle(for: snapshots, primaryProviderId: "zhipu")

        XCTAssertEqual(title, "智谱 异常")
    }

    func testDetailLineIncludesUsedAndRemainingValues() {
        let snapshot = UsageSnapshot(
            providerId: "codex",
            displayName: "Codex",
            status: .ok,
            label: "今日",
            used: 1200,
            remaining: 8800,
            total: 10000,
            unit: "tokens",
            fetchedAt: Date(timeIntervalSince1970: 0),
            message: nil
        )

        XCTAssertEqual(
            UsageFormatter.detailLine(for: snapshot),
            "Codex：已用 1200 tokens，剩余 8800 tokens"
        )
    }

    func testMenuBarTitleDoesNotInsertSpaceBeforePercentUnit() {
        let snapshots = [
            UsageSnapshot(
                providerId: "codex",
                displayName: "Codex",
                status: .ok,
                label: "额度",
                used: 31,
                remaining: 69,
                total: 100,
                unit: "%",
                fetchedAt: Date(timeIntervalSince1970: 0),
                message: "codex 5h 69%"
            )
        ]

        XCTAssertEqual(UsageFormatter.menuBarTitle(for: snapshots, primaryProviderId: "codex"), "Codex 69%")
    }

    func testMenuBarTitleUsesPrimaryProviderFirstMetric() {
        let snapshots = [
            ProviderUsageSnapshot(
                providerId: "codex",
                displayName: "Codex",
                status: .ok,
                fetchedAt: Date(timeIntervalSince1970: 0),
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
                                usedPercent: 52,
                                remainingPercent: 48,
                                resetText: "3h12m",
                                status: .ok,
                                detail: nil
                            )
                        ]
                    )
                ]
            ),
            ProviderUsageSnapshot(
                providerId: "zhipu",
                displayName: "智谱",
                status: .ok,
                fetchedAt: Date(timeIntervalSince1970: 0),
                summary: nil,
                message: nil,
                groups: [
                    UsageGroup(
                        id: "zhipu",
                        title: "智谱 Coding Plan",
                        subtitle: nil,
                        items: [
                            UsageMetric(
                                id: "zhipu-5h",
                                label: "5h",
                                kind: .quota,
                                usedPercent: 25,
                                remainingPercent: 75,
                                resetText: nil,
                                status: .ok,
                                detail: nil
                            )
                        ]
                    )
                ]
            )
        ]

        let title = UsageFormatter.menuBarTitle(for: snapshots, primaryProviderId: "zhipu")

        XCTAssertEqual(title, "智谱 75%")
    }

    func testMenuBarTitleUsesCachedMetricWhenProviderHasWarningStatus() {
        let snapshots = [
            ProviderUsageSnapshot(
                providerId: "claude-code",
                displayName: "Claude Code",
                status: .warning,
                fetchedAt: Date(timeIntervalSince1970: 0),
                summary: "Claude Code 5h 88%",
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
                                usedPercent: 12,
                                remainingPercent: 88,
                                resetText: "4h",
                                status: .ok,
                                detail: nil
                            )
                        ]
                    )
                ]
            )
        ]

        let title = UsageFormatter.menuBarTitle(for: snapshots, primaryProviderId: "claude-code")

        XCTAssertEqual(title, "Claude Code 88%")
    }
}
