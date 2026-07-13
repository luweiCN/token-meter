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

    /// agent 系列色 s1-s4（与主窗口图例一致）。名单外的 provider 用 muted。
    func seriesColor(_ providerId: String) -> Color {
        switch providerId {
        case "claude-code": return accent
        case "codex": return self == .light ? Color(hex: 0x7A4FE0) : Color(hex: 0xA277FF)
        case "omp": return ok
        case "opencode": return warn
        default: return muted
        }
    }
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

    final class TintView: NSView {
        var color: NSColor = .clear {
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
            frameView.layer?.cornerRadius = 11
        }
    }

    func makeNSView(context: Context) -> TintView {
        let view = TintView()
        view.color = color
        return view
    }

    func updateNSView(_ nsView: TintView, context: Context) {
        nsView.color = color
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
        default: return providerId
        }
    }
}

enum MenuBarNumberFormat {
    static func tokens(_ value: Int64) -> String {
        let v = Double(value)
        if v >= 1_000_000_000 { return String(format: "%.1fB", v / 1_000_000_000) }
        if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%.1fK", v / 1_000) }
        return String(Int(v))
    }

    static func usd(_ micros: Int64) -> String {
        String(format: "$%.2f", Double(micros) / 1_000_000)
    }
}

// MARK: - 弹窗主体（.panel：head / today / srcline / 按服务商 / 订阅额度 / unk / foot）

struct PopoverView: View {
    @ObservedObject var store: ProviderStore
    @State private var measuredContentHeight: CGFloat = 0
    @AppStorage("menubarTheme") private var themeName = "dark"
    let initialPanelHeight: CGFloat
    let maxPanelHeight: CGFloat
    let onPreferredHeightChange: (CGFloat) -> Void
    var onOpenMainInterface: () -> Void = {}
    var onThemeChange: () -> Void = {}

    private var theme: MBTheme { themeName == "light" ? .light : .dark }

    /// 吸顶区与底栏的高度是【实测】的（readHeight），不是估计值——写死的估计值
    /// 偏小时，VStack 总高超出面板，底部按钮的 padding 会被整个裁掉且毫无征兆。
    @State private var headerHeight: CGFloat = 192
    @State private var footHeight: CGFloat = 50

    private var chromeMeasured: CGFloat { headerHeight + footHeight }

    /// 弹窗打开期间面板高度【锁定】：首次内容测量到位后定格，之后展开/收起
    /// 一律由滚动区内部消化——没有 resize 就没有任何可跳动的东西（原生菜单栏
    /// 面板同款行为）。每次打开都重建视图，锁定值随之按当次内容重算。
    @State private var lockedHeight: CGFloat?

    private var panelHeight: CGFloat {
        if let lockedHeight { return lockedHeight }
        guard measuredContentHeight > 20 else {
            return min(maxPanelHeight, initialPanelHeight)
        }
        // 自然高度再拔 10%（用户裁定）：全折叠的矮态不至于太局促；
        // 展开态本就会被 maxPanelHeight 钳住，不受影响。
        return min(maxPanelHeight, (chromeMeasured + measuredContentHeight) * 1.1)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 吸顶头部：毛玻璃 + surface 叠加，滚动内容从下面穿过时层次分明。
            VStack(spacing: 0) {
                PanelHead(store: store, themeName: $themeName)
                TodayBlock(summary: store.todaySummary)
                SourceLine(text: sourceLineText)
                PanelDivider()
            }
            .background(
                ZStack {
                    HeaderBlur()
                    theme.surface.opacity(0.72)
                }
            )
            .readHeight { headerHeight = $0 }
            .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
            .zIndex(1)

            // 纯 SwiftUI 滚动区：AppKit 滚动容器与 SwiftUI 内容之间的高度信号
            // 无论怎么接都差一拍（诊断日志：展开居中跳 ±60.5、收起文档卡 732、
            // offset 被推到 236 再回弹），树内没有 AppKit 边界后这一类问题整体消失。
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 6)

