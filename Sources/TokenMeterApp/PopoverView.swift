import AppKit
import SwiftUI
import TokenMeterCore

// MARK: - 主题（OpenDesign 稿 coolnight，深色原生 / 浅色派生，随弹窗右上角按钮切换）

struct MBTheme: Equatable {
    let bg: Color
    let surface: Color
    let surface2: Color
    let fg: Color
    let fg2: Color
    let muted: Color
    let border: Color
    let accent: Color
    let onAccent: Color
    let ok: Color
    let warn: Color
    let danger: Color
    let tintWarn: Color
    let tintDanger: Color

    static let dark = MBTheme(
        bg: Color(hex: 0x00111E), surface: Color(hex: 0x02182A), surface2: Color(hex: 0x032138),
        fg: Color(hex: 0xCBE0F0), fg2: Color(hex: 0xA9B1D6), muted: Color(hex: 0x5D84A6),
        border: Color(hex: 0x033259), accent: Color(hex: 0x0FC5ED), onAccent: Color(hex: 0x011423),
        ok: Color(hex: 0x44FFB1), warn: Color(hex: 0xFFE073), danger: Color(hex: 0xE52E2E),
        tintWarn: Color(hex: 0xFFE073).opacity(0.1), tintDanger: Color(hex: 0xE52E2E).opacity(0.12)
    )

    static let light = MBTheme(
        bg: Color(hex: 0xF2F7FB), surface: Color(hex: 0xFFFFFF), surface2: Color(hex: 0xE9F1F7),
        fg: Color(hex: 0x0A2540), fg2: Color(hex: 0x3D5A78), muted: Color(hex: 0x4A6B8A),
        border: Color(hex: 0xD8E6F0), accent: Color(hex: 0x0895BD), onAccent: Color(hex: 0xFFFFFF),
        ok: Color(hex: 0x0F9D6E), warn: Color(hex: 0x9A7500), danger: Color(hex: 0xC92A2A),
        tintWarn: Color(hex: 0x9A7500).opacity(0.12), tintDanger: Color(hex: 0xC92A2A).opacity(0.1)
    )
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

/// NSPopover 的系统 chrome（框架、箭头、边框）没有公开的换色 API。放一个零尺寸
/// NSView 进层级，等它挂上窗口后把 frame view 的 layer 染成面板色——这是 macOS
/// 上自定义 popover 背景的通行做法，箭头会一并变色，系统边框随之消隐。
private struct PopoverChromeTint: NSViewRepresentable {
    let color: NSColor
    var cornerRadius: CGFloat = 11

    final class TintView: NSView {
        var color: NSColor = .clear {
            didSet { apply() }
        }
        var cornerRadius: CGFloat = 11 {
            didSet { apply() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            // 窗口 resize 与内容布局并成同一事务：AppKit 原点在左下，resize 的
            // 瞬间帧里内容会跟着底边走，同步布局让归位发生在同一次屏幕提交内
            // （面板打开时从估值到实值的那一次调整靠它保持顶部稳定）。
            if let window {
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didResizeNotification, object: window, queue: .main
                ) { note in
                    (note.object as? NSWindow)?.contentView?.layoutSubtreeIfNeeded()
                }
            }
        }

        func apply() {
            guard let frameView = window?.contentView?.superview else { return }
            frameView.wantsLayer = true
            frameView.layer?.backgroundColor = color.cgColor
            // 不描边（用户裁定）：背景色本身就是边界，系统边框一并压为 0。
            frameView.layer?.borderWidth = 0
            frameView.layer?.cornerRadius = cornerRadius
        }
    }

    func makeNSView(context: Context) -> TintView {
        let view = TintView()
        view.color = color
        view.cornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ nsView: TintView, context: Context) {
        nsView.color = color
        nsView.cornerRadius = cornerRadius
    }
}

/// 吸顶区毛玻璃：原生 NSVisualEffectView，窗口内混合——滚动内容从下面穿过时
/// 透出模糊残影，吸顶与滚动区的层次一眼可辨。
private struct HeaderBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct MBThemeKey: EnvironmentKey {
    static let defaultValue = MBTheme.dark
}

extension EnvironmentValues {
    var mbTheme: MBTheme {
        get { self[MBThemeKey.self] }
        set { self[MBThemeKey.self] = newValue }
    }
}

enum MenuBarProviderName {
    static func label(_ providerId: String) -> String {
        switch providerId {
        case "claude-code": return "Claude Code"
        case "codex": return "Codex CLI"
        case "omp": return "OMP"
        case "opencode": return "OpenCode"
        case "reasonix": return "Reasonix"
        case "openclaw": return "OpenClaw"
        case "hermes": return "Hermes Agent"
        case "dsh": return "DeepSeek Harness"
        case "grok": return "Grok Build"
        case "qwen-code": return "千问 Code"
        case "qoder-cli": return "Qoder CLI"
        case "qoder-desktop": return "Qoder Desktop"
        case "workbuddy": return "WorkBuddy"
        case "antigravity-cli": return AntigravityCLIUsage.displayName
        case "gemini-cli": return "Gemini CLI"
        default: return providerId
        }
    }
}

enum MenuBarNumberFormat {
    /// 与菜单栏标题共用同一实现（UsageFormatter.compactTokens），两处数字永远同格式。
    static func tokens(_ value: Int64) -> String {
        UsageFormatter.compactTokens(value)
    }

    static func credits(_ picos: Int64) -> String {
        let value = Double(picos) / 1_000_000_000_000
        let digits = value >= 100 ? 2 : (value >= 1 ? 4 : 8)
        return String(format: "%.*f Credits", digits, value)
            .replacingOccurrences(of: #"\.?0+ Credits$"#, with: " Credits", options: .regularExpression)
    }

    /// 金额显示：美元直接用存储值，人民币按当前汇率换算。两位小数。
    static func money(_ micros: Int64, currency: DisplayCurrency, usdToCny: Double) -> String {
        switch currency {
        case .usd:
            return String(format: "$%.2f", Double(micros) / 1_000_000)
        case .cny:
            return String(format: "¥%.2f", Double(micros) / 1_000_000 * usdToCny)
        }
    }
}

// MARK: - 弹窗主体（.panel：head / today / srcline / 按服务商 / 订阅额度 / unk / foot）

struct PopoverView: View {
    @ObservedObject var store: ProviderStore
    @State private var measuredContentHeight: CGFloat = 0
    @AppStorage("menubarTheme") private var themeName = "dark"
    /// 手风琴展开态（用户裁定：默认第一家展开、任意时刻至多一家）。
    /// nil = 未点过 → 展开第一家；空串 = 手动全收起。
    @State private var expandedProviderId: String?
    let initialPanelHeight: CGFloat
    let maxPanelHeight: CGFloat
    let onPreferredHeightChange: (CGFloat) -> Void
    var onOpenMainInterface: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onThemeChange: () -> Void = {}

    private var theme: MBTheme { themeName == "light" ? .light : .dark }

    private var resolvedExpandedProviderId: String? {
        expandedProviderId ?? store.displayProviderSnapshots.first?.providerId
    }

    /// 吸顶区与底栏的高度是【实测】的（readHeight），不是估计值——写死的估计值
    /// 偏小时，VStack 总高超出面板，底部按钮的 padding 会被整个裁掉且毫无征兆。
    @State private var headerHeight: CGFloat = 192
    @State private var footHeight: CGFloat = 50

    private var chromeMeasured: CGFloat { headerHeight + footHeight }

