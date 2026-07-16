import AppKit
import Combine
import SwiftUI
import TokenMeterCore

@MainActor
protocol MainInterfaceLaunching: AnyObject {
    func openMainInterface()
}

struct MainInterfaceLaunchCommand: Equatable {
    let executablePath: String
    let arguments: [String]
    let environment: [String: String]
}

@MainActor
final class ElectronMainInterfaceLauncher: MainInterfaceLaunching {
    private var process: Process?

    func openMainInterface() {
        guard let electronDirectory = Self.electronDirectory() else {
            NSSound.beep()
            return
        }

        let command = Self.launchCommand(electronDirectory: electronDirectory)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executablePath)
        process.arguments = command.arguments
        var environment = ProcessInfo.processInfo.environment
        command.environment.forEach { key, value in
            environment[key] = value
        }
        process.environment = environment
        process.standardOutput = nil
        process.standardError = nil

        do {
            try process.run()
            self.process = process
        } catch {
            NSSound.beep()
        }
    }

    static func launchCommand(electronDirectory: URL) -> MainInterfaceLaunchCommand {
        let path = [
            URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())
                .appendingPathComponent(".volta/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ].joined(separator: ":")

        return MainInterfaceLaunchCommand(
            executablePath: "/usr/bin/env",
            arguments: [
                "node",
                electronDirectory.appendingPathComponent("node_modules/electron/cli.js").path,
                electronDirectory.path
            ],
            environment: ["PATH": path]
        )
    }

    static func electronDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath,
        resourceURL: URL? = Bundle.main.resourceURL
    ) -> URL? {
        if let configuredPath = environment["TOKENMETER_ELECTRON_DIR"], !configuredPath.isEmpty {
            let configuredURL = URL(fileURLWithPath: configuredPath, isDirectory: true)
            if FileManager.default.fileExists(atPath: configuredURL.appendingPathComponent("package.json").path) {
                return configuredURL
            }
        }

        if let bundledElectronURL = resourceURL?.appendingPathComponent("Electron", isDirectory: true),
           FileManager.default.fileExists(atPath: bundledElectronURL.appendingPathComponent("package.json").path) {
            return bundledElectronURL
        }

        let workingDirectoryURL = URL(fileURLWithPath: currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Electron", isDirectory: true)
        if FileManager.default.fileExists(atPath: workingDirectoryURL.appendingPathComponent("package.json").path) {
            return workingDirectoryURL
        }

        return nil
    }
}

/// 菜单栏标题的 SwiftUI 绘制层：token 数变化时逐位滚动（numericText）。
struct StatusBarTitleView: View {
    let title: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(title)
            .font(Font(StatusBarController.statusTitleFont as CTFont))
            .contentTransition(reduceMotion ? .identity : .numericText())
            .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: title)
    }
}

// 菜单栏额度 cell 的样式族视图（S0 同心双环及其余 15 种）统一在
// MenuBarStyleViews.swift：投影（MenuBarProjection）驱动，样式规则见 spec §3。

/// 品牌折线小标（弹窗 BrandMark 的菜单栏版）：today 数据未加载时替代
/// 「TokenMeter」文字（用户裁定：图标比应用名文案好）。随菜单栏黑白取 primary。
/// size 可调：哨兵/点阵/堆叠条样式用 13pt 作名称前缀位。
struct MenuBarBrandMark: View {
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Color.primary.opacity(0.9), lineWidth: 1.5)
                .frame(width: 15, height: 15)
            Path { p in
                p.move(to: CGPoint(x: 3.2, y: 9.1))
                p.addLine(to: CGPoint(x: 5.4, y: 5.5))
                p.addLine(to: CGPoint(x: 7.3, y: 8.0))
                p.addLine(to: CGPoint(x: 9.1, y: 4.1))
                p.addLine(to: CGPoint(x: 10.5, y: 9.1))
            }
            .stroke(Color.primary.opacity(0.9), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            .frame(width: 13.5, height: 12.5)
        }
        .frame(width: 16, height: 16)
        .scaleEffect(size / 16)
        .frame(width: size, height: size)
    }
}