                    if !store.todaySummary.perProvider.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(store.todaySummary.perProvider, id: \.providerId) { row in
                                ProviderRow(row: row)
                            }
                        }
                        .padding(EdgeInsets(top: 6, leading: 16, bottom: 8, trailing: 16))
                        PanelDivider()
                    }

                    if !store.providerSnapshots.isEmpty {
                        SectionBlock(title: "订阅额度") {
                            VStack(spacing: 8) {
                                ForEach(store.providerSnapshots, id: \.providerId) { snapshot in
                                    QuotaGroupView(snapshot: snapshot) {
                                        Task { await store.refresh() }
                                    }
                                }
                            }
                        }
                    }

                    if store.todaySummary.unknownEvents > 0 {
                        UnknownNote(count: store.todaySummary.unknownEvents)
                    }

                    Color.clear.frame(height: 12)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.bg)
                .background(ThinScrollerStyler())
                .readHeight { height in
                    if abs(measuredContentHeight - height) > 0.5 {
                        measuredContentHeight = height
                    }
                    if lockedHeight == nil, height > 20 {
                        // 延一拍锁定：等 header/foot 的首轮测量一并回填后再定格。
                        DispatchQueue.main.async {
                            if lockedHeight == nil {
                                lockedHeight = min(maxPanelHeight, (chromeMeasured + measuredContentHeight) * 1.1)
                                onPreferredHeightChange(lockedHeight ?? panelHeight)
                            }
                        }
                    }
                }
            }
            .background(theme.bg)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 0) {
                PanelDivider()
                FootBar(
                    isScanPaused: $store.isScanPaused,
                    onOpenMainInterface: onOpenMainInterface
                )
            }
            .background(theme.surface)
            .readHeight { footHeight = $0 }
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
            store.reloadTodaySummary()
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

private struct TodayBlock: View {
    let summary: MenuBarTodaySummary
    @Environment(\.mbTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(MenuBarNumberFormat.tokens(summary.tokens))
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(theme.fg)
                    .monospacedDigit()
                Text("tokens")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.fg2)
            }

            (Text("花费 ")
                + Text(MenuBarNumberFormat.usd(summary.costUsdMicros)).foregroundColor(theme.fg2)
                + Text(" · ")
                + Text("\(summary.sessions)").foregroundColor(theme.fg2)
                + Text(" 个会话"))
                .font(.system(size: 11.5))
                .foregroundStyle(theme.muted)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 0, leading: 16, bottom: 12, trailing: 16))
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

    /// 悬停展开是系统行为：鼠标移到滚动条上，AppKit 把 scroller 加宽（约 +6）
    /// 并重绘——用自身宽度判定展开态，随之加宽 knob、加深颜色、显出轨道。
    private var isExpanded: Bool { bounds.width >= 14 }

    /// knob 与轨道一律【右缘锚定】：展开时 scroller 区域向左加宽，若按中点
    /// 定位，knob 会随中点左移——右边距恒定才是「原地变宽」的观感。
    private let trailingInset: CGFloat = 3

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        guard isExpanded else { return }   // 常态无槽；悬停展开时垫一条淡轨道作高亮
        NSColor.tertiaryLabelColor.withAlphaComponent(0.12).setFill()
        let width: CGFloat = 9
        let track = NSRect(
            x: bounds.width - trailingInset - width,
            y: slotRect.minY + 2,
            width: width,
            height: slotRect.height - 4
        )
        NSBezierPath(roundedRect: track, xRadius: width / 2, yRadius: width / 2).fill()
    }

    override func drawKnob() {
        let knob = rect(for: .knob)
        let width: CGFloat = isExpanded ? 7 : 4
        let inset = NSRect(
            x: bounds.width - trailingInset - width - (isExpanded ? 1 : 0),
            y: knob.origin.y + 2,
            width: width,
            height: max(24, knob.height - 4)
        )
        NSColor.tertiaryLabelColor.withAlphaComponent(isExpanded ? 0.72 : 0.5).setFill()
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

/// .sec：区块容器 + uppercase 小标题。
private struct SectionBlock<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @Environment(\.mbTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(theme.muted)
                .kerning(0.5)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 10, leading: 16, bottom: 12, trailing: 16))
    }
}