    /// 面板高度跟随内容（用户裁定，取代先前「打开期间锁定」）：默认内容完整
    /// 展示、不出滚动条；展开手风琴/模型列表时面板继续长高，顶到
    /// maxPanelHeight（屏幕可用高度）才交给滚动条消化。
    private var panelHeight: CGFloat {
        guard measuredContentHeight > 20 else {
            return min(maxPanelHeight, initialPanelHeight)
        }
        return min(maxPanelHeight, chromeMeasured + measuredContentHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 吸顶头部：毛玻璃 + surface 叠加，滚动内容从下面穿过时层次分明。
            VStack(spacing: 0) {
                PanelHead(store: store, themeName: $themeName)
                TodayBlock(
                    summary: store.todaySummary,
                    monthActivity: store.overviewStats == nil ? nil : store.monthActivity,
                    displayCurrency: store.displayCurrency,
                    usdToCny: store.exchangeRate.usdToCny,
                    modelBreakdown: { store.modelBreakdown(for: $0) },
                    deviceBreakdown: { store.deviceBreakdown(for: $0) }
                )
                if let stats = store.overviewStats {
                    OverviewTilesView(
                        stats: stats,
                        displayCurrency: store.displayCurrency,
                        usdToCny: store.exchangeRate.usdToCny
                    )
                } else {
                    Text("设备历史汇总暂不可用")
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
                SourceLine(text: sourceLineText)
                PanelDivider()
            }
            .background(
                ZStack {
                    HeaderBlur()
                    theme.surface.opacity(0.72)
                }
            )
            .readHeight { height in
                headerHeight = height
                onPreferredHeightChange(panelHeight)
            }
            .shadow(
                color: themeName == "light" ? Color.black.opacity(0.14) : Color.black.opacity(0.45),
                radius: 10,
                y: 4
            )
            .zIndex(1)

            // 纯 SwiftUI 滚动区：AppKit 滚动容器与 SwiftUI 内容之间的高度信号
            // 无论怎么接都差一拍（诊断日志：展开居中跳 ±60.5、收起文档卡 732、
            // offset 被推到 236 再回弹），树内没有 AppKit 边界后这一类问题整体消失。
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 6)

                    if store.settingsSnapshot?.menuBarAppearance.showPeakSection != false,
                       store.peakPricingRows.contains(where: { $0.tier.phase(at: Date()) != .notYetEffective }) {
                        SectionBlock(title: "峰谷时段") {
                            PeakPricingSection(rows: store.peakPricingRows)
                        }
                        PanelDivider()
                    }

                    let machines = store.dailyNodeSummary?.visibleMachines ?? []
                    let models = store.dailyModels
                    if !machines.isEmpty || !store.dailyAgents.isEmpty || models?.rows.isEmpty == false {
                        DailyUsageGrid(
                            machines: machines,
                            agents: store.dailyAgents,
                            models: models,
                            displayCurrency: store.displayCurrency,
                            usdToCny: store.exchangeRate.usdToCny
                        )
                        if let models, models.total.unknownCost > 0 {
                            UnknownNote(summary: models)
                        }
                        PanelDivider()
                    }

                    if !store.displayProviderSnapshots.isEmpty {
                        SectionBlock(title: "账户额度") {
                            VStack(spacing: 8) {
                                ForEach(store.displayProviderSnapshots, id: \.providerId) { snapshot in
                                    QuotaGroupView(
                                        snapshot: snapshot,
                                        isExpanded: resolvedExpandedProviderId == snapshot.providerId,
                                        isRefreshing: store.isRefreshingQuota(for: snapshot.providerId),
                                        onToggleExpanded: {
                                            expandedProviderId = resolvedExpandedProviderId == snapshot.providerId
                                                ? "" : snapshot.providerId
                                        }
                                    ) {
                                        Task { await store.retryQuota(for: snapshot.providerId) }
                                    }
                                }
                            }
                        }
                    }

                    // 尾部不再垫高（用户裁定：面板要比精确贴合再紧一点）。
                    // 底部留白由末区块自带的 12 底边距提供。今日模型行数变化会让
                    // 面板高度自然波动（精确贴合内容），别用垫条去补内容行数的增减。
                    Color.clear.frame(height: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.bg)
                .background(ThinScrollerStyler())
                .readHeight { height in
                    if abs(measuredContentHeight - height) > 0.5 {
                        measuredContentHeight = height
                        onPreferredHeightChange(panelHeight)
                    }
                }
            }
            .background(theme.bg)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 0) {
                PanelDivider()
                FootBar(store: store, onOpenMainInterface: onOpenMainInterface, onOpenSettings: onOpenSettings)
            }
            .background(theme.surface)
            .readHeight { height in
                footHeight = height
                onPreferredHeightChange(panelHeight)
            }
        }
        .frame(width: 378, height: panelHeight, alignment: .top)
        .background(theme.surface)
        .background(PopoverChromeTint(
            color: themeName == "light"
                ? NSColor(red: 1, green: 1, blue: 1, alpha: 1)
                : NSColor(red: 0x02 / 255.0, green: 0x18 / 255.0, blue: 0x2A / 255.0, alpha: 1)))
        .environment(\.mbTheme, theme)
        .environment(\.colorScheme, themeName == "light" ? .light : .dark)
        .onAppear {
            onPreferredHeightChange(panelHeight)
        }
        .onChange(of: themeName) { _ in
            onThemeChange()
        }
        .task {
            await store.refreshNotificationAuthorizationState()
        }
    }

    private var sourceLineText: String {
        guard let updatedAt = store.localIndexUpdatedAt else { return store.localIndexStatusText }
        let minutes = max(0, Int(Date().timeIntervalSince(updatedAt) / 60))
        let ago = minutes == 0 ? "刚刚" : "\(minutes) 分钟前"
        return "\(store.localIndexStatusText) · \(ago)"
    }
}

// MARK: - .head：logo + TokenMeter + 日期 + 主题按钮

private struct PanelHead: View {
    @ObservedObject var store: ProviderStore
    @Binding var themeName: String
    @Environment(\.mbTheme) private var theme

    var body: some View {
        HStack(spacing: 9) {
            BrandMark()

            Text("TokenMeter")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.fg)

            NotificationPermissionControl(store: store)

            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer()

            Text(dateText)
                .font(.system(size: 11))
                .foregroundStyle(theme.muted)

            Button {
                themeName = themeName == "light" ? "dark" : "light"
            } label: {
                Group {
                    if themeName == "light" {
                        // 太阳
                        Image(systemName: "sun.max")
                            .font(.system(size: 11, weight: .medium))
                    } else {
                        // 月亮（稿中路径的等价形状）
                        Image(systemName: "moon")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .foregroundStyle(theme.fg2)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        .focusable(false)
            .help("切换外观")
        }
        .padding(EdgeInsets(top: 20, leading: 16, bottom: 10, trailing: 16))
    }

    private var dateText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEE"
        return formatter.string(from: Date())
    }
}

/// 品牌小标（稿左上角 18×18 圆角方框折线）。
private struct BrandMark: View {
    @Environment(\.mbTheme) private var theme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                .stroke(theme.accent, lineWidth: 1.6)
                .frame(width: 17, height: 17)
            Path { p in
                p.move(to: CGPoint(x: 3.7, y: 10.3))
                p.addLine(to: CGPoint(x: 6.2, y: 6.2))
                p.addLine(to: CGPoint(x: 8.3, y: 9.1))
                p.addLine(to: CGPoint(x: 10.3, y: 4.6))
                p.addLine(to: CGPoint(x: 11.9, y: 10.3))
            }
            .stroke(theme.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            .frame(width: 15, height: 14)
        }
        .frame(width: 18, height: 18)
    }
}

// MARK: - .today：32px 大数字 + 今日金额/会话

/// 数字文本变化时逐位滚动（numericText），系统「减弱动态效果」开启则直接替换。
/// 只做文本过渡、不碰布局尺寸——弹窗高度的平滑过渡由 NSPopover 原生动画负责
/// （见 QuotaGroupView.summaryRow 的注释），两边不打架。
private struct RollingNumberModifier<Value: Equatable>: ViewModifier {
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .contentTransition(reduceMotion ? .identity : .numericText())
            .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: value)
    }
}

private extension View {
    func rollingNumber<Value: Equatable>(value: Value) -> some View {
        modifier(RollingNumberModifier(value: value))
    }
}

private struct TodayBlock: View {
    let summary: MenuTodayUsage
    let monthActivity: [DayActivity]?
    let displayCurrency: DisplayCurrency
    let usdToCny: Double
    let modelBreakdown: (String) -> [DailyModelSummary.Row]
    let deviceBreakdown: (String) -> [DayDeviceUsage]
    @Environment(\.mbTheme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(summary.usage.tokenAmount.dailyText)
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(theme.fg)
                        .monospacedDigit()
                        .rollingNumber(value: summary.usage.tokens)
                    Text("tokens")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.fg2)
                }

                HStack(spacing: 0) {
                    Text("花费 ")
                    Text(verbatim: summary.usage.formattedCost(currency: displayCurrency, usdToCny: usdToCny))
                        .foregroundStyle(theme.fg2)
                    if let sessions = summary.sessions {
                        Text(" · ")
                        Text(verbatim: "\(sessions)").foregroundStyle(theme.fg2)
                        Text(" 个会话")
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(theme.muted)
                .monospacedDigit()
                .rollingNumber(value: summary)
                .accessibilityElement(children: .combine)
            }

            Spacer(minLength: 4)

            if let monthActivity {
                MonthHeatmapView(
                    days: monthActivity,
                    displayCurrency: displayCurrency,
                    usdToCny: usdToCny,
                    modelBreakdown: modelBreakdown,
                    deviceBreakdown: deviceBreakdown
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 0, leading: 16, bottom: 12, trailing: 16))
        // 浮窗从热力图向下延伸、会覆盖到三张卡片区域；把本块画在 header 其他
        // 兄弟之上，浮窗才不会被后面的卡片盖住。
        .zIndex(1)
    }
}

// MARK: - .heatmap：当月用量点阵（周一对齐的日历网格，GitHub 式着色）

/// 顶部总览右侧的当月热力图。7 列固定为周一…周日，行数随当月 1 号的星期偏移与
/// 天数动态 4–6 行（1 号前的空位与月末后的空位留白），与系统日历完全对齐；
/// 颜色对应固定日 Token 区间，同样的用量在不同月份同色。悬浮单点弹详情浮窗：
/// 展示当天的 Token、花费、可用的会话和事件数，以及按模型和设备拆分的用量。
/// 还没到的日期不响应悬浮、也不弹浮窗。顶部一行极淡的「一二三四五六日」作列标题，
/// 不抢视觉但让「第几列是周几」一目了然。
private struct MonthHeatmapView: View {
    let days: [DayActivity]
    let displayCurrency: DisplayCurrency
    let usdToCny: Double
    let modelBreakdown: (String) -> [DailyModelSummary.Row]
    let deviceBreakdown: (String) -> [DayDeviceUsage]
    @Environment(\.mbTheme) private var theme

    @State private var hoveredDay: Int?
    @State private var pendingClose: DispatchWorkItem?

    private static let columns = 7
    private static let cellSize: CGFloat = 10
    private static let spacing: CGFloat = 3
    private static let popupWidth: CGFloat = 300
    private static let weekdayTitles = ["一", "二", "三", "四", "五", "六", "日"]

    private var calendar: Calendar { Calendar.current }

