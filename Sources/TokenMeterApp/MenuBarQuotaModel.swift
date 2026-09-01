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
        /// 用户配置的完整显示名；空格属于名称内容，不能在投影层隐式截断。
        let badge: String
        /// 单字符标（monogram/tagnum 用，全组去重后注入）。
        let mono: String
        /// 短窗（5h 类）；单窗家为 nil——唯一窗恒放 longWindow（沿现状「last = 最长窗」口径）。
        let shortWindow: Window?
        let longWindow: Window
        /// 全部窗口（OpenCode Go / Command Code 的 5h/周/月三只平级）；双窗家与 short+long 同构。
        let allWindows: [Window]
        let glyphChoice: MenuBarWindowChoice
        let numberChoice: MenuBarWindowChoice
        /// 多选窗口标签（设置页新交互，优先于 choice）：按 label 在全部窗口里筛选。
        let glyphWindowLabels: [String]?
        let numberWindowLabels: [String]?

        var isSingleWindow: Bool { shortWindow == nil }

        /// 窗口展开：多选标签优先（按 label 匹配全部窗口）；否则单窗家恒取唯一窗，
        /// 双窗/全部按 choice 与 order。
        func windows(for choice: MenuBarWindowChoice, order: MenuBarWindowOrder, labels: [String]? = nil) -> [Window] {
            if let labels, !labels.isEmpty {
                let matched = allWindows.filter { labels.contains($0.label) }
                if !matched.isEmpty {
                    return order == .shortFirst ? matched : matched.reversed()
                }
            }
            guard let shortWindow else { return [longWindow] }
            switch choice {
            case .short: return [shortWindow]
            case .long: return [longWindow]
            case .both: return order == .shortFirst ? [shortWindow, longWindow] : [longWindow, shortWindow]
            case .all:
                let ordered = allWindows.isEmpty ? [shortWindow, longWindow] : allWindows
                return order == .shortFirst ? ordered : ordered.reversed()
            }
        }

        func glyphWindows(order: MenuBarWindowOrder) -> [Window] {
            windows(for: glyphChoice, order: order, labels: glyphWindowLabels)
        }
        func numberWindows(order: MenuBarWindowOrder) -> [Window] {
            windows(for: numberChoice, order: order, labels: numberWindowLabels)
        }
        var worstNumberWindow: Window {
            MenuBarQuotaModel.worst(of: windows(for: numberChoice, order: .longFirst, labels: numberWindowLabels))
        }
        var worstGlyphWindow: Window {
            MenuBarQuotaModel.worst(of: windows(for: glyphChoice, order: .longFirst, labels: glyphWindowLabels))
        }
    }

    static func worst(of windows: [Window]) -> Window {
        windows.min { $0.remainingPercent < $1.remainingPercent }
            ?? Window(label: "", remainingPercent: 0, tone: .muted)
    }

    /// 哨兵样式的组件级状态（spec §3：红 > 黄 > 安静）。
    enum SentinelState: Equatable {
        case quiet
        case alert(cell: Cell, window: Window)
    }

    static func sentinelState(cells: [Cell]) -> SentinelState {
        let alerts = cells
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
        return .quiet
    }

    /// 聚合样式的组件级最险数字（数字窗口口径）。
    /// 缓存家仍计入：查询失败不等于额度归零，菜单栏应继续显示上次剩余%。
    static func aggregateWorstNumber(cells: [Cell]) -> (cell: Cell, window: Window)? {
        cells
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

    /// 文字样式的超宽降级（spec §2）：CJK 名称 + 双窗数字 + 名称开启 → 数字降最险单窗。
    /// both 与 all（三窗家）同属多窗口径，都触发降级。
    static func numbersDegradeToWorst(style: MenuBarStyleId, cell: Cell, showName: Bool) -> Bool {
        guard style == .digits, showName, !cell.isSingleWindow,
              cell.numberChoice == .both || cell.numberChoice == .all else { return false }
        return cell.badge.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
    }

    /// 单字符标去重：依序取名称第一个未被占用的非空白字符，全占用回落首字符。
    /// [CC, CX, 智谱, OMP] → [C, X, 智, O]（与设计稿 MONO_CH 一致）。
    static func monograms(for badges: [String]) -> [String] {
        var used = Set<String>()
        return badges.map { badge in
            let chars = badge.filter { !$0.isWhitespace }.map(String.init)
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

        struct PeakTierEntry: Equatable {
            let brandName: String
            let modelName: String
            let tier: PeakOffPeakPricing
        }

        let style: MenuBarStyleId
        let showName: Bool
        let showGlyph: Bool
        let showNumber: Bool
        let windowOrder: MenuBarWindowOrder
        let cells: [Cell]
        let tail: Tail
        /// 随包定价模型的峰谷时刻表（与额度供应商无关）。空 = 不显示峰/谷标识。
        /// 只带时刻表不带档位：峰/谷由视图层按当前时刻自判（TimelineView），
        /// 整点切换不必重建整个投影。
        let peakTiers: [PeakTierEntry]
        /// 峰/谷标识样式（设置页可调）。
        let peakBadgeStyle: PeakBadgeStyle
    }

    static func projection(
        snapshots: [ProviderUsageSnapshot],
        settings: SettingsSnapshot?,
        todaySummary: MenuBarTodaySummary,
        peakTiers: [MenuBarProjection.PeakTierEntry] = [],
        displayCurrency: DisplayCurrency = .usd,
        usdToCny: Double = 1,
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
            let windows = model.menuBarWindows.map {
                Window(label: $0.label, remainingPercent: $0.percent, tone: $0.tone)
            }
            guard let longWindow = windows.last else { return nil }
            return Cell(
                providerId: snapshot.providerId,
                badge: snapshot.displayName,
                mono: "",
                shortWindow: windows.count > 1 ? windows.first : nil,
                longWindow: longWindow,
                allWindows: windows,
                // 默认 all：三窗家（OpenCode Go / Command Code）菜单栏平级全显；双窗家 all 与 both 同构。
                glyphChoice: providerOverride?.menuBarGlyphWindow ?? .all,
                numberChoice: providerOverride?.menuBarNumberWindow ?? .all,
                glyphWindowLabels: providerOverride?.menuBarGlyphWindows,
                numberWindowLabels: providerOverride?.menuBarNumberWindows
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
                allWindows: cell.allWindows,
                glyphChoice: cell.glyphChoice,
                numberChoice: cell.numberChoice,
                glyphWindowLabels: cell.glyphWindowLabels,
                numberWindowLabels: cell.numberWindowLabels
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
                ? .text(MenuBarNumberFormat.money(todaySummary.costUsdMicros, currency: displayCurrency, usdToCny: usdToCny))
                : .hidden
        }

        // 峰/谷标识由定价模型驱动，不与任一额度供应商绑定；设置页关闭时整体不显示。
        let visiblePeakTiers = appearance.showPeakBadge ? peakTiers : []

        return MenuBarProjection(
            style: appearance.style,
            showName: elements.name,
            showGlyph: elements.glyph,
            showNumber: elements.number,
            windowOrder: appearance.windowOrder,
            cells: cells,
            tail: tail,
            peakTiers: visiblePeakTiers,
            peakBadgeStyle: appearance.peakBadgeStyle
        )
    }
}
