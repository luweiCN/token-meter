import AppKit
import XCTest
@testable import TokenMeterApp
@testable import TokenMeterCore

@MainActor
final class StatusBarControllerTests: XCTestCase {
    func testRightClickUsesContextMenuWhileLeftClickKeepsPopoverToggle() throws {
        let controller = StatusBarController(
            store: makeStore(),
            mainInterfaceLauncher: RecordingMainInterfaceLauncher(),
            quitApplication: {}
        )

        XCTAssertEqual(controller.statusItemClickAction(for: .leftMouseUp), .togglePopover)
        XCTAssertEqual(controller.statusItemClickAction(for: .rightMouseUp), .showContextMenu)
        XCTAssertEqual(controller.statusItemClickAction(for: nil), .togglePopover)
    }

    /// status item 必须有固定 autosave 身份：无名时系统按 Item-0/Item-1 顺序分配，
    /// 双实例（dev 验证）会把身份挤漂移，Bartender 这类按身份记显示规则的工具
    /// 从此认不出它（2026-07-17 实锤：图标被收进隐藏区「消失」）。
    func testStatusItemHasStableAutosaveName() throws {
        let controller = StatusBarController(
            store: makeStore(),
            mainInterfaceLauncher: RecordingMainInterfaceLauncher(),
            quitApplication: {}
        )

        XCTAssertEqual(controller.autosaveNameForTesting, "TokenMeterQuota")
    }

    func testUpdateTitleDrivesTheWidthTitleLayer() throws {
        let controller = StatusBarController(
            store: makeStore(),
            mainInterfaceLauncher: RecordingMainInterfaceLauncher(),
            quitApplication: {}
        )

        controller.updateTitle("1.2M")

        // 宽度由透明 attributedTitle 驱动（可见绘制在 SwiftUI 层）：字符串必须同步。
        XCTAssertEqual(controller.titleForTesting, "1.2M")
    }

    /// 三源绑定（snapshots × settings × todaySummary）初始投影：controller 的
    /// 投影镜像必须与按 store 当前状态直接投影的结果一致（store 可能读到本机
    /// 磁盘缓存的快照，断言一致性而非空态）；无设置时样式回默认、尾巴隐藏。
    func testProjectionMirrorsStoreStateAfterInit() throws {
        let store = makeStore()
        let controller = StatusBarController(
            store: store,
            mainInterfaceLauncher: RecordingMainInterfaceLauncher(),
            quitApplication: {}
        )

        // bindStore 经 RunLoop.main 投递，转一拍让初始 sink 落地。
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let expected = MenuBarQuotaModel.projection(
            snapshots: store.displayProviderSnapshots,
            settings: store.settingsSnapshot,
            todaySummary: store.todaySummary
        )
        XCTAssertEqual(controller.projectionForTesting, expected)
        XCTAssertEqual(controller.projectionForTesting.style, .rings)
        XCTAssertEqual(controller.projectionForTesting.tail, .hidden)
        XCTAssertEqual(controller.titleForTesting, "")
    }

    func testContextMenuContainsOpenMainInterfaceAndQuit() throws {
        let controller = StatusBarController(
            store: makeStore(),
            mainInterfaceLauncher: RecordingMainInterfaceLauncher(),
            quitApplication: {}
        )

        let menu = controller.makeContextMenuForTesting()

        XCTAssertEqual(menu.items.map(\.title), ["打开主界面", "检查更新…", "", "退出 TokenMeter"])
        XCTAssertTrue(menu.items[2].isSeparatorItem)
    }

    func testOpenMainInterfaceMenuItemInvokesLauncher() throws {
        let launcher = RecordingMainInterfaceLauncher()
        let controller = StatusBarController(
            store: makeStore(),
            mainInterfaceLauncher: launcher,
            quitApplication: {}
        )
        let menu = controller.makeContextMenuForTesting()

        try performMenuItem(try XCTUnwrap(menu.items.first))

        XCTAssertEqual(launcher.openCount, 1)
    }