    private var byDay: [String: DayActivity] {
        Dictionary(uniqueKeysWithValues: days.map { ($0.date, $0) })
    }

    private var dayCount: Int {
        calendar.range(of: .day, in: .month, for: Date())?.count ?? 30
    }

    private var todayDay: Int {
        calendar.component(.day, from: Date())
    }

    /// 当月 1 号在「周一为第 0 列」坐标系下的偏移（0=周一，6=周日）。
    private var firstWeekdayOffset: Int {
        guard let firstOfMonth = calendar.date(
            from: calendar.dateComponents([.year, .month], from: Date())
        ) else { return 0 }
        let weekday = calendar.component(.weekday, from: firstOfMonth) // 1=周日 … 7=周六
        return (weekday + 5) % 7 // 周一→0，周二→1，… 周日→6
    }

    /// 按偏移与天数算出的实际行数，固定 6 行：月与月之间高度不跳，1 号前的空位与
    /// 月末后的空位用占位灰填充，网格始终是完整的 6×7，不会出现「左上缺一块、底部孤一点」的跳动感。
    private var rowsNeeded: Int { 6 }

    var body: some View {
        VStack(spacing: 2.5) {
            // 标题行：字号收小、字重加粗、透明度压低到恰好可辨，不与点抢视觉；
            // 与点阵的间距收紧到 2.5，避免截图里「标题悬空」的割裂感。
            HStack(spacing: Self.spacing) {
                ForEach(Array(Self.weekdayTitles.enumerated()), id: \.offset) { _, title in
                    Text(title)
                        .font(.system(size: 6.5, weight: .semibold))
                        .foregroundStyle(theme.muted.opacity(0.55))
                        .frame(width: Self.cellSize, height: 7)
                }
            }
            VStack(spacing: Self.spacing) {
                ForEach(0..<rowsNeeded, id: \.self) { row in
                    HStack(spacing: Self.spacing) {
                        ForEach(0..<Self.columns, id: \.self) { column in
                            let dayNumber = row * Self.columns + column - firstWeekdayOffset + 1
                            if dayNumber < 1 || dayNumber > dayCount {
                                // 月外的占位格：不再全透明，给一个极淡的 surface2 占位，让网格
                                // 的「缺口」消失，视觉上是完整的方块，仅比无数据日更淡。
                                RoundedRectangle(cornerRadius: 2.5)
                                    .fill(theme.surface2.opacity(0.5))
                                    .frame(width: Self.cellSize, height: Self.cellSize)
                            } else {
                                cell(dayNumber: dayNumber)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cell(dayNumber: Int) -> some View {
        let activity = byDay[dayText(dayNumber)]
        let tokens = activity?.tokens ?? 0
        let isFuture = dayNumber > todayDay
        RoundedRectangle(cornerRadius: 2.5)
            .fill(color(tokens: tokens, isFuture: isFuture))
            .frame(width: Self.cellSize, height: Self.cellSize)
            .overlay {
                if !isFuture, hoveredDay == dayNumber {
                    RoundedRectangle(cornerRadius: 2.5)
                        .stroke(theme.fg2, lineWidth: 1)
                } else if !isFuture, dayNumber == todayDay {
                    RoundedRectangle(cornerRadius: 2.5)
                        .stroke(theme.accent, lineWidth: 1)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(dayLabel(dayNumber)))
            .accessibilityValue(Text(PopoverTokenAmount(tokens: tokens, unreportedEvents: activity?.tokenUnreportedEvents ?? 0).detail))
            .onHover { hovering in
                if isFuture { return }
                if hovering {
                    pendingClose?.cancel()
                    hoveredDay = dayNumber
                    let date = dayText(dayNumber)
                    let models = modelBreakdown(date)
                    let devices = deviceBreakdown(date)
                    HeatmapDetailPopover.shared.show(below: NSEvent.mouseLocation) {
                        detailCard(day: dayNumber, models: models, devices: devices)
                            .environment(\.mbTheme, theme)
                    }
                } else if hoveredDay == dayNumber {
                    scheduleClose(dayNumber)
                }
            }
    }

    /// 离开格子后延迟一小拍再关：给鼠标从格子挪进浮窗留出时间，浮窗的 onHover 会取消关闭。
    private func scheduleClose(_ day: Int) {
        pendingClose?.cancel()
        let work = DispatchWorkItem {
            if hoveredDay == day {
                hoveredDay = nil
                HeatmapDetailPopover.shared.hide()
            }
        }
        pendingClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    @ViewBuilder
    private func detailCard(day: Int, models: [DailyModelSummary.Row], devices: [DayDeviceUsage]) -> some View {
        let activity = byDay[dayText(day)]
        let usage = activity.map(DailyUsage.init(activity:)) ?? .zero
        VStack(spacing: 0) {
            arrow

            VStack(alignment: .leading, spacing: 8) {
                Text(dayLabel(day))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.fg)

                HStack(alignment: .top, spacing: 8) {
                    stat("Token", usage.tokenAmount.dailyText)
                    stat("花费", usage.formattedCost(currency: displayCurrency, usdToCny: usdToCny))
                    if activity?.includesAllSessionCounts != false {
                        stat("会话", "\(activity?.sessions ?? 0)")
                    }
                    stat("事件", "\(activity?.events ?? 0)")
                }

                let band = MonthHeatmapBand.band(for: activity?.tokens ?? 0)
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(band.color(in: theme))
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text("日用量档位 · \(band.rangeLabel)")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.fg2)
                    Spacer(minLength: 4)
                    let cache = usage.cacheUsage
                    Text("缓存命中 \(cache.percentText)")
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(theme.fg2)
                        .accessibilityLabel(cache.detail)
                }

                Rectangle().fill(theme.border).frame(height: 1)

                if models.isEmpty {
                    Text("当天无模型明细")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.muted)
                        .padding(.vertical, 4)
                } else {
                    usageTable("模型", rows: models, name: \.id, usage: \.usage)
                }

                if !devices.isEmpty {
                    Rectangle().fill(theme.border).frame(height: 1)
                    let table = usageTable("设备", rows: devices, name: \.name, usage: \.usage)
                    if devices.count > 6 {
                        ScrollView { table }
                            .frame(height: 140)
                    } else {
                        table
                    }
                }
            }
            .padding(12)
        }
        .frame(width: Self.popupWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border, lineWidth: 1))
        .onHover { hovering in
            if hovering {
                pendingClose?.cancel()
            } else {
                scheduleClose(day)
            }
        }
    }

    private func usageTable<Row: Identifiable>(
        _ title: LocalizedStringKey, rows: [Row], name: KeyPath<Row, String>, usage: KeyPath<Row, DailyUsage>
    ) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: 6, verticalSpacing: 4) {
            GridRow {
                Text(title).frame(maxWidth: .infinity, alignment: .leading)
                Text("Token")
                Text("花费")
                Text("命中率")
            }
            .font(.system(size: 9.5))
            .foregroundStyle(theme.muted)

            ForEach(rows) { row in
                let usage = row[keyPath: usage]
                GridRow {
                    Text(verbatim: row[keyPath: name])
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: usage.tokenAmount.dailyText)
                    Text(verbatim: usage.formattedCost(currency: displayCurrency, usdToCny: usdToCny))
                    Text(verbatim: usage.cacheUsage.percentText)
                        .accessibilityLabel(usage.cacheUsage.detail)
                }
                .font(.system(size: 10.5, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(theme.fg2)
            }
        }
    }

    /// 浮窗顶部的小箭头：浮窗水平居中于鼠标，箭头顶点自然指向被悬浮的格子。
    private var arrow: some View {
        let arrowX = Self.popupWidth / 2
        return Path { path in
            path.move(to: CGPoint(x: arrowX, y: 0))
            path.addLine(to: CGPoint(x: arrowX - 6, y: 6))
            path.addLine(to: CGPoint(x: arrowX + 6, y: 6))
            path.closeSubpath()
        }
        .fill(theme.surface)
        .overlay {
            Path { path in
                path.move(to: CGPoint(x: arrowX, y: 0))
                path.addLine(to: CGPoint(x: arrowX - 6, y: 6))
                path.addLine(to: CGPoint(x: arrowX + 6, y: 6))
                path.closeSubpath()
            }
            .stroke(theme.border, lineWidth: 1)
        }
        .frame(height: 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.fg)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func color(tokens: Int64, isFuture: Bool) -> Color {
        // 未来日期用 muted 半透明：浅色模式下也不至于和面板底色糊成一片。
        if isFuture { return theme.muted.opacity(0.3) }
        return MonthHeatmapBand.band(for: tokens).color(in: theme)
    }

    private func dayLabel(_ day: Int) -> String {
        let month = calendar.component(.month, from: Date())
        let year = calendar.component(.year, from: Date())
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return "\(month)月\(day)日"
        }
        let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let weekday = weekdays[calendar.component(.weekday, from: date) - 1]
        return "\(month)月\(day)日 · \(weekday)"
    }

    private func dayText(_ day: Int) -> String {
        let components = calendar.dateComponents([.year, .month], from: Date())
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0, components.month ?? 0, day
        )
    }
}

// MARK: - .tiles：总计 / 本月 / 本周三张并排卡

private struct OverviewTilesView: View {
    let stats: MenuUsagePeriods
    let displayCurrency: DisplayCurrency
    let usdToCny: Double
    @Environment(\.mbTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            tile(title: "总计", usage: stats.total)
            tile(title: "本月", usage: stats.month)
            tile(title: "本周", usage: stats.week)
        }
        .padding(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
    }

    private func tile(title: String, usage: DailyUsage) -> some View {
        let amount = usage.tokenAmount
        let cache = usage.cacheUsage
        let details = [title, amount.detail, cache.detail].joined(separator: "\n")
        return VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(theme.muted)
            Text(verbatim: amount.aggregateText)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.fg)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(verbatim: usage.formattedCost(currency: displayCurrency, usdToCny: usdToCny))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(theme.fg2)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("缓存命中 \(cache.percentText)")
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(theme.fg2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.surface2))
        .overlay(
            // 卡片轮廓用 1px 边框而不是阴影：深浅色两种模式下都稳定可见。
            RoundedRectangle(cornerRadius: 8).stroke(theme.fg.opacity(0.12), lineWidth: 1)
        )
        .background(PopoverToolTip(text: details).accessibilityHidden(true))
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(verbatim: details))
    }
}

