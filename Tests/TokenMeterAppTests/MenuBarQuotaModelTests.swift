import XCTest
@testable import TokenMeterApp
@testable import TokenMeterCore

@MainActor
final class MenuBarQuotaModelTests: XCTestCase {
    private func metric(id: String, used: Double, windowMinutes: Int?, status: UsageStatus = .ok) -> UsageMetric {
        UsageMetric(
            id: id,
            label: "x",
            kind: .quota,
            usedPercent: used,
            remainingPercent: 100 - used,
            resetText: nil,
            status: status,
            detail: nil,
            resetAt: nil,
            windowDurationMinutes: windowMinutes
        )
    }

    private func snapshot(
        _ providerId: String,
        _ displayName: String,
        groups: [UsageGroup],
        fetchedAt: Date = Date()
    ) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            providerId: providerId,
            displayName: displayName,
            status: .ok,
            fetchedAt: fetchedAt,
            summary: nil,
            message: nil,
            groups: groups
        )
    }

    /// 双窗供应商快照：5h 与 7d 各一个百分比窗口。
    private func twoWindowSnapshot(
        _ providerId: String = "claude-code",
        _ displayName: String = "Claude Code",
        shortRemaining: Double,
        longRemaining: Double,
        fetchedAt: Date = Date()
    ) -> ProviderUsageSnapshot {
        snapshot(providerId, displayName, groups: [
            UsageGroup(id: providerId, title: displayName, subtitle: nil, items: [
                metric(id: "\(providerId)-5h", used: 100 - shortRemaining, windowMinutes: 300),
                metric(id: "\(providerId)-7d", used: 100 - longRemaining, windowMinutes: 10_080)
            ])
        ], fetchedAt: fetchedAt)
    }

    private func settings(
        style: MenuBarStyleId = .rings,
        name: Bool = true,
        glyph: Bool = true,
        number: Bool = true,
        usage: MenuBarUsageTail = .tok,
        order: MenuBarWindowOrder = .longFirst,
        overrides: [ProviderConfigOverride] = []
    ) -> SettingsSnapshot {
        SettingsSnapshot(
            version: 1,
            menuBarPrimaryProviderId: nil,
            autoRefreshSeconds: 300,
            enabledAgentKinds: [],
            providerOverrides: overrides,
            quotaUsedThresholdPercent: 0,
            menuBarAppearance: MenuBarAppearanceSettings(
                style: style, showName: name, showGlyph: glyph, showNumber: number,
                usage: usage, windowOrder: order
            )
        )
    }

    /// 直接构造 Cell（纯函数测试用；窗口 label 语义与真实投影一致）。
    private func cell(
        _ providerId: String,
        badge: String = "CC",
        mono: String = "C",
        short: (Double, UsageMetricTone)? = nil,
        long: (Double, UsageMetricTone),
        staleMinutes: Int? = nil,
        glyphChoice: MenuBarWindowChoice = .both,
        numberChoice: MenuBarWindowChoice = .both
    ) -> MenuBarQuotaModel.Cell {
        MenuBarQuotaModel.Cell(
            providerId: providerId,
            badge: badge,
            mono: mono,
            shortWindow: short.map { MenuBarQuotaModel.Window(label: "5h", remainingPercent: $0.0, tone: $0.1) },
            longWindow: MenuBarQuotaModel.Window(label: "7d", remainingPercent: long.0, tone: long.1),
            staleMinutes: staleMinutes,
            glyphChoice: glyphChoice,
            numberChoice: numberChoice
        )
    }

    // MARK: - 迁移用例（原 cells(from:) 语义在 projection 下保持）

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

        let projection = MenuBarQuotaModel.projection(snapshots: snapshots, settings: nil, todaySummary: .empty)

        XCTAssertEqual(projection.cells.count, 1)
        XCTAssertEqual(projection.cells[0].providerId, "claude-code")
        // 短名 = displayName 首词:菜单栏里「Cl/Co」认不出是谁(用户裁定)。
        XCTAssertEqual(projection.cells[0].badge, "Claude")
        XCTAssertEqual(projection.cells[0].shortWindow?.label, "5h")
        XCTAssertEqual(projection.cells[0].shortWindow?.remainingPercent, 64.0)
        XCTAssertEqual(projection.cells[0].longWindow.label, "7d")
        XCTAssertEqual(projection.cells[0].longWindow.remainingPercent, 95.0)
    }

    /// Codex 已取消 5h:主组只剩 7d 一个窗口,唯一窗恒放 longWindow。
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

        let projection = MenuBarQuotaModel.projection(snapshots: snapshots, settings: nil, todaySummary: .empty)

        XCTAssertEqual(projection.cells.count, 1)
        XCTAssertTrue(projection.cells[0].isSingleWindow)
        XCTAssertNil(projection.cells[0].shortWindow)
        XCTAssertEqual(projection.cells[0].longWindow.remainingPercent, 95.0)
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

        let projection = MenuBarQuotaModel.projection(snapshots: snapshots, settings: nil, todaySummary: .empty)

        XCTAssertEqual(projection.cells.map(\.providerId), ["codex"])
    }

    // MARK: - 窗口选择与顺序

    func testWindowOrderControlsBothExpansion() {
        let projection = MenuBarQuotaModel.projection(
            snapshots: [twoWindowSnapshot(shortRemaining: 96, longRemaining: 55)],
            settings: settings(order: .longFirst),
            todaySummary: .empty
        )
        let cell = projection.cells[0]
        XCTAssertEqual(cell.glyphWindows(order: .longFirst).map(\.roundedPercent), [55, 96])
        XCTAssertEqual(cell.glyphWindows(order: .shortFirst).map(\.roundedPercent), [96, 55])
        XCTAssertEqual(projection.windowOrder, .longFirst)
    }

    func testPerProviderChoiceSplitsGlyphAndNumberWindows() {
        let overrides = [
            ProviderConfigOverride(
                providerId: "claude-code", enabled: nil, displayName: nil, menuRank: nil,
                showInMenuBar: nil, showInCharts: nil,
                menuBarGlyphWindow: .both, menuBarNumberWindow: .short
            )
        ]
        let projection = MenuBarQuotaModel.projection(
            snapshots: [twoWindowSnapshot(shortRemaining: 96, longRemaining: 55)],
            settings: settings(overrides: overrides),
            todaySummary: .empty
        )
        let cell = projection.cells[0]
        XCTAssertEqual(cell.glyphWindows(order: .longFirst).count, 2)
        XCTAssertEqual(cell.numberWindows(order: .longFirst).map(\.roundedPercent), [96])
    }

    func testSingleWindowProviderIgnoresChoice() {
        let single = cell("codex", short: nil, long: (95, .ok), glyphChoice: .short, numberChoice: .short)
        XCTAssertEqual(single.glyphWindows(order: .longFirst).map(\.roundedPercent), [95])
        XCTAssertEqual(single.numberWindows(order: .shortFirst).map(\.roundedPercent), [95])
    }

    func testWorstPicksLowestRemaining() {
        let c = cell("claude-code", short: (96, .ok), long: (55, .warning))
        XCTAssertEqual(c.worstNumberWindow.roundedPercent, 55)
        XCTAssertEqual(c.worstNumberWindow.tone, .warning)
    }

    // MARK: - 元素锁定与兜底（spec §3 表）

    func testEffectiveElementsLockTable() {
        // digits：无图形维度
        var e = MenuBarQuotaModel.effectiveElements(style: .digits, showName: true, showGlyph: true, showNumber: true)
        XCTAssertFalse(e.glyph)
        // monogram：字符即名称，name 锁开、glyph 锁关
        e = MenuBarQuotaModel.effectiveElements(style: .monogram, showName: false, showGlyph: true, showNumber: false)
        XCTAssertTrue(e.name); XCTAssertFalse(e.glyph)
        // tagnum/deck2：数字为本体、无图形
        e = MenuBarQuotaModel.effectiveElements(style: .tagnum, showName: true, showGlyph: true, showNumber: false)
        XCTAssertFalse(e.glyph); XCTAssertTrue(e.number)
        // 混合系：图形与数字均为本体
        e = MenuBarQuotaModel.effectiveElements(style: .ringdeck, showName: false, showGlyph: false, showNumber: false)
        XCTAssertTrue(e.glyph); XCTAssertTrue(e.number)
        // 聚合图形支：图形为本体
        e = MenuBarQuotaModel.effectiveElements(style: .strip, showName: true, showGlyph: false, showNumber: true)
        XCTAssertTrue(e.glyph)
    }

    func testAtLeastOneElementFallback() {
        // 普通样式全关 → 图形兜底
        var e = MenuBarQuotaModel.effectiveElements(style: .rings, showName: false, showGlyph: false, showNumber: false)
        XCTAssertTrue(e.glyph); XCTAssertFalse(e.name); XCTAssertFalse(e.number)
        // digits 全关（图形维度不存在）→ 数字兜底
        e = MenuBarQuotaModel.effectiveElements(style: .digits, showName: false, showGlyph: false, showNumber: false)
        XCTAssertTrue(e.number); XCTAssertFalse(e.glyph)
    }

    // MARK: - 单字符标去重

    func testMonogramDeduplicates() {
        XCTAssertEqual(
            MenuBarQuotaModel.monograms(for: ["CC", "CX", "智谱", "OMP"]),
            ["C", "X", "智", "O"]
        )
        // 全占用回落首字符
        XCTAssertEqual(MenuBarQuotaModel.monograms(for: ["A", "A"]), ["A", "A"])
    }

    // MARK: - 哨兵三态

    func testSentinelQuietAlertAndStale() {
        let green = cell("claude-code", short: (96, .ok), long: (55, .ok))
        let warn = cell("codex", badge: "CX", mono: "X", short: (34, .warning), long: (18, .warning))
        let bad = cell("zhipu", badge: "智谱", mono: "智", short: (8, .bad), long: (55, .ok))
        let stale12 = cell("omp", badge: "OMP", mono: "O", short: nil, long: (71, .ok), staleMinutes: 12)

        XCTAssertEqual(MenuBarQuotaModel.sentinelState(cells: [green]), .quiet)

        if case let .alert(cell, window) = MenuBarQuotaModel.sentinelState(cells: [warn, bad]) {
            XCTAssertEqual(cell.providerId, "zhipu")
            XCTAssertEqual(window.tone, .bad)
        } else {
            XCTFail("expected alert")
        }

        XCTAssertEqual(
            MenuBarQuotaModel.sentinelState(cells: [green, stale12]),
            .stale(minutes: 12)
        )
    }

    // MARK: - 超宽降级与 stale

    func testDigitsCJKDualDegradesToWorst() {
        let zhipu = cell("zhipu", badge: "智谱", mono: "智", short: (8, .bad), long: (55, .ok))
        XCTAssertTrue(MenuBarQuotaModel.numbersDegradeToWorst(style: .digits, cell: zhipu, showName: true))
        XCTAssertFalse(MenuBarQuotaModel.numbersDegradeToWorst(style: .digits, cell: zhipu, showName: false))
        let latin = cell("claude-code", short: (96, .ok), long: (55, .ok))
        XCTAssertFalse(MenuBarQuotaModel.numbersDegradeToWorst(style: .digits, cell: latin, showName: true))
        XCTAssertFalse(MenuBarQuotaModel.numbersDegradeToWorst(style: .rings, cell: zhipu, showName: true))
    }

    func testStaleCellCarriesMinutes() {
        let projection = MenuBarQuotaModel.projection(
            snapshots: [twoWindowSnapshot(shortRemaining: 96, longRemaining: 55, fetchedAt: Date(timeIntervalSinceNow: -720))],
            settings: nil,
            todaySummary: .empty
        )
        XCTAssertEqual(projection.cells[0].staleMinutes, 12)
        XCTAssertTrue(projection.cells[0].isStale)
    }

    // MARK: - 按家隐藏与尾巴

    func testCellsFilteredByShowInMenuBar() {
        let overrides = [
            ProviderConfigOverride(
                providerId: "codex", enabled: nil, displayName: nil, menuRank: nil,
                showInMenuBar: false, showInCharts: nil
            )
        ]
        let projection = MenuBarQuotaModel.projection(
            snapshots: [
                twoWindowSnapshot("claude-code", "Claude Code", shortRemaining: 96, longRemaining: 55),
                twoWindowSnapshot("codex", "Codex", shortRemaining: 70, longRemaining: 30)
            ],
            settings: settings(overrides: overrides),
            todaySummary: .empty
        )
        XCTAssertEqual(projection.cells.map(\.providerId), ["claude-code"])
    }

    func testTailTokCostOffAndZeroHidden() {
        let summary = MenuBarTodaySummary(
            tokens: 3_400_000, costUsdMicros: 196_440_000, sessions: 3, unknownEvents: 0, perProvider: []
        )
        var projection = MenuBarQuotaModel.projection(snapshots: [], settings: settings(usage: .tok), todaySummary: summary)
        XCTAssertEqual(projection.tail, .text("3.4M"))

        projection = MenuBarQuotaModel.projection(snapshots: [], settings: settings(usage: .cost), todaySummary: summary)
        XCTAssertEqual(projection.tail, .text("$196.44"))

        projection = MenuBarQuotaModel.projection(snapshots: [], settings: settings(usage: .off), todaySummary: summary)
        XCTAssertEqual(projection.tail, .hidden)

        projection = MenuBarQuotaModel.projection(snapshots: [], settings: settings(usage: .tok), todaySummary: .empty)
        XCTAssertEqual(projection.tail, .hidden)
    }
}
