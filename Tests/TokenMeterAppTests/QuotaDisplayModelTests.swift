import XCTest
@testable import TokenMeterApp
@testable import TokenMeterCore

@MainActor
final class QuotaDisplayModelTests: XCTestCase {
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

    /// 锁住弹窗的环/条分配规则：主组（组名与 provider 同名）进环、标签只留窗口；
    /// 模型级额度（Sonnet/Fable/Spark…）一律水平条、标签带模型名；数值为【剩余】。
    /// seven_day_sonnet 哪天非空，解析出的 Sonnet 组走的就是这条路径。
    func testPrimaryGroupFeedsRingsAndModelGroupsBecomeBars() {
        let snapshot = ProviderUsageSnapshot(
            providerId: "claude-code",
            displayName: "Claude Code",
            status: .ok,
            fetchedAt: Date(),
            summary: "",
            message: nil,
            groups: [
                UsageGroup(id: "claude", title: "Claude Code", subtitle: nil, items: [
                    metric(id: "claude-5h", used: 36, windowMinutes: 300),
                    metric(id: "claude-7d", used: 5, windowMinutes: 10_080)
                ]),
                UsageGroup(id: "sonnet", title: "Sonnet", subtitle: nil, items: [
                    metric(id: "claude-sonnet", used: 44, windowMinutes: 10_080)
                ]),
                UsageGroup(id: "fable", title: "Fable", subtitle: nil, items: [
                    metric(id: "claude-fable", used: 9, windowMinutes: 10_080)
                ])
            ]
        )

        let model = QuotaDisplayModel(snapshot: snapshot)

        XCTAssertEqual(model.rings.map(\.label), ["5h", "7d"])
        XCTAssertEqual(model.rings.map(\.percent), [64.0, 95.0])
        XCTAssertEqual(model.bars.map(\.label), ["Sonnet 7d", "Fable 7d"])
        XCTAssertEqual(model.bars.map(\.percent), [56.0, 91.0])
    }

    /// 智谱主组 5h/7d/MCP 三指标只有前两个有窗口时长（MCP 是次数额度）：
    /// 环只给 5h/7d，MCP 降为水平条、保留 detail（已用/总次数）。
    func testZhipuMcpBecomesBarNotRing() {
        let mcp = UsageMetric(
            id: "zhipu-mcp", label: "MCP", kind: .quota,
            usedPercent: 3, remainingPercent: 97, resetText: "10d15h", status: .ok,
            detail: "152/4000 次", resetAt: Date(), windowDurationMinutes: nil
        )
        let snapshot = ProviderUsageSnapshot(
            providerId: "zhipu",
            displayName: "智谱",
            status: .ok,
            fetchedAt: Date(),
            summary: "",
            message: nil,
            groups: [
                UsageGroup(id: "zhipu-coding-plan", title: "智谱", subtitle: nil, items: [
                    metric(id: "zhipu-5h", used: 18, windowMinutes: 300),
                    metric(id: "zhipu-7d", used: 34, windowMinutes: 10_080),
                    mcp
                ])
            ]
        )

        let model = QuotaDisplayModel(snapshot: snapshot)

        XCTAssertEqual(model.rings.map(\.label), ["5h", "7d"])
        XCTAssertEqual(model.bars.map(\.label), ["MCP"])
        XCTAssertEqual(model.bars.map(\.percent), [97.0])
        XCTAssertEqual(model.bars.first?.note, "152/4000 次")
    }

    /// OpenCode 主组 5h/7d/Monthly 三指标都有窗口时长，但一行最多两只环：
    /// 5h/7d 进环，Monthly（30d）降为水平条、note 带重置倒计时。
    func testOpenCodeMonthlyBecomesBarNotRing() {
        let snapshot = ProviderUsageSnapshot(
            providerId: "opencode-go",
            displayName: "OpenCode Go",
            status: .ok,
            fetchedAt: Date(),
            summary: "",
            message: nil,
            groups: [
                UsageGroup(id: "opencode-go", title: "OpenCode Go", subtitle: nil, items: [
                    metric(id: "opencode-go-5h", used: 1, windowMinutes: 300),
                    metric(id: "opencode-go-weekly", used: 9, windowMinutes: 10_080),
                    UsageMetric(
                        id: "opencode-go-monthly", label: "Monthly", kind: .quota,
                        usedPercent: 4, remainingPercent: 96, resetText: "26d12h", status: .ok,
                        detail: nil, resetAt: Date(), windowDurationMinutes: 43_200
                    )
                ])
            ]
        )

        let model = QuotaDisplayModel(snapshot: snapshot)

        XCTAssertEqual(model.rings.map(\.label), ["5h", "7d"])
        XCTAssertEqual(model.rings.map(\.percent), [99.0, 91.0])
        XCTAssertEqual(model.bars.map(\.label), ["30d"])
        XCTAssertEqual(model.bars.map(\.percent), [96.0])
        XCTAssertEqual(model.bars.first?.note, "26d12h")
    }

