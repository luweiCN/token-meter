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

    func testContextMenuContainsOpenMainInterfaceAndQuit() throws {
        let controller = StatusBarController(
            store: makeStore(),
            mainInterfaceLauncher: RecordingMainInterfaceLauncher(),
            quitApplication: {}
        )

        let menu = controller.makeContextMenuForTesting()

        XCTAssertEqual(menu.items.first?.title, "打开主界面")
        XCTAssertTrue(menu.items.dropFirst().first?.isSeparatorItem == true)
        XCTAssertEqual(menu.items.last?.title, "退出 TokenMeter")
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
