import XCTest
@testable import TokenMeterApp
@testable import TokenMeterCore

@MainActor
final class MenuBarQuotaModelTests: XCTestCase {
    private func metric(id: String, used: Double, windowMinutes: Int?) -> UsageMetric {
        UsageMetric(
            id: id,
            label: "x",
            kind: .quota,
            usedPercent: used,
            remainingPercent: 100 - used,
            resetText: nil,
            status: .ok,
            detail: nil,
            resetAt: nil,
            windowDurationMinutes: windowMinutes
        )
    }

    private func snapshot(_ providerId: String, _ displayName: String, groups: [UsageGroup]) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            providerId: providerId,
            displayName: displayName,
            status: .ok,
            fetchedAt: Date(),
            summary: nil,
            message: nil,
            groups: groups
        )
    }

    /// 菜单栏额度 cell 与弹窗的环同一选取口径：主组前两个百分比窗口,
    /// 次要组(Fable/Spark 等模型级额度)不进菜单栏。
    func testProjectsPrimaryWindowsPerProvider() {
        let snapshots = [
            snapshot("claude-code", "Claude Code", groups: [
                UsageGroup(id: "claude", title: "Claude Code", subtitle: nil, items: [
                    metric(id: "claude-5h", used: 36, windowMinutes: 300),
                    metric(id: "claude-7d", used: 5, windowMinutes: 10_080)
                ]),
                UsageGroup(id: "fable", title: "Fable", subtitle: nil, items: [
                    metric(id: "claude-fable", used: 9, windowMinutes: 10_080)
                ])
            ])
        ]

        let cells = MenuBarQuotaModel.cells(from: snapshots)

        XCTAssertEqual(cells.count, 1)
        XCTAssertEqual(cells[0].providerId, "claude-code")
        // 短名 = displayName 首词:菜单栏里「Cl/Co」认不出是谁(用户裁定)。
        XCTAssertEqual(cells[0].badge, "Claude")
        XCTAssertEqual(cells[0].windows.map(\.label), ["5h", "7d"])
        XCTAssertEqual(cells[0].windows.map(\.remainingPercent), [64.0, 95.0])
    }

    /// Codex 已取消 5h:主组只剩 7d 一个窗口,cell 退化为单窗口(单条全高)。
    func testSingleWindowProviderYieldsSingleWindowCell() {
        let snapshots = [
            snapshot("codex", "Codex", groups: [
                UsageGroup(id: "codex", title: "Codex", subtitle: nil, items: [
                    metric(id: "codex-7d", used: 5, windowMinutes: 10_080)
                ]),
                UsageGroup(id: "spark", title: "GPT-5.3-Codex-Spark", subtitle: nil, items: [
                    metric(id: "codex-spark", used: 0, windowMinutes: 10_080)
                ])
            ])
        ]

        let cells = MenuBarQuotaModel.cells(from: snapshots)

        XCTAssertEqual(cells.count, 1)
        XCTAssertEqual(cells[0].windows.map(\.label), ["7d"])
        XCTAssertEqual(cells[0].windows.map(\.remainingPercent), [95.0])
    }

    /// 没有任何百分比额度的 provider(接口异常/纯余额型)不出 cell,不占菜单栏。
    func testProvidersWithoutPercentQuotasAreOmitted() {
        let snapshots = [
            snapshot("zhipu", "智谱", groups: []),
            snapshot("codex", "Codex", groups: [
                UsageGroup(id: "codex", title: "Codex", subtitle: nil, items: [
                    metric(id: "codex-7d", used: 40, windowMinutes: 10_080)
                ])
            ])
        ]

        let cells = MenuBarQuotaModel.cells(from: snapshots)

        XCTAssertEqual(cells.map(\.providerId), ["codex"])
    }
}
