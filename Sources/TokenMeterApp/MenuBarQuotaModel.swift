import Foundation
import TokenMeterCore

/// 菜单栏组件的数据投影：settings + snapshots + todaySummary → 渲染模型。
/// 纯函数、无 UI 依赖，16 种样式共用同一份 Cell；样式渲染差异全在
/// MenuBarStyleViews。规则权威：docs/superpowers/specs/2026-07-17-menubar-styles-implementation-design.md §2-3。
enum MenuBarQuotaModel {
    struct Window: Equatable {
        let label: String
        /// 剩余百分比（越大越充裕，与弹窗环同语义）。
        let remainingPercent: Double
        let tone: UsageMetricTone
        var roundedPercent: Int { Int(remainingPercent.rounded()) }
    }

    struct Cell: Equatable {
        let providerId: String
        /// 品牌短名（displayName 首词：「Claude」「Codex」「智谱」——缩写认不出是谁，用户裁定）。
        let badge: String
        /// 单字符标（monogram/tagnum 用，全组去重后注入）。
        let mono: String
        /// 短窗（5h 类）；单窗家为 nil——唯一窗恒放 longWindow（沿现状「last = 最长窗」口径）。
        let shortWindow: Window?
        let longWindow: Window
        /// 快照超时分钟数（QuotaDisplayModel 口径：≥10 分钟才非 nil）。
        let staleMinutes: Int?
        let glyphChoice: MenuBarWindowChoice
        let numberChoice: MenuBarWindowChoice

        var isStale: Bool { staleMinutes != nil }
        var isSingleWindow: Bool { shortWindow == nil }

        /// 窗口展开：单窗家无视 choice 恒取唯一窗；both 顺序由 windowOrder 决定。
        func windows(for choice: MenuBarWindowChoice, order: MenuBarWindowOrder) -> [Window] {
            guard let shortWindow else { return [longWindow] }
            switch choice {
            case .short: return [shortWindow]
            case .long: return [longWindow]
            case .both: return order == .shortFirst ? [shortWindow, longWindow] : [longWindow, shortWindow]
            }
        }

        func glyphWindows(order: MenuBarWindowOrder) -> [Window] { windows(for: glyphChoice, order: order) }
        func numberWindows(order: MenuBarWindowOrder) -> [Window] { windows(for: numberChoice, order: order) }
        var worstNumberWindow: Window { MenuBarQuotaModel.worst(of: windows(for: numberChoice, order: .longFirst)) }
        var worstGlyphWindow: Window { MenuBarQuotaModel.worst(of: windows(for: glyphChoice, order: .longFirst)) }
    }

    static func worst(of windows: [Window]) -> Window {
        windows.min { $0.remainingPercent < $1.remainingPercent }
            ?? Window(label: "", remainingPercent: 0, tone: .muted)
    }

    /// 哨兵样式的组件级状态（spec §3：红 > 黄 > 灰过期 > 安静）。
    enum SentinelState: Equatable {
        case quiet
        case alert(cell: Cell, window: Window)
        case stale(minutes: Int)
    }

    static func sentinelState(cells: [Cell]) -> SentinelState {
        let fresh = cells.filter { !$0.isStale }
        let alerts = fresh
            .map { (cell: $0, window: $0.worstNumberWindow) }
            .filter { $0.window.tone == .bad || $0.window.tone == .warning }
        if let hit = alerts.min(by: { lhs, rhs in
            let leftBad = lhs.window.tone == .bad
            let rightBad = rhs.window.tone == .bad
            if leftBad != rightBad { return leftBad }
            return lhs.window.remainingPercent < rhs.window.remainingPercent
        }) {
            return .alert(cell: hit.cell, window: hit.window)
        }
        if let minutes = cells.compactMap(\.staleMinutes).max() {
            return .stale(minutes: minutes)
        }
        return .quiet
    }

    /// 聚合样式的组件级最险数字（跳过 stale 家；数字窗口口径）。
    static func aggregateWorstNumber(cells: [Cell]) -> (cell: Cell, window: Window)? {
        cells.filter { !$0.isStale }
            .map { (cell: $0, window: $0.worstNumberWindow) }
            .min { $0.window.remainingPercent < $1.window.remainingPercent }
    }

