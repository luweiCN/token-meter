import Foundation
import XCTest
@testable import TokenMeterApp
@testable import TokenMeterCore

@MainActor
final class ProviderStoreLocalIndexTests: XCTestCase {
    func testLocalModelDetailsFilterEmptyEventsBeforeTheHeatmapLimit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tokenmeter.sqlite")
        let store = ProviderStore(config: TokenMeterConfig(menuBar: MenuBarConfig(primaryProviderId: nil), providers: []), databaseURL: url)
        let database = try SQLiteDatabase(path: url.path)
        let today = MonthActivityRepository.dayText(Date())
        func insert(_ model: String, cost: Int64 = 0, credits: Int64 = 0, missingTokens: Int64 = 0) throws {
            try database.execute("""
                INSERT INTO daily_rollup(
                    usage_date, provider_id, source_kind, model_canonical, sessions_count, events_count,
                    cost_usd_micros, credits_picos, token_unreported_events
                ) VALUES (?, 'codex', 'codex_jsonl', ?, 1, 1, ?, ?, ?)
                """, [.text(today), .text(model), .int(cost), .int(credits), .int(missingTokens)])
        }
        for index in 0..<7 { try insert("a-empty-\(index)") }
        try insert("known-cost", cost: 250_000)
        try insert("paid-credits", credits: 7)
        try insert("unreported-tokens", missingTokens: 1)

        await store.reloadTodaySummary()