    private func pacedMetric(id: String, used: Double, windowMinutes: Int, secondsLeft: TimeInterval) -> UsageMetric {
        UsageMetric(
            id: id,
            label: "x",
            kind: .quota,
            usedPercent: used,
            remainingPercent: 100 - used,
            resetText: nil,
            status: .ok,
            detail: nil,
            resetAt: Date().addingTimeInterval(secondsLeft),
            windowDurationMinutes: windowMinutes
        )
    }

    /// 环的颜色走时间进度感知（tmux 同款 pace 逻辑）：
    /// 7 天窗口刚过半就烧掉 80% → 红；还剩 1 小时才重置、剩 10% 也算绿。
    func testRingToneFollowsPaceNotRawRemaining() {
        let snapshot = ProviderUsageSnapshot(
            providerId: "claude-code",
            displayName: "Claude Code",
            status: .ok,
            fetchedAt: Date(),
            summary: "",
            message: nil,
            groups: [
                UsageGroup(id: "claude", title: "Claude Code", subtitle: nil, items: [
                    // 7d 窗口还剩 3.5 天（时间进度 50%），已用 80% → 明显跑赢进度 → bad
                    pacedMetric(id: "burn", used: 80, windowMinutes: 10_080, secondsLeft: 3.5 * 86_400),
                    // 7d 窗口还剩 1 小时，已用 90%（低于时间进度 ~99.4%）→ ok
                    pacedMetric(id: "fine", used: 90, windowMinutes: 10_080, secondsLeft: 3_600)
                ])
            ]
        )

        let model = QuotaDisplayModel(snapshot: snapshot)

        XCTAssertEqual(model.rings.count, 2)
        XCTAssertEqual(model.rings[0].tone, .bad)
        XCTAssertEqual(model.rings[1].tone, .ok)
    }

    /// 折叠行摘要各段跟随环的 tone：收起时也能看出哪个窗口在警戒。
    func testSummarySegmentsCarryRingTones() {
        let now = Date()
        let snapshot = ProviderUsageSnapshot(
            providerId: "claude-code", displayName: "Claude Code", status: .ok, fetchedAt: now,
            summary: "", message: nil,
            groups: [
                UsageGroup(id: "claude", title: "Claude Code", subtitle: nil, items: [
                    pacedMetric(id: "burn", used: 80, windowMinutes: 10_080, secondsLeft: 3.5 * 86_400),
                    pacedMetric(id: "fine", used: 90, windowMinutes: 10_080, secondsLeft: 3_600)
                ])
            ]
        )

        let model = QuotaDisplayModel(snapshot: snapshot, now: now)

        XCTAssertEqual(model.summarySegments.map(\.tone), [.bad, .ok])
        XCTAssertEqual(model.summaryText, model.summarySegments.map(\.text).joined(separator: " · "))
    }

    func testWarnStatusOrDepletionOverridesPaceTone() {
        let depleted = UsageMetric(
            id: "empty", label: "x", kind: .quota,
            usedPercent: 100, remainingPercent: 0, resetText: nil, status: .ok, detail: nil,
            resetAt: Date().addingTimeInterval(60), windowDurationMinutes: 300
        )
        let snapshot = ProviderUsageSnapshot(
            providerId: "codex", displayName: "Codex", status: .ok, fetchedAt: Date(),
            summary: "", message: nil,
            groups: [UsageGroup(id: "codex", title: "Codex", subtitle: nil, items: [depleted])]
        )

        // 用尽（哪怕马上重置、pace 判定会给 ok）必须红——0% 时没有"够用"一说。
        XCTAssertEqual(QuotaDisplayModel(snapshot: snapshot).rings[0].tone, .bad)
    }
}
