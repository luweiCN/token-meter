import SwiftUI
import TokenMeterCore

/// 16 样式共享的小件与 S0-S7 基础族视图；聚合/数字支/混合系在文件下半部。
/// 规则权威：docs/superpowers/specs/2026-07-17-menubar-styles-implementation-design.md §2-3。
/// cell 内只用系统语义色（品牌色禁入菜单栏）。

enum MenuBarToneColor {
    /// 名称/尾巴文字 = 纯白（深）/纯黑（浅）——用户裁定：不要系统 label 的灰调。
    static let text = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white : .black
    })

    /// 安全态 = 系统绿，与弹窗进度条同语义（用户裁定 2026-07-17 二改：
    /// 曾试过品牌青，与弹窗的绿进度条明显不一致，回绿）。
    static func color(_ tone: UsageMetricTone) -> Color {
        switch tone {
        case .ok: return Color(nsColor: .systemGreen)
        case .warning: return Color(nsColor: .systemYellow)
        case .bad: return Color(nsColor: .systemRed)
        case .muted: return Color(nsColor: .tertiaryLabelColor)
        }
    }

    /// stale 整 cell 灰：图形/数字染色前先过这层。
    static func display(_ tone: UsageMetricTone, stale: Bool) -> Color {
        color(stale ? .muted : tone)
    }
}

/// 品牌短名（11pt semibold，纯白/纯黑——用户裁定不要 label 灰调）。
struct CellNameText: View {
    let badge: String
    var body: some View {
        Text(badge)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(MenuBarToneColor.text)
            .fixedSize()
    }
}

/// 数字组：双数字各自跟随所属窗口 tone（S0 用户裁定的打磨，推广到全族）；
/// stale 显示 "—"。分隔点弱化、基线对齐（异色数字 center 对齐有高低错觉）。
struct CellNumbersView: View {
    let windows: [MenuBarQuotaModel.Window]
    let isStale: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if isStale {
            Text("—")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.tertiary)
                .fixedSize()
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                ForEach(Array(windows.enumerated()), id: \.offset) { index, window in
                    if index > 0 {
                        Text("·")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 1.5)
                    }
                    Text("\(window.roundedPercent)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(MenuBarToneColor.color(window.tone))
                        .fixedSize()
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: window.roundedPercent)
                }
            }
        }
    }
}

/// S0 同心双环（现状实现迁入）：butt 端点（round 的端点小圆凸起在双环异位时
/// 是持续的不对称噪音）、底环 0.28 加深（缺口不拉偏视觉重心）、overlay 同心
///（ZStack 亚像素中心在 Retina 下曾渲染出肉眼可见的偏心）。[0] = 外环。
struct RingsGlyphView: View {
    let windows: [MenuBarQuotaModel.Window]
    let isStale: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func ring(_ window: MenuBarQuotaModel.Window, diameter: CGFloat) -> some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.28), lineWidth: 2)
            Circle()
                .trim(from: 0, to: window.remainingPercent / 100)
                .stroke(
                    MenuBarToneColor.display(window.tone, stale: isStale),
                    style: StrokeStyle(lineWidth: 2, lineCap: .butt)
                )
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .smooth(duration: 0.5), value: window.remainingPercent)
        }
        .frame(width: diameter, height: diameter)
    }

    var body: some View {
        if let outer = windows.first {
            ring(outer, diameter: 15)
                .overlay {
                    if windows.count > 1 { ring(windows[1], diameter: 8) }
                }
                .frame(width: 17, height: 17)
                .opacity(isStale ? 0.7 : 1)
        }
    }
}

/// S1 双竖条：3×13pt 底向上填充。
struct VBarsGlyphView: View {
    let windows: [MenuBarQuotaModel.Window]
    let isStale: Bool
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.14))
                    RoundedRectangle(cornerRadius: 1)
                        .fill(MenuBarToneColor.display(window.tone, stale: isStale))
                        .frame(height: max(1, 13 * window.remainingPercent / 100))
                        .opacity(isStale ? 0.5 : 1)
                }
                .frame(width: 3, height: 13)
            }
        }
    }
}