        let expected = ["known-cost", "paid-credits", "unreported-tokens"]
        let details = store.modelBreakdown(for: today)
        XCTAssertEqual(store.dailyModels?.rows.map(\.id), expected)
        XCTAssertEqual(details.map(\.id), expected)
        XCTAssertEqual(details.first?.usage.costMicros, 250_000)
        XCTAssertEqual(details.first(where: { $0.id == "paid-credits" })?.hasCredits, true)
        XCTAssertEqual(details.last?.usage.tokenAmount.dailyText, "—")
    }

    func testHeaderAndHeatmapCombineDevicesAndCountTheLocalLedgerOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let node = directory.appendingPathComponent("node", isDirectory: true)
        try FileManager.default.createDirectory(at: node, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tokenmeter.sqlite")
        let store = ProviderStore(config: TokenMeterConfig(menuBar: MenuBarConfig(primaryProviderId: nil), providers: []), databaseURL: url)
        let database = try SQLiteDatabase(path: url.path)
        let today = MonthActivityRepository.dayText(Date())
        try database.execute("""
            INSERT INTO daily_rollup(
                usage_date, provider_id, source_kind, model_canonical, sessions_count, events_count,
                tokens_input, tokens_output, tokens_reasoning, tokens_cache_read,
                tokens_cache_write_5m, tokens_cache_write_1h, cost_usd_micros, cost_unknown_events
            ) VALUES (?, 'codex', 'codex_jsonl', 'shared-model', 1, 1, 1000000, 0, 0, 0, 0, 0, 250000, 0)
            """, [.text(today)])
        await store.reloadTodaySummary()
        XCTAssertEqual(store.todaySummary.usage.tokens, 1_000_000)
        XCTAssertEqual(store.overviewStats?.total.tokens, 1_000_000)

        func usage(tokens: Int, cached: Int, cost: Int, unknown: Int, events: Int) -> [String: Any] {
            ["tokens": tokens, "input": tokens - cached, "cacheRead": cached, "cacheWrite": 0,
             "costMicros": cost, "unknownCost": unknown, "unknownTokens": 0, "events": events]
        }
        func writeCache(includesLocal: Bool) throws {
            let remote = usage(tokens: 3_000_000, cached: 3_000_000, cost: 750_000, unknown: 1, events: 1)
            let local = usage(tokens: 1_000_000, cached: 0, cost: 250_000, unknown: 0, events: 1)
            let todayUsage = includesLocal
                ? usage(tokens: 4_000_000, cached: 3_000_000, cost: 1_000_000, unknown: 1, events: 2) : remote
            let remoteDevice = remote.merging(["id": "remote", "name": "Remote", "local": false, "active": true, "observed": 1]) { _, value in value }
            let localDevice = local.merging(["id": "local", "name": "Local", "local": true, "active": true, "observed": 1]) { _, value in value }
            let idle = usage(tokens: 0, cached: 0, cost: 0, unknown: 0, events: 0)
            let idleDevice = idle.merging(["id": "idle", "name": "Idle", "local": false, "active": false, "observed": 1]) { _, value in value }
            let billed = idle.merging(["hasCredits": true]) { _, value in value }
            let billedDevice = idle.merging(["id": "billed", "name": "Billed", "local": false, "active": true, "observed": 1]) { _, value in value }
            let models = [todayUsage.merging(["model": "shared-model"]) { _, value in value }]
            var deviceUsage = ["remote": remote, "idle": idle, "billed": billed]
            var devices = [remoteDevice, idleDevice, billedDevice]
            if includesLocal {
                deviceUsage["local"] = local
                devices.append(localDevice)
            }
            let dayUsage = todayUsage.merging(["models": models, "sessionsIncomplete": true, "devices": deviceUsage]) { _, value in value }
            let total = usage(tokens: includesLocal ? 6_000_000 : 5_000_000, cached: 3_000_000,
                              cost: includesLocal ? 1_000_000 : 750_000, unknown: 1, events: includesLocal ? 3 : 2)
            let history: [String: Any] = ["total": total, "month": todayUsage, "week": todayUsage, "days": [today: dayUsage]]
            let report: [String: Any] = ["day": today, "devices": devices,
                                         "agents": [], "models": models, "history": history]
            try JSONSerialization.data(withJSONObject: report).write(to: DesktopNode.summaryURL(in: node), options: .atomic)
        }

        for includesLocal in [false, true] {
            try writeCache(includesLocal: includesLocal)
            await store.reloadDailyNodeSummary()
            XCTAssertEqual(store.todaySummary.usage.tokens, 4_000_000)
            XCTAssertNil(store.todaySummary.sessions)
            XCTAssertEqual(store.overviewStats?.total.tokens, 6_000_000)
            XCTAssertEqual(store.overviewStats?.month.tokens, 4_000_000)
            XCTAssertEqual(store.overviewStats?.week.costMicros, 1_000_000)
            let day = try XCTUnwrap(store.monthActivity.first)
            XCTAssertEqual(day.tokens, 4_000_000)
            XCTAssertEqual(day.events, 2)
            XCTAssertFalse(day.includesAllSessionCounts)
            let model = try XCTUnwrap(store.modelBreakdown(for: today).first)
            XCTAssertEqual(model.usage, store.todaySummary.usage)
            XCTAssertEqual(model.usage.cacheUsage.percentText, "75.0%")
            XCTAssertEqual(model.usage.formattedCost(currency: .usd, usdToCny: 1), "$1.00+")
            XCTAssertEqual(store.modelBreakdown(for: today).count, 1)
            let devices = store.deviceBreakdown(for: today)
            XCTAssertEqual(devices.map(\.name), ["Remote", includesLocal ? "Local" : "本机", "Billed"])
            XCTAssertEqual(devices.map(\.usage.tokens), [3_000_000, 1_000_000, 0])
            XCTAssertEqual(store.dailyNodeSummary?.history?.days[today]?.devices?["billed"]?.hasCredits, true)
            XCTAssertEqual(devices.first?.usage.formattedCost(currency: .usd, usdToCny: 1), "$0.75+")
            XCTAssertTrue(store.deviceBreakdown(for: "2000-01-01").isEmpty)
        }
    }

    func testReloadSettingsPublishesPeakVisibilityFromDesktop() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.sqlite")
        let store = ProviderStore(config: TokenMeterConfig(menuBar: MenuBarConfig(primaryProviderId: nil), providers: []), databaseURL: url)
        let desktop = try SQLiteDatabase(path: url.path)
        let initial = try XCTUnwrap(store.settingsSnapshot)
        XCTAssertTrue(initial.menuBarAppearance.showPeakBadge)
        XCTAssertTrue(initial.menuBarAppearance.showPeakSection)

        let desktopVersion = initial.version + 1
        try desktop.execute("""
            INSERT INTO settings(key, value_json, value_type, version, updated_by) VALUES
                ('menubar.showPeakSection', '0', 'int', ?, 'electron'),
                ('menubar.peakBadgeStyle', '"pill"', 'string', ?, 'electron')
            """, [.int(Int64(desktopVersion)), .int(Int64(desktopVersion))])

        try store.reloadSettings(expectedVersion: desktopVersion)
        let snapshot = try XCTUnwrap(store.settingsSnapshot)
        XCTAssertEqual(snapshot.version, desktopVersion)
        XCTAssertTrue(snapshot.menuBarAppearance.showPeakBadge)
        XCTAssertFalse(snapshot.menuBarAppearance.showPeakSection)
        XCTAssertEqual(snapshot.menuBarAppearance.peakBadgeStyle, .pill)
    }

    func testTieredPricingEntriesLoadFromEffectiveSnapshot() {
        let homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        let store = ProviderStore(
            config: TokenMeterConfig(menuBar: MenuBarConfig(primaryProviderId: nil), providers: []),
            notificationCenter: nil,
            databaseURL: homeDirectory.appendingPathComponent("tokenmeter.sqlite")
        )

        XCTAssertEqual(store.tieredPricingEntries.count, 2)
        XCTAssertEqual(
            Set(store.tieredPricingEntries.map(\.modelName)),
            ["deepseek-v4-flash", "deepseek-v4-pro"]
        )
        XCTAssertTrue(store.tieredPricingEntries.allSatisfy { $0.brandName == "DeepSeek" })
        XCTAssertTrue(store.tieredPricingEntries.allSatisfy { $0.tier.weekdaysOnly })
        // 峰谷是模型定价状态，不依赖某一家额度接口是否有卡片或是否启用。
        XCTAssertEqual(store.peakPricingRows.count, 1)
        XCTAssertEqual(store.peakPricingRows[0].brandName, "DeepSeek")
        XCTAssertFalse(store.peakPricingRows[0].modelNames.isEmpty)
    }

    /// 并发单飞：await scanner 让出 MainActor 时重入的第二个调用必须被挡回
    ///（否则增量扫描会堆叠——实测 16 路并发把 CPU 顶到 150%+）。
    func testConcurrentRefreshCallsCoalesceIntoOneScan() async throws {
        let homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        let codexRoot = homeDirectory.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try writeLocalIndexJSONL(codexJSONL(sessionKey: "s", inputTokens: 1, outputTokens: 1), to: codexRoot.appendingPathComponent("session.jsonl"))

        let databaseURL = homeDirectory
            .appendingPathComponent("database", isDirectory: true)
            .appendingPathComponent("tokenmeter.sqlite")
        let store = ProviderStore(
            config: TokenMeterConfig(menuBar: MenuBarConfig(primaryProviderId: nil), providers: []),
            notificationCenter: nil,
            databaseURL: databaseURL
        )
        let database = try SQLiteDatabase(path: databaseURL.path)
        try insertScanRoot(database, id: 1, kind: .codexJSONL, rootPath: codexRoot.path, displayName: "Codex")

        async let first = store.refreshLocalAgentIndex()
        async let second = store.refreshLocalAgentIndex()
        let results = await [first, second]

        // 一个真扫、另一个被单飞守卫合并（消息「扫描已在进行」，不新起 scan_runs）。
        let skipped = results.filter { $0.message == "扫描已在进行" }
        XCTAssertEqual(skipped.count, 1, "并发调用必须恰好一个被合并")
        XCTAssertEqual(
            try scalarInt(database, "SELECT count(*) AS value FROM scan_runs"),
            1,
            "两次并发调用只允许产生一轮扫描"
        )
    }

    func testRefreshLocalAgentIndexScansOnlyEnabledAgentKinds() async throws {
        let homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        let claudeRoot = homeDirectory.appendingPathComponent("claude", isDirectory: true)
        let codexRoot = homeDirectory.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try writeLocalIndexJSONL(claudeJSONL(sessionKey: "claude-disabled", inputTokens: 1, outputTokens: 2), to: claudeRoot.appendingPathComponent("session.jsonl"))
        try writeLocalIndexJSONL(codexJSONL(sessionKey: "codex-enabled", inputTokens: 3, outputTokens: 4), to: codexRoot.appendingPathComponent("session.jsonl"))

        let databaseURL = homeDirectory
            .appendingPathComponent("database", isDirectory: true)
            .appendingPathComponent("tokenmeter.sqlite")
        let store = ProviderStore(
            config: TokenMeterConfig(menuBar: MenuBarConfig(primaryProviderId: nil), providers: []),
            notificationCenter: nil,
            databaseURL: databaseURL
        )

        let database = try SQLiteDatabase(path: databaseURL.path)
        try insertScanRoot(database, id: 1, kind: .claudeJSONL, rootPath: claudeRoot.path, displayName: "Claude")
        try insertScanRoot(database, id: 2, kind: .codexJSONL, rootPath: codexRoot.path, displayName: "Codex")

        let settingsStore = SettingsStore(database: database)
        let currentSettings = try XCTUnwrap(store.settingsSnapshot)
        _ = try settingsStore.apply(
            SettingsPatch(enabledAgentKinds: [LocalAgentKind.codex.rawValue]),
            expectedVersion: currentSettings.version,
            updatedBy: .swift
        )
        try store.reloadSettings()

        await store.refreshLocalAgentIndex()

        XCTAssertEqual(
            try scalarInt(database, "SELECT count(*) AS value FROM scan_runs WHERE scan_root_id = 1"),
            0,
            "disabled agent kinds must not create scan_runs for their roots"
        )
        XCTAssertEqual(
            try scalarInt(database, "SELECT count(*) AS value FROM source_files WHERE scan_root_id = 1"),
            0,
            "disabled agent kinds must not index source_files from their roots"
        )
        XCTAssertEqual(
            try scalarInt(database, "SELECT count(*) AS value FROM scan_runs WHERE scan_root_id = 2"),
            1,
            "enabled agent kinds should still be scanned"
        )
        XCTAssertEqual(
            try database.query("SELECT source_session_key FROM agent_sessions WHERE scan_root_id = 2").first?.string("source_session_key"),
            "codex-enabled"
        )
    }
}

