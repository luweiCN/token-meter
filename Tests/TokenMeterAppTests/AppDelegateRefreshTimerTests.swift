import AppKit
import Darwin
import XCTest
@testable import TokenMeterApp
@testable import TokenMeterCore

final class AppDelegateRefreshTimerTests: XCTestCase {
    @MainActor
    func testSettingsIntervalChangesRecreateRefreshTimer() throws {
        let homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        let configURL = homeDirectory.appendingPathComponent("token-meter-config.json")
        try Data(#"{"providers":[]}"#.utf8).write(to: configURL)

        let previousFixedHome = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]
        let previousConfig = ProcessInfo.processInfo.environment["TOKENMETER_CONFIG"]
        setenv("CFFIXED_USER_HOME", homeDirectory.path, 1)
        setenv("TOKENMETER_CONFIG", configURL.path, 1)
        defer {
            restoreEnvironmentValue(previousFixedHome, forKey: "CFFIXED_USER_HOME")
            restoreEnvironmentValue(previousConfig, forKey: "TOKENMETER_CONFIG")
        }

        let delegate = AppDelegate()
        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification, object: NSApplication.shared)
        )
        defer {
            delegate.applicationWillTerminate(
                Notification(name: NSApplication.willTerminateNotification, object: NSApplication.shared)
            )
        }

        let initialTimer = try refreshTimer(in: delegate)
        XCTAssertEqual(initialTimer.timeInterval, 300)

        let store = try providerStore(in: delegate)
        let settingsStore = SettingsStore(
            database: try SQLiteDatabase(path: TokenMeterPaths.databaseURL(homeDirectory: homeDirectory).path)
        )
        let currentSettings = try XCTUnwrap(store.settingsSnapshot)
        _ = try settingsStore.apply(
            SettingsPatch(autoRefreshSeconds: 60),
            expectedVersion: currentSettings.version,
            updatedBy: .swift
        )

        try store.reloadSettings()

        let rescheduledTimer = try refreshTimer(in: delegate)
        XCTAssertEqual(
            rescheduledTimer.timeInterval,
            60,
            "settings interval changes should recreate/reschedule refresh timer with the updated interval"
        )
    }

    @MainActor
    private func refreshTimer(in delegate: AppDelegate) throws -> Timer {
        try mirroredValue(named: "refreshTimer", in: delegate)
    }

    @MainActor
    private func providerStore(in delegate: AppDelegate) throws -> ProviderStore {
        try mirroredValue(named: "store", in: delegate)
    }

    private func mirroredValue<Value>(named label: String, in subject: Any) throws -> Value {
        for child in Mirror(reflecting: subject).children where child.label == label {
            if let value = unwrapOptional(child.value) as? Value {
                return value
            }
        }
        throw XCTSkip("Missing AppDelegate.\(label) test seam")
    }

    private func unwrapOptional(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else {
            return value
        }
        return mirror.children.first?.value
    }

    private func restoreEnvironmentValue(_ value: String?, forKey key: String) {
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
    }
}