/// 按样式分发 cell 渲染：基础族与混合系逐家一 cell；聚合/数字支全家一 cell。
struct MenuBarStyleRouterView: View {
    let projection: MenuBarQuotaModel.MenuBarProjection

    var body: some View {
        // 空 cell 组不渲染任何样式骨架（聚合样式的 logo 前缀也不出）——
        // 全空的品牌小标兜底由 StatusBarContentView 统一负责，避免双 logo。
        if projection.cells.isEmpty {
            EmptyView()
        } else {
            styled
        }
    }

    @ViewBuilder
    private var styled: some View {
        switch projection.style {
        case .rings, .vbars, .hbar, .digits, .dots, .caps, .ticks, .ring1:
            HStack(spacing: 9) {
                ForEach(projection.cells, id: \.providerId) { cell in
                    BasicStyleCellView(cell: cell, projection: projection)
                }
            }
        case .grid:
            GridAggregateView(projection: projection)
        case .strip:
            StripAggregateView(projection: projection)
        case .monogram:
            MonogramAggregateView(projection: projection)
        case .sentinel:
            SentinelView(projection: projection)
        case .tagnum:
            TagnumAggregateView(projection: projection)
        case .deck2:
            Deck2AggregateView(projection: projection)
        case .ringdeck, .barsdeck:
            HStack(spacing: 9) {
                ForEach(projection.cells, id: \.providerId) { cell in
                    HybridCellView(cell: cell, projection: projection)
                }
            }
        }
    }
}

/// 菜单栏整体内容：样式化 cell 组 + 组件级今日尾巴（token/花费）。
/// 全空（无 cell 且尾巴隐藏）时退品牌小标。宽度由 applyStatusContent 显式设定。
struct StatusBarContentView: View {
    let projection: MenuBarQuotaModel.MenuBarProjection
    let title: String

    private var tailText: String? {
        if case let .text(text) = projection.tail { return text }
        return nil
    }

    var body: some View {
        HStack(spacing: 9) {
            MenuBarStyleRouterView(projection: projection)
            if let tailText {
                StatusBarTitleView(title: tailText)
                    .opacity(0.75)
            } else if projection.cells.isEmpty {
                MenuBarBrandMark()
            }
        }
    }
}

/// 只负责显示、不拦截鼠标——点击（开弹窗/右键菜单）仍由 NSStatusBarButton 处理。
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

enum StatusItemClickAction: Equatable {
    case togglePopover
    case showContextMenu
}

// `NSPopover` 是 final class，没法子类化出一个测试替身；而它的「show」在
// XCTest 的无头环境里（`NSApp.isRunning == false`）会静默不生效，isShown
// 永远是 false，导致没法验证「失活即关闭」这条逻辑。抽出这个协议，测试里
// 注入一个记录调用的替身，绕开对真实 AppKit 渲染管线的依赖。
@MainActor
protocol PopoverPresenting: AnyObject {
    var behavior: NSPopover.Behavior { get set }
    var animates: Bool { get set }
    var isShown: Bool { get }
    var contentSize: NSSize { get set }
    var contentViewController: NSViewController? { get set }
    var appearance: NSAppearance? { get set }
    func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge)
    func performClose(_ sender: Any?)
}

extension NSPopover: PopoverPresenting {}

@MainActor
final class StatusBarController: NSObject {
    private let store: ProviderStore
    private let statusItem: NSStatusItem
    private let popover: PopoverPresenting
    private let mainInterfaceLauncher: MainInterfaceLaunching
    private let quitApplication: () -> Void
    private var cancellables: Set<AnyCancellable> = []
    private var titleHosting: NSHostingView<StatusBarContentView>?
    private var globalClickMonitor: Any?
    private var currentTitle = "TokenMeter"
    private var projection = MenuBarQuotaModel.MenuBarProjection(
        style: .rings, showName: true, showGlyph: true, showNumber: true,
        windowOrder: .longFirst, cells: [], tail: .hidden
    )