    func testQuitMenuItemInvokesQuitHandler() throws {
        var didQuit = false
        let controller = StatusBarController(
            store: makeStore(),
            mainInterfaceLauncher: RecordingMainInterfaceLauncher(),
            quitApplication: { didQuit = true }
        )
        let menu = controller.makeContextMenuForTesting()

        try performMenuItem(try XCTUnwrap(menu.items.last))

        XCTAssertTrue(didQuit)
    }

    func testPopoverClosesWhenAppResignsActive() throws {
        // TokenMeter 是 LSUIElement，实测 popover 的 .transient 不总能在切到
        // 另一个 App（比如仪表盘的 Electron 窗口）时自动收起。显式监听失活
        // 通知、手动关闭，不能只靠 .transient 自己判断。
        //
        // 用 SpyPopover 而不是真的 NSPopover：XCTest 是无头环境
        // （NSApp.isRunning == false），真实 NSPopover.show() 在这里静默不
        // 生效、isShown 永远是 false，没法验证「失活即关闭」这条逻辑本身。
        let spyPopover = SpyPopover()
        let controller = StatusBarController(
            store: makeStore(),
            mainInterfaceLauncher: RecordingMainInterfaceLauncher(),
            quitApplication: {},
            popover: spyPopover
        )

        controller.showPopoverForTesting()
        XCTAssertTrue(controller.isPopoverShownForTesting)

        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)

        XCTAssertFalse(controller.isPopoverShownForTesting)
        XCTAssertEqual(spyPopover.performCloseCallCount, 1)
    }

    func testElectronLauncherUsesPreparedElectronCliWithoutUserShell() throws {
        let electronDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: electronDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: electronDirectory) }
        try Data(#"{"scripts":{"build":"vite build","electron":"electron ."}}"#.utf8)
            .write(to: electronDirectory.appendingPathComponent("package.json"))

        let command = ElectronMainInterfaceLauncher.launchCommand(electronDirectory: electronDirectory)

        XCTAssertEqual(command.executablePath, "/usr/bin/env")
        XCTAssertEqual(
            command.arguments,
            [
                "node",
                electronDirectory.appendingPathComponent("node_modules/electron/cli.js").path,
                electronDirectory.path
            ]
        )
        XCTAssertTrue(try XCTUnwrap(command.environment["PATH"]).contains(".volta/bin"))
    }

    func testElectronDirectoryPrefersBundledResourcesBeforeRepositoryWorkingDirectory() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let bundledElectron = tempRoot
            .appendingPathComponent("TokenMeter.app/Contents/Resources/Electron", isDirectory: true)
        let workingDirectory = tempRoot
            .appendingPathComponent("repo", isDirectory: true)
        let sourceElectron = workingDirectory.appendingPathComponent("Electron", isDirectory: true)
        try makeElectronDirectory(bundledElectron)
        try makeElectronDirectory(sourceElectron)

        let selected = ElectronMainInterfaceLauncher.electronDirectory(
            environment: [:],
            currentDirectoryPath: workingDirectory.path,
            resourceURL: bundledElectron.deletingLastPathComponent()
        )

        XCTAssertEqual(selected, bundledElectron)
    }

    private func makeElectronDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"name":"token-meter-electron"}"#.utf8)
            .write(to: directory.appendingPathComponent("package.json"))
    }

    private func performMenuItem(_ item: NSMenuItem) throws {
        let action = try XCTUnwrap(item.action)
        XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item))
    }

    private func makeStore() -> ProviderStore {
        ProviderStore(
            config: TokenMeterConfig(menuBar: MenuBarConfig(primaryProviderId: nil), providers: []),
            notificationCenter: nil,
            databaseURL: nil
        )
    }
}

private final class RecordingMainInterfaceLauncher: MainInterfaceLaunching {
    private(set) var openCount = 0

    func openMainInterface() {
        openCount += 1
    }
}

@MainActor
private final class SpyPopover: PopoverPresenting {
    var behavior: NSPopover.Behavior = .transient
    var animates = true
    private(set) var isShown = false
    var contentSize: NSSize = .zero
    var contentViewController: NSViewController?
    var appearance: NSAppearance?
    private(set) var performCloseCallCount = 0

    func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge) {
        isShown = true
    }

    func performClose(_ sender: Any?) {
        performCloseCallCount += 1
        isShown = false
    }
}