/// .srcline：绿点 + 数据源更新状态。
private struct SourceLine: View {
    let text: String
    @Environment(\.mbTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(theme.ok).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(theme.muted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 0, leading: 16, bottom: 12, trailing: 16))
    }
}

/// 细滚动条：AppKit 官方定制通道。SwiftUI ScrollView 在 macOS 底层就是
/// NSScrollView，从内容视图经 enclosingScrollView 拿到它，换上重绘过的
/// NSScroller——拖拽、滚动同步、overlay 自动淡出全部系统托管，只换外观。
private final class ThinScroller: NSScroller {
    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat {
        10
    }

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // 细条不画槽。悬停展开动效已撤：其触发链在自定义 scroller 上不可靠，
        // 保留的行为（细条、闪现、渐隐、拖拽）全部确定。
    }

    override func drawKnob() {
        let knob = rect(for: .knob)
        let width: CGFloat = 4
        let inset = NSRect(
            x: bounds.width - 3 - width,
            y: knob.origin.y + 2,
            width: width,
            height: max(24, knob.height - 4)
        )
        NSColor.tertiaryLabelColor.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: inset, xRadius: width / 2, yRadius: width / 2).fill()
    }
}

private struct ThinScrollerStyler: NSViewRepresentable {
    final class ProbeView: NSView {
        private weak var trackedScrollView: NSScrollView?
        private var trackingAreaInstalled: NSTrackingArea?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            guard let scrollView = enclosingScrollView else { return }
            if !(scrollView.verticalScroller is ThinScroller) {
                let scroller = ThinScroller()
                scroller.scrollerStyle = .overlay
                scrollView.verticalScroller = scroller
                scrollView.hasVerticalScroller = true
                scrollView.scrollerStyle = .overlay
                scrollView.autohidesScrollers = true
            }
            installTracking(on: scrollView)
        }

        /// 进出面板的滚动条礼仪：进面板闪现一下（提示有内容可滚），
        /// 离开面板立即渐隐（不等系统的淡出计时）。
        private func installTracking(on scrollView: NSScrollView) {
            guard trackedScrollView !== scrollView else { return }
            if let old = trackingAreaInstalled, let oldView = trackedScrollView {
                oldView.removeTrackingArea(old)
            }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            )
            scrollView.addTrackingArea(area)
            trackedScrollView = scrollView
            trackingAreaInstalled = area
        }

        override func mouseEntered(with event: NSEvent) {
            guard let scrollView = trackedScrollView else { return }
            scrollView.verticalScroller?.alphaValue = 1
            scrollView.flashScrollers()
        }

        override func mouseExited(with event: NSEvent) {
            guard let scroller = trackedScrollView?.verticalScroller else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                scroller.animator().alphaValue = 0
            }
        }
    }

    func makeNSView(context: Context) -> ProbeView {
        ProbeView()
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        // SwiftUI 更新可能重置底层 scroller，每次校验补装。
        nsView.apply()
    }
}

private struct PanelDivider: View {
    @Environment(\.mbTheme) private var theme

    var body: some View {
        Rectangle().fill(theme.border).frame(height: 1)
    }
}

/// 弹窗区块与标题。
private struct SectionBlock<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @Environment(\.mbTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(theme.muted)
                .kerning(0.5)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 10, leading: 16, bottom: 12, trailing: 16))
    }
}

// MARK: - .sec 峰谷时段：分时计价的当前档位与下次切换

/// 独立区块：每个采用峰谷定价的品牌一行，显示当前峰/谷与下次切换时刻。
/// 设计成按定价品牌归并而不是绑死 DeepSeek——后续厂商上分时价时，
/// ProviderStore.peakPricingRows 长出几行这里就多显示几行。生效前整块
/// 完全不显示、不做预告，到生效时刻起才出现。
private struct PeakPricingSection: View {
    let rows: [PeakPricingRow]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let active = rows.filter { $0.tier.phase(at: context.date) != .notYetEffective }
            if active.isEmpty {
                EmptyView()
            } else {
                VStack(spacing: 0) {
                    ForEach(active) { row in
                        PeakPhaseRow(row: row, now: context.date)
                    }
                }
            }
        }
    }
}

private struct PeakPhaseRow: View {
    let row: PeakPricingRow
    let now: Date
    @Environment(\.mbTheme) private var theme

    private var phase: PeakOffPeakPhase { row.tier.phase(at: now) }

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)

            HStack(spacing: 6) {
                Text(row.brandName)
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.fg)
                    .lineLimit(1)
                Text(phaseLabel)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(dotColor)
            }

            Spacer(minLength: 8)

            Text(transitionText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.muted)
                .monospacedDigit()
                .fixedSize()
        }
        .padding(.vertical, 5)
        .help(helpText)
    }

    private var dotColor: Color {
        switch phase {
        case .peak: return theme.warn
        case .offPeak, .notYetEffective: return theme.ok
        }
    }

    private var phaseLabel: String {
        switch phase {
        case .peak: return "峰"
        case .offPeak, .notYetEffective: return "谷"
        }
    }

    private var transitionText: String {
        guard let transition = row.tier.nextTransition(after: now) else { return "" }
        let time = Self.timeText(transition.at, sameDayAs: now)
        switch transition.phase {
        case .peak: return "\(time) 转峰"
        case .offPeak, .notYetEffective: return "\(time) 转谷"
        }
    }

    /// 时段说明收进悬停提示，行内只留明确标识。
    private var helpText: String {
        let windows = row.tier.beijingPeakRanges.map { start, end in
            String(format: "%d:00–%d:00", start, end)
        }
        .joined(separator: "、")
        var lines = [
            "\(row.brandName)：\(row.modelNames.joined(separator: " / "))",
            "高峰：\(windows)（北京时间）",
        ]
        if row.tier.weekdaysOnly {
            lines.append("仅工作日；周末与法定节假日整天空闲")
        }
        return lines.joined(separator: "\n")
    }

    /// 同一天只显示时刻，跨天带日期与星期（用户机器时区，通常是北京）。
    private static func timeText(_ date: Date, sameDayAs now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "M/d (EEE) HH:mm"
        return formatter.string(from: date)
    }
}

private struct DisclosureChevron: View {
    let isExpanded: Bool
    @Environment(\.mbTheme) private var theme

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(theme.muted)
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .accessibilityHidden(true)
    }
}

private struct UsageTableHeader: View {
    let title: String
    var count = 0
    var expanded: Binding<Bool>?
    @Environment(\.mbTheme) private var theme

    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            Group {
                if let expanded, count > PopoverUsageList.previewCount {
                    disclosureButton(expanded: expanded)
                } else {
                    titleLabel
                }
            }
            .frame(maxWidth: .infinity, minHeight: 14, alignment: .leading)
            Text("Token")
            Text("花费")
            Text("缓存命中")
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(theme.muted)
        .lineLimit(1)
    }

    private var titleLabel: some View {
        Text(verbatim: title)
            .foregroundStyle(theme.fg)
    }

    private func disclosureButton(expanded: Binding<Bool>) -> some View {
        let shown = PopoverUsageList.visibleCount(count, expanded: expanded.wrappedValue)
        let action = expanded.wrappedValue ? "收起\(title)" : "展开全部\(title)"
        // 不用 Button：菜单栏打开时系统会给第一个按钮套强调色，Agent 就会和模型看起来不是同一层。
        return HStack(spacing: 4) {
            titleLabel
            Text(verbatim: "\(shown)/\(count)")
                .monospacedDigit()
                .foregroundStyle(theme.muted)
            DisclosureChevron(isExpanded: expanded.wrappedValue)
        }
        .contentShape(Rectangle())
        .onTapGesture { expanded.wrappedValue.toggle() }
        .help(action)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: action))
        .accessibilityValue(Text(verbatim: "显示 \(shown) 项，共 \(count) 项"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { expanded.wrappedValue.toggle() }
    }
}