/// S2 迷你横条：22×3pt 上下叠（顺序 = windowOrder 首位在上），单窗加粗 4pt。
struct HBarGlyphView: View {
    let windows: [MenuBarQuotaModel.Window]
    let isStale: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.primary.opacity(0.14))
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(MenuBarToneColor.display(window.tone, stale: isStale))
                        .frame(width: max(1, 22 * window.remainingPercent / 100))
                        .opacity(isStale ? 0.5 : 1)
                }
                .frame(width: 22, height: windows.count == 1 ? 4 : 3)
            }
        }
    }
}

/// S4 状态点：6pt 圆点每窗一点。
struct DotsGlyphView: View {
    let windows: [MenuBarQuotaModel.Window]
    let isStale: Bool
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                Circle()
                    .fill(MenuBarToneColor.display(window.tone, stale: isStale))
                    .frame(width: 6, height: 6)
            }
        }
    }
}

/// S5 胶囊电池：14×8pt，描边内缩 1pt 填充（借系统电池心智）。
struct CapsGlyphView: View {
    let windows: [MenuBarQuotaModel.Window]
    let isStale: Bool
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(MenuBarToneColor.display(window.tone, stale: isStale))
                        .frame(width: max(1, 12 * window.remainingPercent / 100))
                        .padding(1)
                        .opacity(isStale ? 0.5 : 1)
                }
                .frame(width: 14, height: 8)
            }
        }
    }
}

/// S6 分段刻度：5 格 2.5×10pt，亮格 = round(p/20) 至少 1（离散刻度读格数不读长度）。
struct TicksGlyphView: View {
    let windows: [MenuBarQuotaModel.Window]
    let isStale: Bool
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                let lit = max(1, Int((window.remainingPercent / 20).rounded()))
                HStack(spacing: 1.5) {
                    ForEach(0..<5, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(index < lit
                                ? MenuBarToneColor.display(window.tone, stale: isStale)
                                : Color.primary.opacity(0.14))
                            .frame(width: 2.5, height: 10)
                    }
                }
            }
        }
    }
}

/// S7 单环：15pt 只画一个窗口（both → windowOrder 首位；「只留最要紧那个」）。
/// 单弧无双环的端点对称问题，round 端点成立。
struct Ring1GlyphView: View {
    let window: MenuBarQuotaModel.Window
    let isStale: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.16), lineWidth: 2)
            Circle()
                .trim(from: 0, to: window.remainingPercent / 100)
                .stroke(
                    MenuBarToneColor.display(window.tone, stale: isStale),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .smooth(duration: 0.5), value: window.remainingPercent)
        }
        .frame(width: 15, height: 15)
    }
}

// MARK: - 聚合紧凑族（S8-S11）、数字支（S12-S13）、混合系（S14-S15）

/// 13pt 品牌 logo（sentinel / grid / strip 的名称前缀位）。
struct MiniBrandLogo: View {
    var tint: Color = .primary
    var body: some View {
        MenuBarBrandMark(size: 13)
            .foregroundStyle(tint)
            .opacity(0.85)
    }
}

/// S8 点阵网格：全家聚合一个点阵（4 家 2×2、≤3 家单行），点色 = 家级最险
///（图形窗口口径）。名称开关 = logo 前缀；数字开关 = 全家最险单数字。
struct GridAggregateView: View {
    let projection: MenuBarQuotaModel.MenuBarProjection

    private var columns: [GridItem] {
        let count = projection.cells.count == 4 ? 2 : max(1, min(projection.cells.count, 3))
        return Array(repeating: GridItem(.fixed(5.5), spacing: 2), count: count)
    }

    var body: some View {
        HStack(spacing: 4) {
            if projection.showName { MiniBrandLogo() }
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(projection.cells, id: \.providerId) { cell in
                    Circle()
                        .fill(MenuBarToneColor.display(cell.worstGlyphWindow.tone, stale: cell.isStale))
                        .frame(width: 5.5, height: 5.5)
                }
            }
            .fixedSize()
            if projection.showNumber, let worst = MenuBarQuotaModel.aggregateWorstNumber(cells: projection.cells) {
                CellNumbersView(windows: [worst.window], isStale: false)
            }
        }
        .fixedSize()
    }
}