// MARK: - .prow：今日按服务商行

private struct ProviderRow: View {
    let row: MenuBarTodaySummary.ProviderToday
    @Environment(\.mbTheme) private var theme

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 2)
                .fill(theme.seriesColor(row.providerId))
                .frame(width: 8, height: 8)

            Text(MenuBarProviderName.label(row.providerId))
                .font(.system(size: 12.5))
                .foregroundStyle(theme.fg)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(MenuBarNumberFormat.tokens(row.tokens))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.fg)
                .monospacedDigit()

            Text("\(MenuBarNumberFormat.usd(row.costUsdMicros)) · \(row.sessions) 会话")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.muted)
                .monospacedDigit()
                .fixedSize()
        }
        .padding(.vertical, 5)
    }
}

// MARK: - 订阅额度：.qgroup 折叠组

/// snapshot → 稿上元素的显示模型。
struct QuotaDisplayModel {
    struct Ring {
        let label: String
        let percent: Double
        let resetText: String?
        let isWarn: Bool
    }

    struct Bar {
        let label: String
        let percent: Double?
        let note: String?
        let isWarn: Bool
    }

    let badge: String
    let name: String
    let isWarn: Bool
    let staleMinutes: Int?
    let summaryText: String
    let alertMessage: String?
    let alertTime: String?
    let rings: [Ring]
    let bars: [Bar]
    let resetCredits: ResetCreditSummary?

