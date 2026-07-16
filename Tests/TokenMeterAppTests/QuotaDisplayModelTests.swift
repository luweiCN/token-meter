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