private struct DailyUsageGrid: View {
    let machines: [NodeDeviceSummary]
    let agents: [DailyAgentRow]
    let models: DailyModelSummary?
    let displayCurrency: DisplayCurrency
    let usdToCny: Double
    @AppStorage(PopoverUsageList.agents.rawValue) private var agentsExpanded = false
    @AppStorage(PopoverUsageList.models.rawValue) private var modelsExpanded = false
    @Environment(\.mbTheme) private var theme

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 8, verticalSpacing: 5) {
            if !machines.isEmpty {
                UsageTableHeader(title: "机器")
                ForEach(machines) { device in
                    usageRow(device.usage) {
                        let lastSeen = device.observed.formatted(date: .abbreviated, time: .shortened)
                        let info = device.partialSources > 0 ? " · \(device.partialSources) 个来源未更新" : ""
                        Text(verbatim: device.name)
                            .lineLimit(1).truncationMode(.middle)
                            .help("\(device.name)\(device.local ? "（本机）" : "") · 最后采集 \(lastSeen)\(info)")
                    }
                }
            }
            if !agents.isEmpty {
                UsageTableHeader(title: "Agent", count: agents.count, expanded: $agentsExpanded)
                    .padding(.top, machines.isEmpty ? 0 : 4)
                ForEach(agents.prefix(PopoverUsageList.visibleCount(agents.count, expanded: agentsExpanded))) { row in
                    usageRow(row.usage) { AgentNameCell(row: row) }
                }
            }
            if let models, !models.rows.isEmpty {
                UsageTableHeader(title: "模型", count: models.rows.count, expanded: $modelsExpanded)
                    .padding(.top, machines.isEmpty && agents.isEmpty ? 0 : 4)
                ForEach(models.rows.prefix(PopoverUsageList.visibleCount(
                    models.rows.count, expanded: modelsExpanded
                ))) { row in
                    modelRow(row.id, usage: row.usage)
                }

                Rectangle().fill(theme.border).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                modelRow("合计", usage: models.total)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func usageRow(_ metrics: DailyUsage, @ViewBuilder name: () -> some View) -> some View {
        GridRow {
            name().frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: metrics.tokenAmount.dailyText).help(metrics.tokenAmount.detail)
            Text(verbatim: metrics.formattedCost(currency: displayCurrency, usdToCny: usdToCny))
                .help(metrics.unknownCost > 0 ? "部分用量未能计价" : "花费")
            Text(verbatim: metrics.cacheUsage.percentText).help(metrics.cacheUsage.detail)
        }
        .lineLimit(1)
        .font(.system(size: 11, design: .monospaced)).monospacedDigit()
        .foregroundStyle(theme.fg)
        .accessibilityElement(children: .combine)
    }

    private func modelRow(_ name: String, usage: DailyUsage) -> some View {
        let amount = usage.tokenAmount
        let cache = usage.cacheUsage
        return GridRow {
            HStack(spacing: 4) {
                Group {
                    if name != "合计" {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(theme.muted)
                            .frame(width: 7, height: 7)
                    }
                }
                .frame(width: 14, height: 7)
                .accessibilityHidden(true)
                Text(verbatim: name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(name)
            Text(verbatim: amount.dailyText)
                .rollingNumber(value: amount.tokens)
                .help(amount.detail)
            Text(usage.formattedCost(currency: displayCurrency, usdToCny: usdToCny))
                .foregroundStyle(theme.fg2)
                .rollingNumber(value: usage.costMicros)
            Text(verbatim: cache.percentText)
                .help(cache.detail)
                .accessibilityLabel(Text(verbatim: cache.detail))
        }
        .font(.system(size: 11, design: .monospaced))
        .monospacedDigit()
        .foregroundStyle(theme.fg)
    }
}

private struct AgentNameCell: View {
    let row: DailyAgentRow
    @Environment(\.mbTheme) private var theme

    var body: some View {
        let label = MenuBarProviderName.label(row.id)
        let sessions = row.sessions.map { "\($0) 会话" }
        let credits = row.creditsPicos.map(MenuBarNumberFormat.credits)
        HStack(alignment: .center, spacing: 4) {
            AgentBrandMark(providerId: row.id)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: label)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.fg)
                    .truncationMode(.middle)
                if let sessions {
                    Text(verbatim: sessions).fixedSize(horizontal: true, vertical: false)
                }
                if let credits { Text(verbatim: credits) }
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(theme.muted)
        .lineLimit(1)
        .help([label, sessions, credits].compactMap { $0 }.joined(separator: " · "))
    }
}

// MARK: - 订阅额度：.qgroup 折叠组

/// snapshot → 稿上元素的显示模型。
struct QuotaDisplayModel {
    /// 环资格的窗口时长上限：≤7 天（日内/周窗）属于「关注级」可当环；月级及以上
    /// 一律长条。绝对阈值而非相对排名——候选不足时排名会递补，阈值不会。
    static let ringWindowCeilingMinutes = 7 * 24 * 60

    struct Ring: Identifiable {
        let id: String
        let label: String
        /// 剩余百分比（与折叠行 summary、tmux 段同语义：数值越大额度越充裕）。
        let percent: Double
        let resetText: String?
        let note: String?
        /// 时间进度感知的警戒色（tmux 同款 pace 逻辑）：用量明显跑赢时间进度才
        /// 黄/红；快到重置时剩得少也算绿。见 UsageMetricToneResolver。
        let tone: UsageMetricTone
    }

    struct Bar {
        let label: String
        /// 剩余百分比（同 Ring）。
        let percent: Double?
        let resetText: String?
        let note: String?
        let tone: UsageMetricTone
    }

    /// 折叠行摘要的一段（「5h 64%」）：文案与环同源的 tone，收起时也能一眼看出警戒。
    struct SummarySegment {
        let text: String
        let tone: UsageMetricTone
    }

    struct DetailRow: Identifiable {
        let id: [String]
        let label: String
        let value: String
        let exactValue: String
        var help: String { "\(label) · \(exactValue)" }
    }

    /// 登录过期时悬浮在感叹号上的操作说明。
    static let grokLoginHelp = "登录已过期。打开终端运行 grok login，完成后点重试或等待下次自动刷新。"

    let badge: String
    let name: String
    let isWarn: Bool
    let needsLogin: Bool
    let statusHelp: String?
    let staleMinutes: Int?
    var summaryText: String { plainSummary ?? summarySegments.map(\.text).joined(separator: " · ") }
    let plainSummary: String?
    let plainSummaryHelp: String?
    let summarySegments: [SummarySegment]
    let alertMessage: String?
    let alertTime: String?
    /// 菜单栏可选的主额度时间窗口；与弹窗环位分开，包含 30d 等长周期。
    let menuBarWindows: [Ring]
    let rings: [Ring]
    let bars: [Bar]
    let resetCredits: ResetCreditSummary?
    let creditDetails: [DetailRow]

    var hasDetails: Bool {
        staleMinutes != nil || alertMessage != nil || !rings.isEmpty || !bars.isEmpty
            || (resetCredits?.availableCount ?? 0) > 0 || !creditDetails.isEmpty
    }

    init(snapshot: ProviderUsageSnapshot, now: Date = Date()) {
        name = snapshot.displayName
        badge = Self.badgeText(snapshot.displayName)

        // 摊平时带上组名：多组时代（Codex 主额度 + Spark 模型额度、Claude 的
        // Fable 等 scoped 额度）只写「7d」分不清是谁的额度；主组（组名与
        // provider 同名）保持只用窗口标签。
        let labeledMetrics = snapshot.groups.flatMap { group in
            group.items.map { metric -> (label: String, metric: UsageMetric, isPrimary: Bool, groupID: String) in
                let window = Self.shortWindowLabel(metric)
                let isGoogle = snapshot.providerId == AntigravityQuota.providerID
                let isPrimary = isGoogle ? group.id == "gemini"
                    : (snapshot.providerId == "codex" ? group.id == "codex" : group.title == snapshot.displayName)
                let label = (isPrimary && !isGoogle) || group.title == window ? window : "\(group.title) \(window)"
                return (label, metric, isPrimary, group.id)
            }
        }
        let warnStatuses: [UsageStatus] = [.warning, .error]
        let metricWarnings = labeledMetrics.compactMap { Self.warning(for: $0.metric, label: $0.label) }
        isWarn = warnStatuses.contains(snapshot.status) || !metricWarnings.isEmpty
        let loginHint = [snapshot.message, snapshot.summary]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        needsLogin = snapshot.status == .error && (
            loginHint.contains("未登录") || loginHint.contains("grok login")
        )
        let staleSeconds = now.timeIntervalSince(snapshot.fetchedAt)
        staleMinutes = staleSeconds >= 600 ? Int(staleSeconds / 60) : nil
        let message = snapshot.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason: String?
        if needsLogin && (snapshot.providerId == "grok" || loginHint.contains("grok login")) {
            reason = Self.grokLoginHelp
        } else if warnStatuses.contains(snapshot.status), let message, !message.isEmpty {
            reason = message
        } else if !metricWarnings.isEmpty {
            reason = metricWarnings.joined(separator: "\n")
        } else if isWarn {
            let summary = snapshot.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
            reason = summary.flatMap { $0.isEmpty ? nil : $0 }
                ?? (snapshot.status == .error ? "\(name) 额度查询失败" : "\(name) 返回了额度告警")
        } else {
            reason = nil
        }
        let reasons = [reason, staleMinutes.map(Self.staleDataText)].compactMap { $0 }
        statusHelp = reasons.isEmpty ? nil : reasons.joined(separator: "\n")

        // 环＝主组（组名与 provider 同名）里【≤7 天或没有时间窗】的 quota，按时间窗
        // 升序、原始顺序稳定地取至多两只。没有时间窗不等于次要额度：Qoder 的套餐与
        // 加购都是一等可消费额度，必须并列用环展示。两条硬语义边界：
        // - 候选不足两只就少画，【绝不递补】：OpenCode 的 Monthly 曾在 5h 行解析失败时
        //   被顶进环位——月级与模型级次要额度属于「条」的世界，不因环缺而升级。
        //   资格线因此必须是绝对阈值而非相对排名：只剩两只候选时「前二」仍会把月窗收进来。
        // - 次要组永远不进环；主组第三项及月级以上额度仍为条。
        let percentMetrics = labeledMetrics.filter { $0.metric.usedPercent != nil }
        // 状态异常/用尽直接红；其余交给时间进度感知的 pace 逻辑。
        func metricTone(_ metric: UsageMetric) -> UsageMetricTone {
            if warnStatuses.contains(metric.status) || (metric.usedPercent ?? 0) >= 99.5 {
                return .bad
            }
            return UsageMetricToneResolver.tone(for: metric)
        }

        let primaryWindowMetrics = percentMetrics
            .filter { entry in
                entry.isPrimary
                    && entry.metric.kind == .quota
                    && (entry.metric.windowDurationMinutes != nil || snapshot.providerId == "codex")
            }
            .enumerated()
            .sorted { lhs, rhs in
                let lhsWindow = lhs.element.metric.windowDurationMinutes ?? Int.max
                let rhsWindow = rhs.element.metric.windowDurationMinutes ?? Int.max
                return lhsWindow == rhsWindow ? lhs.offset < rhs.offset : lhsWindow < rhsWindow
            }
            .map(\.element)
        menuBarWindows = primaryWindowMetrics.map { entry in
            Ring(
                id: entry.metric.id,
                label: snapshot.providerId == AntigravityQuota.providerID ? Self.shortWindowLabel(entry.metric) : entry.label,
                percent: Self.remainingPercent(entry.metric),
                resetText: entry.metric.resetText,
                note: entry.metric.detail,
                tone: metricTone(entry.metric)
            )
        }

        let ringCandidates = percentMetrics
            .filter { entry in
                guard entry.isPrimary, entry.metric.kind == .quota else { return false }
                guard let window = entry.metric.windowDurationMinutes else { return true }
                return window <= Self.ringWindowCeilingMinutes
            }
            .enumerated()
            .sorted { lhs, rhs in
                let lhsWindow = lhs.element.metric.windowDurationMinutes ?? Int.max
                let rhsWindow = rhs.element.metric.windowDurationMinutes ?? Int.max
                return lhsWindow == rhsWindow ? lhs.offset < rhs.offset : lhsWindow < rhsWindow
            }
            .map(\.element)
        let ringMetrics = Array(
            ringCandidates.prefix(2)
        )
        let ringIds = Set(ringMetrics.map(\.metric.id))
        rings = ringMetrics.map { entry in
            Ring(
                id: entry.metric.id,
                label: entry.label,
                percent: Self.remainingPercent(entry.metric),
                resetText: entry.metric.resetText,
                note: entry.metric.detail,
                tone: metricTone(entry.metric)
            )
        }
        bars = percentMetrics.filter { !ringIds.contains($0.metric.id) }.map { entry in
            Bar(
                label: entry.label,
                percent: Self.remainingPercent(entry.metric),
                resetText: entry.metric.resetText,
                note: entry.metric.detail,
                tone: metricTone(entry.metric)
            )
        }

        // 折叠态优先复用环摘要；像 Qoder Credits、智谱 MCP 这类没有可验证
        // 时间窗的额度只会进入条位，仍需给出摘要，避免整行只剩供应商名称。
        // 条位最多展示两项，完整列表留在展开态，防止窄弹窗被三项以上额度挤爆。
        if rings.isEmpty {
            summarySegments = bars.prefix(2).compactMap { bar in
                bar.percent.map {
                    SummarySegment(text: "\(bar.label) \(Int($0.rounded()))%", tone: bar.tone)
                }
            }
        } else {
            summarySegments = rings.enumerated().map { index, ring in
                let label = snapshot.providerId == AntigravityQuota.providerID
                    ? Self.shortWindowLabel(ringMetrics[index].metric) : ring.label
                return SummarySegment(text: "\(label) \(Int(ring.percent.rounded()))%", tone: ring.tone)
            }
        }
        // 额度用尽已经由红色环与标题告警完整表达，不再额外堆一张大号“额度提醒”卡。
        // 其它无法从指标本身读出的告警仍保留消息卡。
        let warningRepresentedByQuota = snapshot.status == .warning
            && labeledMetrics.contains { ($0.metric.usedPercent ?? 0) >= 99.5 || ($0.metric.remainingPercent ?? 100) <= 0.5 }
        if isWarn, !warningRepresentedByQuota, let message = snapshot.message, !message.isEmpty {
            alertMessage = message
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            alertTime = formatter.string(from: snapshot.fetchedAt)
        } else {
            alertMessage = nil
            alertTime = nil
        }

        resetCredits = snapshot.resetCredits
        let quantities = labeledMetrics.flatMap { entry -> [DetailRow] in
            let m = entry.metric
            guard m.usedPercent == nil, m.remainingPercent == nil else { return [] }
            let fields = [("剩余", m.remainingAmount), ("已用", m.usedAmount), ("总额", m.totalAmount)]
                .compactMap { field, value in value.flatMap { $0.isEmpty ? nil : (field, $0) } }
            if fields.isEmpty, snapshot.providerId == AntigravityQuota.providerID, let detail = m.detail {
                return [DetailRow(id: [entry.groupID, m.id], label: entry.label, value: detail, exactValue: detail)]
            }
            return fields.compactMap { field, raw in
                if field == "剩余", Self.duplicatesWallet(m, raw: raw, wallet: snapshot.accountCredits) { return nil }
                let label = fields.count == 1 && field == "剩余" ? entry.label : "\(entry.label) · \(field)"
                let unit = m.unit.flatMap { $0.isEmpty ? nil : " " + $0 } ?? ""
                return DetailRow(id: [entry.groupID, m.id, field], label: label,
                                 value: Self.compactAmount(raw) + unit, exactValue: raw + unit)
            }
        }
        var extras: [DetailRow] = []
        if case let .claude(_, extra?) = snapshot.accountCredits {
            extras = [
                ("额外用量", extra.enabled == false ? "已关闭" : nil),
                ("本月额外已用", extra.used?.displayText),
                ("每月支出上限", extra.monthlyLimit?.displayText)
            ].compactMap { label, value in
                value.map { DetailRow(id: ["account", label], label: label, value: $0, exactValue: $0) }
            }
        }
        let canUseHeader = summarySegments.isEmpty && snapshot.status == .ok && !isWarn
            && snapshot.accountCredits?.displayBalance == nil && extras.isEmpty && (resetCredits?.availableCount ?? 0) == 0
        let summary = snapshot.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        if canUseHeader, quantities.count == 1, let row = quantities.first {
            if labeledMetrics.count == 1, labeledMetrics[0].metric.kind == .tokens, let summary, !summary.isEmpty {
                plainSummary = summary
            } else {
                plainSummary = "\(row.label) \(row.value)"
            }
            plainSummaryHelp = row.help
            creditDetails = []
        } else {
            creditDetails = quantities + extras
            let windows = Set(quantities.map { Array($0.id.prefix(2)) })
            if canUseHeader, windows.count > 1 {
                plainSummary = "\(windows.count) 项额度"
            } else {
                plainSummary = canUseHeader && creditDetails.isEmpty && snapshot.providerId != AntigravityQuota.providerID
                    ? summary.flatMap { $0.isEmpty ? nil : $0 } : nil
            }
            plainSummaryHelp = plainSummary
        }
    }

    private static func compactAmount(_ raw: String) -> String {
        guard raw.count > 14 else { return raw }
        if let number = Double(raw), number.isFinite, number != 0 {
            return String(format: "%.6g", locale: Locale(identifier: "en_US_POSIX"), number)
        }
        return "\(raw.prefix(8))…\(raw.suffix(4))"
    }

    private static func duplicatesWallet(_ metric: UsageMetric, raw: String, wallet: AccountCredits?) -> Bool {
        guard metric.kind == .balance, wallet?.displayBalance != nil else { return false }
        let unit = metric.unit?.lowercased() ?? ""
        let amount: Decimal
        switch wallet {
        case .codex(.amount(let value)) where ["credits", "credit", "积分"].contains(unit):
            amount = value
        case .claude(let prepaid?, _) where prepaid.currency.lowercased() == unit:
            amount = prepaid.value
        default:
            return false
        }
        var normalized = raw
        if normalized.contains(".") {
            while normalized.last == "0" { normalized.removeLast() }
            if normalized.last == "." { normalized.removeLast() }
        }
        return NSDecimalNumber(decimal: amount).stringValue == normalized
    }

    /// 「智谱 GLM」→「智」；「Claude Code」→「Cl」（稿：badge 双字符/单汉字）。
    static func badgeText(_ name: String) -> String {
        guard let first = name.first else { return "?" }
        if first.isASCII {
            let letters = name.filter { $0.isLetter && $0.isASCII }
            return String(letters.prefix(2)).capitalized
        }
        return String(first)
    }

    static func remainingPercent(_ metric: UsageMetric) -> Double {
        min(100, max(0, metric.remainingPercent ?? (100 - (metric.usedPercent ?? 0))))
    }

    private static func warning(for metric: UsageMetric, label: String) -> String? {
        let detail = metric.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        if metric.status == .error {
            return detail.flatMap { $0.isEmpty ? nil : "\(label)：\($0)" } ?? "\(label) 额度读取失败"
        }
        let remaining = metric.remainingPercent ?? metric.usedPercent.map { 100 - $0 }
        if let remaining, remaining <= 0.5 {
            return remaining <= 0 ? "\(label) 额度已用尽" : "\(label) 额度剩余不足 1%"
        }
        guard metric.status == .warning else { return nil }
        if let detail, !detail.isEmpty { return "\(label)：\(detail)" }
        if let remaining { return "\(label) 额度告警，剩余 \(UsageFormatter.numberText(remaining))%" }
        return "\(label) 额度告警"
    }

    static func staleDataText(minutes: Int) -> String {
        let age: String
        if minutes < 60 { age = "\(minutes) 分钟" }
        else if minutes < 24 * 60 { age = "\(minutes / 60) 小时" }
        else { age = "\(minutes / (24 * 60)) 天" }
        return "当前显示 \(age)前的额度数据"
    }

    /// 窗口标签压缩为稿上的「5h / 7d」形态；识别不了就用原 label。
    static func shortWindowLabel(_ metric: UsageMetric) -> String {
        if let minutes = metric.windowDurationMinutes {
            if minutes % (24 * 60) == 0 { return "\(minutes / (24 * 60))d" }
            if minutes % 60 == 0 { return "\(minutes / 60)h" }
            return "\(minutes)m"
        }
        return metric.label
    }
}

private struct QuotaGroupView: View {
    let snapshot: ProviderUsageSnapshot
    /// 展开态由列表层受控（手风琴：至多一家展开），不再各组自持。
    let isExpanded: Bool
    let isRefreshing: Bool
    let onToggleExpanded: () -> Void
    let onRetry: () -> Void
    @Environment(\.mbTheme) private var theme
    private let model: QuotaDisplayModel

    init(
        snapshot: ProviderUsageSnapshot,
        isExpanded: Bool,
        isRefreshing: Bool = false,
        onToggleExpanded: @escaping () -> Void,
        onRetry: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.isExpanded = isExpanded
        self.isRefreshing = isRefreshing
        self.onToggleExpanded = onToggleExpanded
        self.onRetry = onRetry
        self.model = QuotaDisplayModel(snapshot: snapshot)
    }

    var body: some View {
        VStack(spacing: 0) {
            summaryRow
                .contextMenu {
                    Button("刷新额度", action: onRetry).disabled(isRefreshing)
                }

            if isExpanded && model.hasDetails {
                VStack(alignment: .leading, spacing: 0) {
                    PanelDivider()

                    VStack(alignment: .leading, spacing: 8) {
                        let failure = snapshot.providerId == AntigravityQuota.providerID && (snapshot.status == .error || (snapshot.status == .warning && !snapshot.groups.isEmpty))
                            ? snapshot.message : nil
                        if model.staleMinutes != nil || failure != nil, let help = model.statusHelp {
                            StaleCard(minutes: model.staleMinutes, help: help, failure: failure,
                                      hasPreviousReading: !snapshot.groups.isEmpty,
                                      isRefreshing: isRefreshing, onRetry: onRetry)
                        }

                        if let message = model.alertMessage, failure == nil {
                            AlertCard(message: message, time: model.alertTime)
                        }

                        if !model.rings.isEmpty {
                            HStack(spacing: 8) {
                                ForEach(model.rings) { ring in
                                    QRingCard(ring: ring)
                                }
                            }
                        }

                        ForEach(model.bars.indices, id: \.self) { i in
                            BarRowCard(bar: model.bars[i])
                        }

                        if let credits = model.resetCredits, credits.availableCount > 0 {
                            ResetCardsGroup(summary: credits)
                        }
                        ForEach(model.creditDetails, content: creditDetail)
                    }
                    .padding(EdgeInsets(top: 10, leading: 12, bottom: 12, trailing: 12))
                    .opacity(model.staleMinutes != nil ? 0.9 : 1)
                }
            }
        }
        .background(theme.bg)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        )
    }

    private func creditDetail(_ row: QuotaDisplayModel.DetailRow) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: row.label).foregroundStyle(theme.fg2)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text(verbatim: row.value).monospacedDigit().foregroundStyle(theme.fg)
                .lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 12))
        .background(PopoverToolTip(text: row.help).accessibilityHidden(true))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: row.help))
    }

    @ViewBuilder private var summaryRow: some View {
        // 内容即时插拔，不做 SwiftUI 高度动画——面板高度的平滑过渡由 NSPopover 的
        // contentSize 原生动画负责，两边同时动画会互相打架（内容先压扁再弹开）。
        if model.hasDetails {
            Button(action: onToggleExpanded) { summaryHeader }
                .buttonStyle(.plain)
                .focusable(false)
        } else {
            summaryHeader.accessibilityElement(children: .combine)
        }
    }

    private var summaryHeader: some View {
        HStack(spacing: 8) {
            Text(model.badge)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.accent)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.surface2))

            if let credits = snapshot.accountCredits?.displayBalance {
                let balance = Text(verbatim: credits.compact)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(theme.fg2)
                    .lineLimit(1)
                    .background(PopoverToolTip(text: credits.help).accessibilityHidden(true))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: credits.help))
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 7) {
                        providerName
                        balance
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        providerName
                        balance
                    }
                }
            } else {
                providerName
            }

            Spacer(minLength: 8)

            // 摘要各段跟随环的 tone（tmux 同款：健康绿/超速黄/用尽红），
            // 展开与收起都显示——展开后它就是标题行的速览。
            if let text = model.plainSummary {
                Text(verbatim: text)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.fg2)
                    .monospacedDigit()
                    .lineLimit(1)
                    .background(PopoverToolTip(text: model.plainSummaryHelp ?? text).accessibilityHidden(true))
                    .accessibilityLabel(Text(verbatim: model.plainSummaryHelp ?? text))
            } else {
                model.summarySegments.enumerated().reduce(Text("")) { acc, pair in
                    acc
                        + Text(pair.offset > 0 ? " · " : "").foregroundColor(theme.muted)
                        + Text(pair.element.text)
                            .foregroundColor(summaryToneColor(pair.element.tone, theme: theme))
                }
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .lineLimit(1)
                .layoutPriority(1)
            }

            if model.hasDetails {
                DisclosureChevron(isExpanded: isExpanded)
                    .animation(.easeOut(duration: 0.15), value: isExpanded)
            }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .contentShape(Rectangle())
    }

    private var providerName: some View {
        HStack(spacing: 6) {
            Text(model.name)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.fg)
                .lineLimit(1)

            if let help = model.statusHelp {
                Group {
                    if model.needsLogin {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.danger)
                    } else {
                        WarnTriangle()
                    }
                }
                .frame(width: 16, height: 18)
                .background(PopoverToolTip(text: help))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: help))
            }
        }
    }
}