    init(snapshot: ProviderUsageSnapshot, now: Date = Date()) {
        name = snapshot.displayName
        badge = Self.badgeText(snapshot.displayName)

        let metrics = snapshot.groups.flatMap(\.items)
        let warnStatuses: [UsageStatus] = [.warning, .error]
        isWarn = snapshot.status == .warning || snapshot.status == .error
            || metrics.contains { warnStatuses.contains($0.status) || ($0.usedPercent ?? 0) >= 99.5 }

        let staleSeconds = now.timeIntervalSince(snapshot.fetchedAt)
        staleMinutes = staleSeconds >= 600 ? Int(staleSeconds / 60) : nil

        // 环：前两个带百分比的指标（各 provider 的 5h/7d 主窗口）；其余进水平条。
        let percentMetrics = metrics.filter { $0.usedPercent != nil }
        let ringMetrics = Array(percentMetrics.prefix(2))
        rings = ringMetrics.map { m in
            Ring(
                label: Self.shortWindowLabel(m),
                percent: min(100, m.usedPercent ?? 0),
                resetText: m.resetText,
                isWarn: warnStatuses.contains(m.status) || (m.usedPercent ?? 0) >= 99.5
            )
        }
        bars = percentMetrics.dropFirst(2).map { m in
            Bar(
                label: m.label,
                percent: min(100, m.usedPercent ?? 0),
                note: m.detail ?? m.resetText,
                isWarn: warnStatuses.contains(m.status) || (m.usedPercent ?? 0) >= 99.5
            )
        }

        summaryText = ringMetrics
            .map { "\(Self.shortWindowLabel($0)) \(Int((min(100, $0.usedPercent ?? 0)).rounded()))%" }
            .joined(separator: " · ")

        if isWarn, let message = snapshot.message, !message.isEmpty {
            alertMessage = message
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            alertTime = formatter.string(from: snapshot.fetchedAt)
        } else {
            alertMessage = nil
            alertTime = nil
        }

        resetCredits = snapshot.resetCredits
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
    let onRetry: () -> Void
    @Environment(\.mbTheme) private var theme
    @State private var expanded: Bool
    private let model: QuotaDisplayModel

    init(snapshot: ProviderUsageSnapshot, onRetry: @escaping () -> Void) {
        self.snapshot = snapshot
        self.onRetry = onRetry
        let model = QuotaDisplayModel(snapshot: snapshot)
        self.model = model
        // 稿：有警示的组默认展开，其余折叠。
        _expanded = State(initialValue: model.isWarn)
    }

    var body: some View {
        VStack(spacing: 0) {
            summaryRow

            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    PanelDivider()

                    VStack(alignment: .leading, spacing: 8) {
                        if let minutes = model.staleMinutes {
                            StaleCard(minutes: minutes, onRetry: onRetry)
                        }

                        if let message = model.alertMessage {
                            AlertCard(message: message, time: model.alertTime)
                        }

                        if !model.rings.isEmpty {
                            HStack(spacing: 8) {
                                ForEach(model.rings.indices, id: \.self) { i in
                                    QRingCard(ring: model.rings[i])
                                }
                            }
                        }

                        ForEach(model.bars.indices, id: \.self) { i in
                            BarRowCard(bar: model.bars[i])
                        }

                        if let credits = model.resetCredits, !credits.credits.isEmpty {
                            ResetCardsGroup(summary: credits)
                        }
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

    private var summaryRow: some View {
        // 内容即时插拔，不做 SwiftUI 高度动画——面板高度的平滑过渡由 NSPopover 的
        // contentSize 原生动画负责，两边同时动画会互相打架（内容先压扁再弹开）。
        Button {
            expanded.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(model.badge)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.accent)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.surface2))

                Text(model.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.fg)
                    .lineLimit(1)

                if let minutes = model.staleMinutes {
                    Text("\(Self.staleBadgeText(minutes)) 未更新")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.danger)
                        .padding(EdgeInsets(top: 1, leading: 7, bottom: 1, trailing: 7))
                        .background(Capsule().fill(theme.tintDanger))
                }

                if model.isWarn {
                    WarnTriangle()
                        .frame(width: 14, height: 14)
                }

                Spacer(minLength: 8)

                Text(model.summaryText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.muted)
                    .monospacedDigit()
                    .lineLimit(1)
                    .opacity(expanded ? 0 : 1)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.muted)
                    .frame(width: 14, height: 14)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .animation(.easeOut(duration: 0.15), value: expanded)
            }
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    /// 红标里的紧凑时长（稿风格 m/h/d）：11,585m → 8d。
    static func staleBadgeText(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 24 * 60 { return "\(minutes / 60)h" }
        return "\(minutes / (24 * 60))d"
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

            VStack(alignment: .leading, spacing: 2) {
                Text("额度提醒")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.warn)
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.fg2)
                    .lineSpacing(2)
                    .lineLimit(2)
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
    let minutes: Int
    let onRetry: () -> Void
    @Environment(\.mbTheme) private var theme

    /// 「11,579 分钟前」没法读——超过一小时换算成时/天。
    private var ageText: String {
        if minutes < 60 { return "\(minutes) 分钟" }
        if minutes < 24 * 60 { return "\(minutes / 60) 小时" }
        return "\(minutes / (24 * 60)) 天"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.danger)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text("额度刷新失败")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.danger)
                Text("以下为 \(ageText)前的数据")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.fg2)
                    .lineSpacing(2)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            Button("重试", action: onRetry)
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
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.tintDanger))
    }
}

// MARK: - 环形主额度（.qring：44×44，r19 stroke4，-90° 起笔）