    /// 元素开关的样式归一化（spec §3 锁定表 + 至少保一兜底）。
    /// Electron 设置页 elementLocks/stylePatch 与此同表，两端注释互指。
    static func effectiveElements(
        style: MenuBarStyleId, showName: Bool, showGlyph: Bool, showNumber: Bool
    ) -> (name: Bool, glyph: Bool, number: Bool) {
        var name = showName
        var glyph = showGlyph
        var number = showNumber
        switch style {
        case .digits:
            glyph = false
        case .monogram:
            name = true
            glyph = false
        case .tagnum, .deck2:
            glyph = false
            number = true
        case .ringdeck, .barsdeck:
            glyph = true
            number = true
        case .grid, .strip, .sentinel:
            glyph = true
        case .rings, .vbars, .hbar, .dots, .caps, .ticks, .ring1:
            break
        }
        if !name && !glyph && !number {
            if style == .digits { number = true } else { glyph = true }
        }
        return (name, glyph, number)
    }

    /// 文字样式的超宽降级（spec §2）：CJK 短名 + 双窗数字 + 名称开启 → 数字降最险单窗。
    static func numbersDegradeToWorst(style: MenuBarStyleId, cell: Cell, showName: Bool) -> Bool {
        guard style == .digits, showName, !cell.isSingleWindow, cell.numberChoice == .both else { return false }
        return cell.badge.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
    }

    /// 单字符标去重：依序取短名第一个未被占用的字符，全占用回落首字符。
    /// [CC, CX, 智谱, OMP] → [C, X, 智, O]（与设计稿 MONO_CH 一致）。
    static func monograms(for badges: [String]) -> [String] {
        var used = Set<String>()
        return badges.map { badge in
            let chars = badge.map(String.init)
            let pick = chars.first { !used.contains($0) } ?? chars.first ?? "?"
            used.insert(pick)
            return pick
        }
    }

    struct MenuBarProjection: Equatable {
        enum Tail: Equatable {
            case hidden
            case text(String)
        }

        let style: MenuBarStyleId
        let showName: Bool
        let showGlyph: Bool
        let showNumber: Bool
        let windowOrder: MenuBarWindowOrder
        let cells: [Cell]
        let tail: Tail
    }

    static func projection(
        snapshots: [ProviderUsageSnapshot],
        settings: SettingsSnapshot?,
        todaySummary: MenuBarTodaySummary,
        now: Date = Date()
    ) -> MenuBarProjection {
        let appearance = settings?.menuBarAppearance ?? .default
        let overrides = settings?.providerOverrides ?? []
        func override(_ id: String) -> ProviderConfigOverride? {
            overrides.first { $0.providerId == id }
        }

        var cells: [Cell] = snapshots.compactMap { snapshot in
            let providerOverride = override(snapshot.providerId)
            guard providerOverride?.showInMenuBar ?? true else { return nil }
            let model = QuotaDisplayModel(snapshot: snapshot, now: now)
            let windows = model.rings.map {
                Window(label: $0.label, remainingPercent: $0.percent, tone: $0.tone)
            }
            guard let longWindow = windows.last else { return nil }
            let shortName = snapshot.displayName.split(separator: " ").first.map(String.init)
                ?? snapshot.displayName
            return Cell(
                providerId: snapshot.providerId,
                badge: shortName,
                mono: "",
                shortWindow: windows.count > 1 ? windows.first : nil,
                longWindow: longWindow,
                staleMinutes: model.staleMinutes,
                glyphChoice: providerOverride?.menuBarGlyphWindow ?? .both,
                numberChoice: providerOverride?.menuBarNumberWindow ?? .both
            )
        }
        let monos = monograms(for: cells.map(\.badge))
        cells = zip(cells, monos).map { cell, mono in
            Cell(
                providerId: cell.providerId,
                badge: cell.badge,
                mono: mono,
                shortWindow: cell.shortWindow,
                longWindow: cell.longWindow,
                staleMinutes: cell.staleMinutes,
                glyphChoice: cell.glyphChoice,
                numberChoice: cell.numberChoice
            )
        }

        let elements = effectiveElements(
            style: appearance.style,
            showName: appearance.showName,
            showGlyph: appearance.showGlyph,
            showNumber: appearance.showNumber
        )

        let tail: MenuBarProjection.Tail
        switch appearance.usage {
        case .off:
            tail = .hidden
        case .tok:
            tail = todaySummary.tokens > 0
                ? .text(UsageFormatter.compactTokens(todaySummary.tokens))
                : .hidden
        case .cost:
            tail = todaySummary.costUsdMicros > 0
                ? .text(MenuBarNumberFormat.usd(todaySummary.costUsdMicros))
                : .hidden
        }

        return MenuBarProjection(
            style: appearance.style,
            showName: elements.name,
            showGlyph: elements.glyph,
            showNumber: elements.number,
            windowOrder: appearance.windowOrder,
            cells: cells,
            tail: tail
        )
    }
}