/// 原生提示区域可在菜单栏弹窗的按钮和统计卡内分别命中。
private struct PopoverToolTip: NSViewRepresentable {
    let text: String

    final class View: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> View {
        let view = View()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: View, context: Context) {
        if view.toolTip != text { view.toolTip = text }
    }
}

/// 稿 .gwarn：警告三角。
private struct WarnTriangle: View {
    @Environment(\.mbTheme) private var theme

    var body: some View {
        ZStack {
            Path { p in
                p.move(to: CGPoint(x: 7, y: 1.5))
                p.addLine(to: CGPoint(x: 13, y: 12))
                p.addLine(to: CGPoint(x: 1, y: 12))
                p.closeSubpath()
            }
            .stroke(theme.warn, style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))

            Path { p in
                p.move(to: CGPoint(x: 7, y: 6))
                p.addLine(to: CGPoint(x: 7, y: 8.6))
            }
            .stroke(theme.warn, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))

            Circle()
                .fill(theme.warn)
                .frame(width: 1.4, height: 1.4)
                .offset(y: 3.4)
        }
        .frame(width: 14, height: 14)
    }
}

// MARK: - .alert / .stale 卡

private struct AlertCard: View {
    let message: String
    let time: String?
    @Environment(\.mbTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            WarnTriangle()
                .frame(width: 13, height: 13)
                .padding(.top, 1)
                .background(PopoverToolTip(text: message))

            VStack(alignment: .leading, spacing: 2) {
                Text("额度提醒")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.warn)
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.fg2)
                    .lineSpacing(2)
                    .lineLimit(3)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            if let time {
                Text(time)
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.muted)
            }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.tintWarn))
    }
}

