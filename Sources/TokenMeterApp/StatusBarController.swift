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
        statusItem.button?.title = title
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        button.title = "TokenMeter"
        button.target = self
        button.action = #selector(handleStatusItemClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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
            popover.performClose(nil)
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
        Publishers.CombineLatest(store.$providerSnapshots, store.$settingsSnapshot)
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshots, settingsSnapshot in
                guard let self else {
                    return
                }

                let primaryProviderId = settingsSnapshot?.menuBarPrimaryProviderId
                    ?? self.store.config.menuBar.primaryProviderId
                let title = UsageFormatter.menuBarTitle(
                    for: snapshots,
                    primaryProviderId: primaryProviderId
                )
                self.updateTitle(title)
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
            popover.performClose(nil)
        } else {
            updatePopoverContent(relativeTo: button)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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
                    self?.popover.performClose(nil)
                    self?.mainInterfaceLauncher.openMainInterface()
                },
                onThemeChange: { [weak self] in
                    self?.applyPopoverAppearance()
                }
            )
        )
        // SwiftUI 理想尺寸 → preferredContentSize → NSPopover 原生跟随。
        // 系统在同一帧里协调窗口与内容，杜绝「内容先变、窗口后跟」的裁切帧。
        hosting.sizingOptions = [.preferredContentSize]
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
        let maxHeight = min(760, max(360, screenHeight - 96))
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

    private func estimatedCollapsedContentHeight() -> CGFloat {
        let snapshots = store.providerSnapshots
        guard !snapshots.isEmpty else {
            return 220
        }

        let headerAndDivider: CGFloat = 62
        let listPadding: CGFloat = 24
        let cardSpacing = CGFloat(max(0, snapshots.count - 1)) * 10
        let cardHeights = snapshots.reduce(CGFloat(0)) { total, snapshot in
            total + estimatedCardHeight(snapshot)
        }

        return headerAndDivider + listPadding + cardSpacing + cardHeights
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