/// S11 堆叠条：每家一段 6×13pt、1pt 缝，段色 = 家级最险（图形窗口口径）；
/// stale 段降透明区分「灰」与「没数据」。
struct StripAggregateView: View {
    let projection: MenuBarQuotaModel.MenuBarProjection
    var body: some View {
        HStack(spacing: 4) {
            if projection.showName { MiniBrandLogo() }
            HStack(spacing: 1) {
                ForEach(projection.cells, id: \.providerId) { cell in
                    Rectangle()
                        .fill(MenuBarToneColor.display(cell.worstGlyphWindow.tone, stale: cell.isStale))
                        .frame(width: 6, height: 13)
                        .opacity(cell.isStale ? 0.55 : 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            if projection.showNumber, let worst = MenuBarQuotaModel.aggregateWorstNumber(cells: projection.cells) {
                CellNumbersView(windows: [worst.window], isStale: false)
            }
        }
        .fixedSize()
    }
}

/// S10 字母色徽：单字符警戒色染字（名称即图形即状态），stale 加删除线
///（色彩之外的第二编码，色盲安全）。
struct MonogramAggregateView: View {
    let projection: MenuBarQuotaModel.MenuBarProjection
    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(projection.cells, id: \.providerId) { cell in
                    Text(cell.mono)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(MenuBarToneColor.display(cell.worstNumberWindow.tone, stale: cell.isStale))
                        .strikethrough(cell.isStale, color: MenuBarToneColor.color(.muted))
                        .fixedSize()
                }
            }
            if projection.showNumber, let worst = MenuBarQuotaModel.aggregateWorstNumber(cells: projection.cells) {
                CellNumbersView(windows: [worst.window], isStale: false)
            }
        }
        .fixedSize()
    }
}

/// S9 哨兵：quiet = 单色 logo（史上最窄常态）；alert = 最险家（logo 染色 +
/// 短名 + 数字，各随元素开关）；stale = 灰 logo + 未更新分钟数。
struct SentinelView: View {
    let projection: MenuBarQuotaModel.MenuBarProjection
    var body: some View {
        switch MenuBarQuotaModel.sentinelState(cells: projection.cells) {
        case .quiet:
            MiniBrandLogo()
        case let .alert(cell, window):
            let tint = MenuBarToneColor.color(window.tone)
            HStack(spacing: 4) {
                if projection.showGlyph { MiniBrandLogo(tint: tint) }
                if projection.showName {
                    Text(cell.badge)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                        .fixedSize()
                }
                if projection.showNumber { CellNumbersView(windows: [window], isStale: false) }
            }
            .fixedSize()
        case let .stale(minutes):
            HStack(spacing: 4) {
                MiniBrandLogo(tint: MenuBarToneColor.color(.muted))
                Text("\(minutes)m")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            .fixedSize()
        }
    }
}

/// deck 单家 unit：上行小字名 / 下行数字（S13 与混合系共用，17pt 高度纵向两层）。
struct DeckUnitView: View {
    let cell: MenuBarQuotaModel.Cell
    let projection: MenuBarQuotaModel.MenuBarProjection
    /// tagnum 用单字符、deck2/混合系用短名；nil = 名称关闭（裸数字位序）。
    let nameText: String?

    var body: some View {
        VStack(spacing: 1) {
            if let nameText {
                Text(nameText)
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundStyle(MenuBarToneColor.text)
                    .fixedSize()
            }
            CellNumbersView(windows: cell.numberWindows(order: projection.windowOrder), isStale: cell.isStale)
        }
        .fixedSize()
    }
}

/// S12 字标数字：10pt 半透明单字符前标 + 警戒色数字（baseline 排布），
/// 数字一个不少、按家窗口全语义。
struct TagnumAggregateView: View {
    let projection: MenuBarQuotaModel.MenuBarProjection
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            ForEach(projection.cells, id: \.providerId) { cell in
                HStack(alignment: .firstTextBaseline, spacing: 1.5) {
                    if projection.showName {
                        Text(cell.mono)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(MenuBarToneColor.text)
                            .fixedSize()
                    }
                    CellNumbersView(windows: cell.numberWindows(order: projection.windowOrder), isStale: cell.isStale)
                }
            }
        }
        .fixedSize()
    }
}