    /// 测试用：当前投影镜像。
    var projectionForTesting: MenuBarQuotaModel.MenuBarProjection { projection }

    /// 菜单栏标题字体：透明的 button.title（管宽度）与 SwiftUI 层（管显示）
    /// 必须同字体两层才对得上；等宽数字避免滚动时横向抖动。
    static let statusTitleFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    init(
        store: ProviderStore,
        mainInterfaceLauncher: MainInterfaceLaunching? = nil,
        quitApplication: (() -> Void)? = nil,
        popover: PopoverPresenting? = nil
    ) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = popover ?? NSPopover()
        self.mainInterfaceLauncher = mainInterfaceLauncher ?? ElectronMainInterfaceLauncher()
        self.quitApplication = quitApplication ?? { NSApp.terminate(nil) }

        super.init()

        configureStatusItem()
        configurePopover()
        bindStore()
    }

    func updateTitle(_ title: String) {
        guard let button = statusItem.button else { return }
        // 透明 title 只剩 accessibility/测试镜像的职责：加入额度图形后宽度
        // 不能再靠文字测量，改由 applyStatusContent 按 fittingSize 显式设定。
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: Self.statusTitleFont, .foregroundColor: NSColor.clear]
        )
        currentTitle = title
        applyStatusContent()
    }

    /// 菜单栏内容（额度 cell 组 + token 数字）统一刷新出口：
    /// 更新 SwiftUI 层并按理想尺寸显式设定 item 宽度。
    private func applyStatusContent() {
        guard let hosting = titleHosting else { return }
        hosting.rootView = StatusBarContentView(projection: projection, title: currentTitle)
        // rootView 更新后 intrinsic 需要显式作废再取，否则可能拿到旧值/偏小值，
        // length 偏小会把内容压出省略号（实测）。视图层全 fixedSize 兜底不塌缩。
        hosting.invalidateIntrinsicContentSize()
        hosting.layoutSubtreeIfNeeded()
        let width = max(hosting.intrinsicContentSize.width, hosting.fittingSize.width)
        statusItem.length = ceil(width) + 8
    }

    /// 测试用：宽度层（透明 title）当前的字符串。
    var titleForTesting: String {
        statusItem.button?.attributedTitle.string ?? ""
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        button.font = Self.statusTitleFont
        installTitleHosting(on: button)
        // 空 title = 显示品牌图标（今日数据尚未加载;用户裁定图标胜于应用名文案）。
        updateTitle("")
        button.target = self
        button.action = #selector(handleStatusItemClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func installTitleHosting(on button: NSStatusBarButton) {
        let hosting = PassthroughHostingView(rootView: StatusBarContentView(projection: projection, title: ""))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            hosting.centerYAnchor.constraint(equalTo: button.centerYAnchor)
        ])
        titleHosting = hosting
    }

    private func configurePopover() {
        popover.behavior = .transient
        updatePopoverContent(relativeTo: statusItem.button)

        // `.transient` 理论上会在应用失去激活状态时自动关闭，但 TokenMeter 是
        // LSUIElement（无 Dock 图标的常驻程序）——这类「accessory」应用与常规
        // 应用在「激活/非激活」状态的语义上历来不完全一致，实测点开这个弹窗、
        // 再点进另一个 App（比如仪表盘的 Electron 窗口），弹窗不会自动收起。
        // 显式监听失活通知、手动关掉，不依赖 .transient 自己判断是否该收起。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(closePopoverOnResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    @objc private func closePopoverOnResignActive() {
        if popover.isShown {
            closePopover()
        }
    }

    /// 关闭的唯一出口：弹窗与全局点击监听一起收。
    private func closePopover() {
        popover.performClose(nil)
        removeGlobalClickMonitor()
    }

    /// 失活通知盖不住所有场景：LSUIElement 应用点开弹窗时 app 可能压根没被激活，
    /// 之后点到哪里都等不来 didResignActive（「失活即收起」于是时灵时不灵）。
    /// 全局监听 app 之外的鼠标按下作兜底——只读事件、无需辅助功能权限，
    /// 弹窗内部/状态栏按钮的点击属于本 app，不会走到 global monitor。
    private func installGlobalClickMonitor() {
        guard globalClickMonitor == nil else { return }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.popover.isShown else { return }
                self.closePopover()
            }
        }
    }

    private func removeGlobalClickMonitor() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
    }

    /// 测试专用：popover 是 private，用这两个方法间接触发/查看它的状态。
    func showPopoverForTesting() {
        togglePopover()
    }

    var isPopoverShownForTesting: Bool {
        popover.isShown
    }

    private func bindStore() {
        // 三源合并重投影：providerSnapshots（额度刷新）/ settingsSnapshot
        // （启停/别名/菜单栏外观）/ todaySummary（今日尾巴）任一变化即重建，
        // 与弹窗的展示口径同步。尾巴文本同步进透明 title（宽度/a11y 镜像层）。
        store.$providerSnapshots
            .combineLatest(store.$settingsSnapshot, store.$todaySummary)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
                guard let self else { return }
                self.projection = MenuBarQuotaModel.projection(
                    snapshots: self.store.displayProviderSnapshots,
                    settings: self.store.settingsSnapshot,
                    todaySummary: self.store.todaySummary
                )
                if case let .text(text) = self.projection.tail {
                    self.updateTitle(text)
                } else {
                    self.updateTitle("")
                }
            }
            .store(in: &cancellables)
    }

    func statusItemClickAction(for eventType: NSEvent.EventType?) -> StatusItemClickAction {
        eventType == .rightMouseUp ? .showContextMenu : .togglePopover
    }

    func makeContextMenuForTesting() -> NSMenu {
        makeContextMenu()
    }

    @objc private func handleStatusItemClick() {
        switch statusItemClickAction(for: NSApp.currentEvent?.type) {
        case .togglePopover:
            togglePopover()
        case .showContextMenu:
            showContextMenu()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else {
            return
        }

        if popover.isShown {
            closePopover()
        } else {
            updatePopoverContent(relativeTo: button)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // 主动激活一次，让「失活即收起」的主路径可靠（见 installGlobalClickMonitor 注）。
            NSApp.activate(ignoringOtherApps: true)
            installGlobalClickMonitor()
        }
    }

    private func showContextMenu() {
        guard let button = statusItem.button else {
            return
        }

        let menu = makeContextMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()

        let openItem = NSMenuItem(
            title: "打开主界面",
            action: #selector(openMainInterface),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出 TokenMeter",
            action: #selector(quitTokenMeter),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func openMainInterface() {
        mainInterfaceLauncher.openMainInterface()
    }

    @objc private func quitTokenMeter() {
        quitApplication()
    }

    private func updatePopoverContent(relativeTo button: NSStatusBarButton?) {
        let size = preferredPopoverSize(relativeTo: button)
        popover.contentSize = NSSize(width: size.width, height: size.initialHeight)
        configurePopoverChrome()
        let hosting = NSHostingController(
            rootView: PopoverView(
                store: store,
                initialPanelHeight: size.initialHeight,
                maxPanelHeight: size.maxHeight,
                onPreferredHeightChange: { [weak self] height in
                    self?.updatePopoverHeight(height)
                },
                onOpenMainInterface: { [weak self] in
                    self?.closePopover()
                    self?.mainInterfaceLauncher.openMainInterface()
                },
                onThemeChange: { [weak self] in
                    self?.applyPopoverAppearance()
                }
            )
        )
        // 不用 sizingOptions=[.preferredContentSize]：实测它让 readHeight 的
        // preference 只在首轮探测布局投递一次（content 恒 0、header 报 0），
        // 高度永远停在打开瞬间的估值上、随数据状态在 ~607/~886 间跳。
        // 高度统一走手动通道：readHeight 实测 → onPreferredHeightChange → contentSize。
        popover.contentViewController = hosting
    }

    /// NSPopover 的系统 chrome（外框材质）跟随弹窗主题——否则深色面板外面
    /// 套一圈系统浅色边，颜色对不上。
    private func configurePopoverChrome() {
        popover.animates = false
        applyPopoverAppearance()
    }

    private func applyPopoverAppearance() {
        let isLight = UserDefaults.standard.string(forKey: "menubarTheme") == "light"
        popover.appearance = NSAppearance(named: isLight ? .aqua : .darkAqua)
    }

    private func preferredPopoverSize(relativeTo button: NSStatusBarButton?) -> (width: CGFloat, initialHeight: CGFloat, maxHeight: CGFloat) {
        let screenHeight = button?.window?.screen?.visibleFrame.height
            ?? NSScreen.main?.visibleFrame.height
            ?? 820
        // 上限只受屏幕可用高度约束（曾有 760 硬顶——默认内容变多后被顶住，
        // 出了滚动条；用户裁定：默认内容完整展示，展开时继续长高到屏幕边界）。
        let maxHeight = max(360, screenHeight - 96)
        let estimatedHeight = estimatedCollapsedContentHeight()
        return (width: 378, initialHeight: min(maxHeight, estimatedHeight), maxHeight: maxHeight)
    }

    private func updatePopoverHeight(_ height: CGFloat) {
        let currentSize = popover.contentSize
        guard abs(currentSize.height - height) > 0.5 else {
            return
        }

        popover.contentSize = NSSize(width: currentSize.width, height: height)
    }

    /// 打开瞬间的初始高度估值——只求接近，弹窗渲染后 readHeight 的实测值
    /// 立刻修正（PopoverView.panelHeight 跟随内容）。估得越准，首帧跳变越小。
    private func estimatedCollapsedContentHeight() -> CGFloat {
        let chrome: CGFloat = 192 + 50   // 吸顶头部（PanelHead+Today+SourceLine）+ 底栏
        var height = chrome + 18         // 滚动区上下留白

        // 今日 Agent / 模型两个列表块：SectionBlock 铺垫约 45，一行约 27。
        let summary = store.todaySummary
        if !summary.perProvider.isEmpty {
            height += 45 + CGFloat(summary.perProvider.count) * 27
        }
        if !summary.perModel.isEmpty {
            height += 45 + CGFloat(min(5, summary.perModel.count)) * 27
            if summary.perModel.count > 5 {
                height += 26   // 「展开全部」按钮行
            }
        }

        let snapshots = store.displayProviderSnapshots
        if !snapshots.isEmpty {
            // 订阅额度手风琴：默认第一家展开、其余只剩 summaryRow（约 40）。
            height += 45
            height += estimatedCardHeight(snapshots[0])
            height += CGFloat(max(0, snapshots.count - 1)) * 48
        }
        return height
    }

    private func estimatedCardHeight(_ snapshot: ProviderUsageSnapshot) -> CGFloat {
        var height: CGFloat = 24 + 26

        if snapshot.groups.isEmpty {
            height += 12 + 22
        } else {
            height += 12
            height += estimatedGroupHeight(
                snapshot.groups[0],
                providerTitle: snapshot.displayName,
                hidesSingleGroupTitle: snapshot.groups.count == 1
            )

            let secondaryGroups = Array(snapshot.groups.dropFirst())
            if !secondaryGroups.isEmpty {
                height += 10 + 16
                height += secondaryGroups.reduce(CGFloat(0)) { total, group in
                    total + estimatedGroupHeight(group, providerTitle: snapshot.displayName, hidesSingleGroupTitle: false)
                }
                height += CGFloat(max(0, secondaryGroups.count - 1)) * 9
            }
        }

        if snapshot.resetCredits != nil {
            height += 12 + 22
        }

        return height
    }

    private func estimatedGroupHeight(
        _ group: UsageGroup,
        providerTitle: String,
        hidesSingleGroupTitle: Bool
    ) -> CGFloat {
        var height: CGFloat = 0
        if !hidesSingleGroupTitle && group.title != providerTitle {
            height += 20
        }

        let itemCount = group.items.count
        if itemCount > 0 {
            height += CGFloat(itemCount) * 32
            height += CGFloat(max(0, itemCount - 1)) * 6
        }
        return height
    }
}