private func insertScanRoot(
    _ database: SQLiteDatabase,
    id: Int64,
    kind: SourceKind,
    rootPath: String,
    displayName: String
) throws {
    try database.execute(
        """
        INSERT INTO scan_roots(id, kind, root_path, display_name, stable_source_key)
        VALUES (?, ?, ?, ?, ?)
        """,
        [
            .int(id),
            .text(kind.rawValue),
            .text(rootPath),
            .text(displayName),
            .text("\(kind.rawValue):\(rootPath)")
        ]
    )
}

private func claudeJSONL(sessionKey: String, inputTokens: Int64, outputTokens: Int64) -> String {
    """
    {"sessionId":"\(sessionKey)","cwd":"/repo/\(sessionKey)","type":"assistant","message":{"role":"assistant","model":"claude-sonnet","usage":{"input_tokens":\(inputTokens),"output_tokens":\(outputTokens)}}}

    """
}

private func codexJSONL(sessionKey: String, inputTokens: Int64, outputTokens: Int64) -> String {
    """
    {"type":"session_meta","payload":{"id":"\(sessionKey)","cwd":"/repo/\(sessionKey)"}}
    {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(inputTokens),"output_tokens":\(outputTokens)}}}}

    """
}

private func writeLocalIndexJSONL(_ content: String, to file: URL) throws {
    try Data(content.utf8).write(to: file)
}

private func scalarInt(_ database: SQLiteDatabase, _ sql: String, _ parameters: [SQLiteValue] = []) throws -> Int64 {
    try XCTUnwrap(database.query(sql, parameters).first?.int("value"))
}