private struct QRingCard: View {
    let ring: QuotaDisplayModel.Ring
    @Environment(\.mbTheme) private var theme

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .stroke(theme.surface2, lineWidth: 4)
                Circle()
                    .trim(from: 0, to: CGFloat(min(100, max(0, ring.percent))) / 100)
                    .stroke(
                        ring.isWarn ? theme.warn : theme.accent,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                Text("\(Int(ring.percent.rounded()))%")
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(ring.isWarn ? theme.warn : theme.fg)
                    .monospacedDigit()
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 1) {
                Text(ring.label)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(theme.fg)
                if let reset = ring.resetText {
                    Text(reset)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border, lineWidth: 1))
        )
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 水平条子额度（.brow）

private struct BarRowCard: View {
    let bar: QuotaDisplayModel.Bar
    @Environment(\.mbTheme) private var theme

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
                        .foregroundStyle(bar.isWarn ? theme.warn : theme.fg)
                        .monospacedDigit()
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
                        .fill(bar.isWarn ? theme.warn : theme.accent)
                        .frame(width: proxy.size.width * CGFloat(min(100, max(0, bar.percent ?? 0))) / 100)
                }
            }
            .frame(height: 4)
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
        VStack(spacing: 0) {
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

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.muted)
                        .frame(width: 14, height: 14)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
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
                        ResetCardRow(index: i + 1, credit: summary.credits[i])
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
    let index: Int
    let credit: ResetCredit
    @Environment(\.mbTheme) private var theme

    /// 剩余寿命占比（发放→过期）。缺日期就不画进度。
    private var lifeInfo: (daysLeft: Int, fraction: Double)? {
        guard let expiresAt = credit.expiresAt else { return nil }
        let now = Date()
        let secondsLeft = expiresAt.timeIntervalSince(now)
        let daysLeft = max(0, Int(ceil(secondsLeft / 86_400)))
        guard let issuedAt = credit.issuedAt, expiresAt > issuedAt else {
            return (daysLeft, secondsLeft > 0 ? 1 : 0)
        }
        let total = expiresAt.timeIntervalSince(issuedAt)
        return (daysLeft, min(1, max(0, secondsLeft / total)))
    }

    private func shortDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }

    var body: some View {
        let info = lifeInfo
        let isWarn = (info?.daysLeft ?? .max) <= 3

        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("#\(index)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.muted)
                Text("\(shortDate(credit.issuedAt)) 发放 · \(shortDate(credit.expiresAt)) 过期")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.fg2)
                Spacer(minLength: 8)
                if let info {
                    Text("剩 \(info.daysLeft) 天")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(isWarn ? theme.warn : theme.fg)
                        .monospacedDigit()
                }
            }

            if let info {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(theme.surface2)
                        Capsule()
                            .fill(isWarn ? theme.warn : theme.accent)
                            .frame(width: proxy.size.width * CGFloat(info.fraction))
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
    let count: Int
    @Environment(\.mbTheme) private var theme

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(theme.warn).frame(width: 6, height: 6)
            Text("今日 \(count) 条事件价格未知，未计入金额")
                .font(.system(size: 10.5))
                .foregroundStyle(theme.muted)
        }
        .padding(EdgeInsets(top: 0, leading: 16, bottom: 10, trailing: 16))
    }
}

private struct FootBar: View {
    @Binding var isScanPaused: Bool
    let onOpenMainInterface: () -> Void
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
                isScanPaused.toggle()
            } label: {
                Text(isScanPaused ? "恢复扫描" : "暂停扫描")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(isScanPaused ? theme.warn : theme.fg2)
                    .padding(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isScanPaused ? theme.tintWarn : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(isScanPaused ? theme.warn.opacity(0.55) : theme.border, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        .focusable(false)

            Spacer()

            Button(action: onOpenMainInterface) {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.fg2)
                    .frame(width: 25, height: 25)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.surface2.opacity(0.6)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        .focusable(false)
            .help("设置")
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
    func readHeight(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: ViewHeightPreferenceKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(ViewHeightPreferenceKey.self, perform: onChange)
    }
}

private struct ViewHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