/// S13 双层堆叠：每家一个 DeckUnit（上名下数），宽度只由数字本身决定。
struct Deck2AggregateView: View {
    let projection: MenuBarQuotaModel.MenuBarProjection
    var body: some View {
        HStack(spacing: 8) {
            ForEach(projection.cells, id: \.providerId) { cell in
                DeckUnitView(cell: cell, projection: projection, nameText: projection.showName ? cell.badge : nil)
            }
        }
        .fixedSize()
    }
}

/// S14/S15 混合系单家 cell：图形（环/竖条，图形窗口口径）+ DeckUnit（数字窗口
/// 口径）——图形管比例感、数字管精确值，任意交叉。
struct HybridCellView: View {
    let cell: MenuBarQuotaModel.Cell
    let projection: MenuBarQuotaModel.MenuBarProjection

    var body: some View {
        let glyphWindows = cell.glyphWindows(order: projection.windowOrder)
        HStack(spacing: 3) {
            if projection.style == .ringdeck {
                if glyphWindows.count > 1 {
                    RingsGlyphView(windows: glyphWindows, isStale: cell.isStale)
                } else {
                    Ring1GlyphView(window: glyphWindows[0], isStale: cell.isStale)
                }
            } else {
                VBarsGlyphView(windows: glyphWindows, isStale: cell.isStale)
            }
            DeckUnitView(cell: cell, projection: projection, nameText: projection.showName ? cell.badge : nil)
        }
        .fixedSize()
    }
}

/// 基础族（S0-S7）单家 cell：[name][glyph][pct] 语法 + 元素开关 +
/// ticks 双组刻度静音数字 + digits 的 CJK 超宽降级。
struct BasicStyleCellView: View {
    let cell: MenuBarQuotaModel.Cell
    let projection: MenuBarQuotaModel.MenuBarProjection

    private var glyphWindows: [MenuBarQuotaModel.Window] { cell.glyphWindows(order: projection.windowOrder) }

    private var numberWindows: [MenuBarQuotaModel.Window] {
        if MenuBarQuotaModel.numbersDegradeToWorst(style: projection.style, cell: cell, showName: projection.showName) {
            return [cell.worstNumberWindow]
        }
        // 双窗数字全显仅 rings/vbars/digits（稿定）；其余样式报最险单窗。
        switch projection.style {
        case .rings, .vbars, .digits:
            return cell.numberWindows(order: projection.windowOrder)
        default:
            return [cell.worstNumberWindow]
        }
    }

    /// ticks 双组刻度时数字自动隐藏（稿定规则）。
    private var numberSuppressed: Bool {
        projection.style == .ticks && projection.showGlyph && glyphWindows.count > 1
    }

    var body: some View {
        HStack(spacing: 4) {
            if projection.showName { CellNameText(badge: cell.badge) }
            if projection.showGlyph {
                switch projection.style {
                case .rings: RingsGlyphView(windows: glyphWindows, isStale: cell.isStale)
                case .vbars: VBarsGlyphView(windows: glyphWindows, isStale: cell.isStale)
                case .hbar: HBarGlyphView(windows: glyphWindows, isStale: cell.isStale)
                case .dots: DotsGlyphView(windows: glyphWindows, isStale: cell.isStale)
                case .caps: CapsGlyphView(windows: glyphWindows, isStale: cell.isStale)
                case .ticks: TicksGlyphView(windows: glyphWindows, isStale: cell.isStale)
                case .ring1: Ring1GlyphView(window: glyphWindows[0], isStale: cell.isStale)
                default: EmptyView()
                }
            }
            if projection.showNumber && !numberSuppressed {
                CellNumbersView(windows: numberWindows, isStale: cell.isStale)
            }
        }
        .fixedSize()
    }
}