private struct StaleCard: View {
    let minutes: Int?
    let help: String
    let failure: String?
    let hasPreviousReading: Bool
    let isRefreshing: Bool
    let onRetry: () -> Void
    @Environment(\.mbTheme) private var theme

    var body: some View {
        let showWarning = failure != nil && hasPreviousReading
        let accent = showWarning ? theme.warn : theme.danger
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(accent)
                .padding(.top, 1)
                .background(PopoverToolTip(text: help))
                .accessibilityLabel(Text(verbatim: help))

            VStack(alignment: .leading, spacing: 2) {
                Text(failure == nil ? "额度数据待更新" : "额度刷新失败")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent)
                if let failure { Text(failure).font(.system(size: 11.5)).foregroundStyle(theme.fg) }
                if let minutes { Text(QuotaDisplayModel.staleDataText(minutes: minutes))
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.fg2)
                    .lineSpacing(2)
                    .lineLimit(2)
                    .truncationMode(.tail)
                }
            }

            Spacer(minLength: 8)

            Button(isRefreshing ? "刷新中" : "重试", action: onRetry)
                .disabled(isRefreshing)
                .buttonStyle(.plain)
                .focusable(false)
                .font(.system(size: 11))
                .foregroundStyle(theme.fg)
                .padding(EdgeInsets(top: 3, leading: 11, bottom: 3, trailing: 11))
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme.surface)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.border, lineWidth: 1))
                )
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .background(RoundedRectangle(cornerRadius: 8).fill(showWarning ? theme.tintWarn : theme.tintDanger))
    }
}

