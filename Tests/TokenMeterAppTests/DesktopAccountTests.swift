import Foundation
import XCTest
@testable import TokenMeterApp
@testable import TokenMeterCore

@MainActor
final class DesktopAccountTests: XCTestCase {
    private final class Fixture {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let feed: DesktopAccountFeed
        let notifications = Notifications()
        let store: ProviderStore

        @MainActor init() throws {
            let files = FileManager.default
            try files.createDirectory(at: home, withIntermediateDirectories: true)
            let executable = home.appendingPathComponent("token-meter")
            feed = DesktopAccountFeed(home: home, executable: executable)
            let script = #"""
            #!/bin/sh
            set -eu
            [ "$1" = "--home" ]
            home=$2
            [ "$3" = "--state" ] && [ "$4" = "$home/.token-meter/node" ]
            [ "$5" = "quota-refresh" ]
            printf '%s\n' "${6:-all}" >> "$home/requests"
            cp "$home/next.json" "$home/.token-meter/cache/update.tmp"
            mv "$home/.token-meter/cache/update.tmp" "$home/.token-meter/cache/provider-snapshots.json"
            """#
            try Data(script.utf8).write(to: executable)
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let config = try ProviderConfigLoader.decode(Data(#"{"providers":[{"id":"antigravity","type":"antigravity","displayName":"AGY","enabled":true}]}"#.utf8))
            store = ProviderStore(config: config, notificationCenter: notifications, databaseURL: nil, accountFeed: feed)
        }

        var requests: [String] {
            ((try? String(contentsOf: home.appendingPathComponent("requests"))) ?? "").split(separator: "\n").map(String.init)
        }

        func write(_ snapshots: [ProviderUsageSnapshot], to file: URL? = nil) throws {
            let file = file ?? feed.snapshotURL
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snapshots).write(to: file, options: .atomic)
        }

        deinit { try? FileManager.default.removeItem(at: home) }
    }

    private final class Notifications: UsageNotificationDelivering {
        var events: [UsageNotificationEvent] = []
        func authorizationState() async -> UsageNotificationAuthorizationState { .authorized }
        func requestAuthorization() async -> UsageNotificationAuthorizationState { .authorized }
        func deliver(_ next: [UsageNotificationEvent]) { events.append(contentsOf: next) }
        func openNotificationSettings() {}
    }

    private func metric(_ id: String, _ remaining: Double, _ minutes: Int) -> UsageMetric {
        UsageMetric(id: id, label: minutes == 300 ? "5 小时" : "每周", kind: .quota, usedPercent: 100 - remaining,
                    remainingPercent: remaining, resetText: nil, status: .ok, detail: nil, windowDurationMinutes: minutes)
    }

    private func snapshot(_ remaining: Double, at: Date = Date(), failure: String? = nil) -> ProviderUsageSnapshot {
        let amount = UsageMetric(id: "absolute", label: "absolute", kind: .quota,
                                 usedPercent: nil, remainingPercent: nil, resetText: nil, status: .ok, detail: "剩余 17")
        let groups = [
            UsageGroup(id: "gemini", title: "Gemini", subtitle: nil,
                       items: [metric("gemini-5h", remaining, 300), metric("gemini-weekly", 50, 10_080)]),
            UsageGroup(id: "3p", title: "Claude/GPT", subtitle: nil,
                       items: [metric("3p-5h", 40, 300), metric("3p-weekly", 0, 10_080)]),
            UsageGroup(id: "gemini-argon-wtu", title: "Gemini Argon WTU", subtitle: nil,
                       items: [metric("gemini-argon-wtu-weekly", 75, 10_080)]),
            UsageGroup(id: "absolute", title: "absolute", subtitle: nil, items: [amount])
        ]
        return ProviderUsageSnapshot(providerId: "antigravity", displayName: "AGY", status: failure == nil ? .ok : .warning,
                                    fetchedAt: at, summary: nil, message: failure, groups: groups)
    }

    func testMenuReadsScopedWindowsAndOriginalFailureAgeFromCLIFeed() async throws {
        let f = try Fixture()
        let old = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 16 * 3600)
        let message = "Google 拒绝了当前地区的后台额度查询。"
        try f.write([snapshot(100, at: old, failure: message)])
        await f.store.reloadAccountSnapshots()
        let cached = try XCTUnwrap(f.store.displayProviderSnapshots.first)
        let card = QuotaDisplayModel(snapshot: cached)
        XCTAssertEqual(cached.fetchedAt, old)
        XCTAssertEqual(cached.message, message)
        XCTAssertEqual(card.rings.map(\.label), ["Gemini 5h", "Gemini 7d"])
        XCTAssertEqual(card.menuBarWindows.map(\.label), ["5h", "7d"])
        XCTAssertEqual(card.summaryText, "5h 100% · 7d 50%")
        XCTAssertEqual(card.bars.map(\.label), ["Claude/GPT 5h", "Claude/GPT 7d", "Gemini Argon WTU 7d"])
        XCTAssertEqual(card.bars.map(\.percent), [40, 0, 75])
        XCTAssertTrue(card.bars.allSatisfy { $0.resetText == nil })
        XCTAssertEqual(card.creditDetails.first?.label, "absolute")
        XCTAssertEqual(AntigravityQuota.menuName("Antigravity"), "AGY")
        XCTAssertEqual(AntigravityQuota.menuName("我的 Google"), "我的 Google")
        XCTAssertTrue(f.requests.isEmpty)

        let fresh = snapshot(70)
        try f.write([fresh], to: f.home.appendingPathComponent("next.json"))
        await f.store.retryQuota(for: "antigravity")
        XCTAssertEqual(f.requests, ["antigravity"])
        XCTAssertEqual(f.store.displayProviderSnapshots.first?.status, .ok)
        XCTAssertNil(f.store.displayProviderSnapshots.first?.message)
        XCTAssertEqual(f.store.displayProviderSnapshots.first?.groups, fresh.groups)
        f.store.isScanPaused = true
        await f.store.retryQuota(for: "antigravity")
        XCTAssertEqual(f.requests, ["antigravity"])
    }

    func testConcurrentManualRequestsAreCoalescedAndNotificationsFollowFeedOnlyOnce() async throws {
        let f = try Fixture()
        try f.write([snapshot(75)])
        await f.store.reloadAccountSnapshots()
        try f.write([snapshot(0)], to: f.home.appendingPathComponent("next.json"))
        async let first: Void = f.store.refreshNow(providerID: "antigravity")
        async let second: Void = f.store.refreshNow(providerID: "antigravity")
        try await first
        try await second
        await f.store.reloadAccountSnapshots()
        XCTAssertEqual(f.requests, ["antigravity"])
        XCTAssertEqual(f.notifications.events.count, 1)
        XCTAssertFalse(f.store.isRefreshing)
        try await f.store.refreshNow()
        XCTAssertEqual(f.requests, ["antigravity", "all"])
    }

    func testRefreshLaunchFailureAndMalformedFeedPreserveLastReadings() async throws {
        let f = try Fixture()
        try f.write([snapshot(80)])
        await f.store.reloadAccountSnapshots()
        try Data("[".utf8).write(to: f.feed.snapshotURL, options: .atomic)
        await f.store.reloadAccountSnapshots()
        XCTAssertEqual(f.store.providerSnapshots.first?.groups.first?.items.first?.remainingPercent, 80)
        try FileManager.default.removeItem(at: try XCTUnwrap(f.feed.executable))
        await f.store.retryQuota(for: "antigravity")
        XCTAssertEqual(f.store.displayProviderSnapshots.first?.status, .warning)
        XCTAssertTrue(f.store.displayProviderSnapshots.first?.message?.contains("命令行") == true)
        XCTAssertEqual(f.store.displayProviderSnapshots.first?.groups.first?.items.first?.remainingPercent, 80)
        XCTAssertEqual(f.store.providerSnapshots.first?.status, .ok)
    }

    func testResetCardMessageReadsCurrentDaemonState() throws {
        let f = try Fixture()
        XCTAssertEqual(f.feed.resetStatusMessage(), "自动使用暂不可用")
        let state = TokenMeterPaths.baseDirectory(homeDirectory: f.home).appendingPathComponent("node/codex-reset-status.json")
        try FileManager.default.createDirectory(at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"status":"waiting","message":"等待重置卡进入到期前 1 小时"}"#.utf8).write(to: state, options: .atomic)
        XCTAssertEqual(f.feed.resetStatusMessage(), "等待重置卡进入到期前 1 小时")
        XCTAssertTrue(f.requests.isEmpty)
    }

    func testSnapshotWatcherFollowsLaterDirectoryCreationAndRepeatedAtomicReplacements() async throws {
        let f = try Fixture()
        let first = expectation(description: "observed initial snapshot")
        let second = expectation(description: "observed atomic replacement")
        var received: Set<Int> = []
        let watcher = SnapshotWatcher(file: f.feed.snapshotURL) {
            guard let snapshots = try? ProviderSnapshotDiskCache.read(from: f.feed.snapshotURL),
                  let left = snapshots.first?.groups.first?.items.first?.remainingPercent,
                  received.insert(Int(left)).inserted else { return }
            if left == 75 { first.fulfill() }
            if left == 25 { second.fulfill() }
        }
        defer { withExtendedLifetime(watcher) {} }
        try f.write([snapshot(75)])
        await fulfillment(of: [first], timeout: 3)
        try f.write([snapshot(25)])
        await fulfillment(of: [second], timeout: 3)
        XCTAssertTrue(f.requests.isEmpty)
    }
}