// MARK: - 环形主额度（.qring：44×44，r19 stroke4，-90° 起笔）

/// tone → 主题色。ok = 绿（用户裁定 2026-07-17：额度安全就该是绿色，
/// 原「正常态用 accent」的设计语言只保留给 muted/数据不足）。
private func toneStroke(_ tone: UsageMetricTone, theme: MBTheme) -> Color {
    switch tone {
    case .warning: return theme.warn
    case .bad: return theme.danger
    case .ok: return theme.ok
    case .muted: return theme.accent
    }
}

private func toneText(_ tone: UsageMetricTone, theme: MBTheme) -> Color {
    switch tone {
    case .warning: return theme.warn
    case .bad: return theme.danger
    case .ok, .muted: return theme.fg
    }
}

/// 折叠行摘要的分段色（tmux 同款语义）：健康绿、超速黄、用尽/严重超速红；
/// 无法判定 pace 的（缺窗口/重置时间）保持 muted。
private func summaryToneColor(_ tone: UsageMetricTone, theme: MBTheme) -> Color {
    switch tone {
    case .ok: return theme.ok
    case .warning: return theme.warn
    case .bad: return theme.danger
    case .muted: return theme.muted
    }
}

private struct QRingCard: View {
    let ring: QuotaDisplayModel.Ring
    @Environment(\.mbTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 打开弹窗/展开分组时环从 0 充盈到实际占比；数据刷新时随 percent 平滑过渡。
    /// 只动 trim 不动 frame（44×44 固定），不触碰 NSPopover 的高度协调。
    @State private var appeared = false

    private var fraction: CGFloat {
        CGFloat(min(100, max(0, ring.percent))) / 100
    }

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .stroke(theme.surface2, lineWidth: 4)
                Circle()
                    .trim(from: 0, to: appeared ? fraction : 0)
                    .stroke(
                        toneStroke(ring.tone, theme: theme),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: ring.percent)
                Text("\(Int(ring.percent.rounded()))%")
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(toneText(ring.tone, theme: theme))
                    .monospacedDigit()
                    .rollingNumber(value: Int(ring.percent.rounded()))
            }
            .frame(width: 44, height: 44)
            .onAppear {
                if reduceMotion {
                    appeared = true
                } else {
                    withAnimation(.smooth(duration: 0.55)) { appeared = true }
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(ring.label)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(theme.fg)
                    .lineLimit(1)
                if let reset = ring.resetText {
                    Text(reset)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                if let note = ring.note {
                    ViewThatFits(in: .horizontal) {
                        Text(note)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(theme.muted)
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)

                        Text(note)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(theme.muted)
                            .monospacedDigit()
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border, lineWidth: 1))
        )
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 水平条子额度（.brow）

private struct BarRowCard: View {
    let bar: QuotaDisplayModel.Bar
    @Environment(\.mbTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 打开弹窗/展开分组时条从 0 充盈到实际占比；刷新时随 percent 平滑过渡。
    /// 只动填充宽度，轨道高度固定 4，不触碰 NSPopover 的高度协调。
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(bar.label)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.fg)
                    .lineLimit(1)
                if let percent = bar.percent {
                    Text("\(Int(percent.rounded()))%")
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(toneText(bar.tone, theme: theme))
                        .monospacedDigit()
                        .rollingNumber(value: Int(percent.rounded()))
                }
                if let reset = bar.resetText {
                    Text(reset)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let note = bar.note {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.muted)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.surface2)
                    Capsule()
                        .fill(toneStroke(bar.tone, theme: theme))
                        .frame(width: appeared ? proxy.size.width * CGFloat(min(100, max(0, bar.percent ?? 0))) / 100 : 0)
                        .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: bar.percent)
                }
            }
            .frame(height: 4)
            .onAppear {
                if reduceMotion {
                    appeared = true
                } else {
                    withAnimation(.smooth(duration: 0.55)) { appeared = true }
                }
            }
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border, lineWidth: 1))
        )
    }
}

// MARK: - 重置卡组（.rcgroup：虚线框，可展开）

private struct ResetCardsGroup: View {
    let summary: ResetCreditSummary
    @Environment(\.mbTheme) private var theme
    @State private var expanded = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        let earliest = ResetCreditDisplay.items(for: summary, now: now)
            .first { $0.credit.expiresAt != nil }

        return VStack(spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.accent)

                    (Text("重置卡 ") + Text("\(summary.availableCount) 张").fontWeight(.semibold))
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.fg)

                    Spacer(minLength: 8)

                    if let earliest {
                        Text(earliest.remainingText)
                            .font(.system(size: 10))
                            .foregroundStyle(theme.muted)
                            .lineLimit(1)
                            .help("最快到期的重置卡")
                    }

                    DisclosureChevron(isExpanded: expanded)
                        .animation(.easeOut(duration: 0.15), value: expanded)
                }
                .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)

            if expanded {
                VStack(spacing: 8) {
                    ForEach(summary.credits.indices, id: \.self) { i in
                        ResetCardRow(item: ResetCreditDisplay.item(
                            index: i + 1, credit: summary.credits[i], now: now
                        ))
                    }
                }
                .padding(EdgeInsets(top: 0, leading: 10, bottom: 10, trailing: 10))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }
}

private struct ResetCardRow: View {
    let item: ResetCreditDisplayItem
    @Environment(\.mbTheme) private var theme

    private var lifetimeColor: Color {
        switch item.tone {
        case .ok: return theme.accent
        case .warning: return theme.warn
        case .bad: return theme.danger
        }
    }

    private func shortDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("#\(item.index)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.muted)
                Text("\(shortDate(item.credit.issuedAt)) 发放")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.fg2)
                Spacer(minLength: 8)
                if item.credit.expiresAt != nil {
                    Text(item.remainingText)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(item.tone == .ok ? theme.fg : lifetimeColor)
                        .monospacedDigit()
                }
            }

            if let issuedAt = item.credit.issuedAt,
               let expiresAt = item.credit.expiresAt,
               expiresAt > issuedAt {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(theme.surface2)
                        Capsule()
                            .fill(lifetimeColor)
                            .frame(width: proxy.size.width * CGFloat(item.progress))
                    }
                }
                .frame(height: 4)
            }
        }
        .padding(.top, 4)
    }
}

// MARK: - .unk 底注 与 .foot 操作行

private struct UnknownNote: View {
    let summary: DailyModelSummary
    @Environment(\.mbTheme) private var theme

    var body: some View {
        let details = summary.rows
            .filter { $0.usage.unknownCost > 0 }
            .map { "\($0.id) · \($0.usage.unknownCost) 条" }
            .joined(separator: "\n")
        HStack(spacing: 5) {
            Circle().fill(theme.warn).frame(width: 6, height: 6).accessibilityHidden(true)
            Text("\(summary.total.unknownCost) 条用量未能计价，未计入花费")
                .font(.system(size: 10.5))
                .foregroundStyle(theme.muted)
        }
        .background(PopoverToolTip(text: details))
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(verbatim: details))
        .padding(EdgeInsets(top: 0, leading: 16, bottom: 10, trailing: 16))
    }
}

private struct FootBar: View {
    @ObservedObject var store: ProviderStore
    let onOpenMainInterface: () -> Void
    let onOpenSettings: () -> Void
    @Environment(\.mbTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            // 主操作：accent 实底
            Button(action: onOpenMainInterface) {
                Text("打开应用")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(theme.onAccent)
                    .padding(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.accent))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)

            // 标签式开关：同高描边钮，暂停中转 warn
            Button {
                store.isScanPaused.toggle()
            } label: {
                Text(store.isScanPaused ? "恢复扫描" : "暂停扫描")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(store.isScanPaused ? theme.warn : theme.fg2)
                    .padding(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(store.isScanPaused ? theme.tintWarn : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(store.isScanPaused ? theme.warn.opacity(0.55) : theme.border, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)

            Spacer()

            FootButton(action: onOpenSettings) {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("打开设置")
            .help("打开设置")
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 12, trailing: 14))
    }
}

private struct FootButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder var label: Label
    @Environment(\.mbTheme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label
                .font(.system(size: 12))
                .foregroundStyle(theme.fg2)
                .padding(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10))
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? theme.surface2 : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
    }
}

private struct NotificationPermissionControl: View {
    @ObservedObject var store: ProviderStore

    var body: some View {
        switch store.notificationAuthorizationState {
        case .notDetermined:
            Button {
                Task {
                    await store.requestNotificationAuthorization()
                }
            } label: {
                Label("开启通知", systemImage: "bell")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .focusable(false)
        case .denied:
            Button {
                store.openNotificationSettings()
            } label: {
                Image(systemName: "bell.slash.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
        .focusable(false)
        case .authorized, .unknown:
            EmptyView()
        }
    }
}

private extension View {
    /// 高度实测。必须用 onGeometryChange——曾用 GeometryReader+PreferenceKey，
    /// 在 NSPopover 的 NSHostingController 里 preference 只在首轮探测布局投递一次
    /// （content 恒 0、header 报 0 后再无更新），实测链路整体失效，面板高度
    /// 常年跑在打开瞬间的估值上（诊断日志 2026-07-15，用户观感「高度乱跳」）。
    func readHeight(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            onChange(height)
        }
    }
}
