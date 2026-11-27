import Foundation
import XCTest
@testable import TokenMeterApp
@testable import TokenMeterCore

final class DailyModelsTests: XCTestCase {
    private var local: MenuBarTodaySummary.ModelToday {
        var row = MenuBarTodaySummary.ModelToday(model: "gpt-5.6-sol", tokens: 50, costUsdMicros: 10)
        row.cacheUsage = PromptCacheUsage(readTokens: 4, inputTokens: 20)
        row.unknownCostEvents = 2
        return row
    }

    private func snapshotData(includesLocal: Bool, includesModels: Bool = true) throws -> Data {
        let calendar = ISO8601DateFormatter()
        calendar.formatOptions = [.withFullDate]
        calendar.timeZone = .current
        let device: [String: Any] = [
            "id": "host", "name": "host", "observed": 1, "active": true, "local": includesLocal,
            "tokens": 156, "input": 50, "cacheRead": 78, "cacheWrite": 6,
            "costMicros": 25, "unknownCost": 1, "unknownTokens": 1
        ]
        var snapshot: [String: Any] = ["day": calendar.string(from: Date()), "devices": [device], "agents": []]
        if includesModels {
            snapshot["models"] = [
                ["model": "gpt-5.6-sol", "tokens": 100, "input": 30, "cacheRead": 60, "cacheWrite": 0,
                 "costMicros": 20, "unknownCost": 0, "unknownTokens": 0],
                ["model": "openai/GPT-5.6-SOL-high", "tokens": 20, "input": 20, "cacheRead": 0, "cacheWrite": 0,
                 "costMicros": 5, "unknownCost": 0, "unknownTokens": 0],
                ["model": "remote-model", "tokens": 36, "input": 0, "cacheRead": 18, "cacheWrite": 6,
                 "costMicros": 0, "unknownCost": 1, "unknownTokens": 1],
                ["model": "events-only-model", "tokens": 0, "input": 0, "cacheRead": 0, "cacheWrite": 0,
                 "events": 40, "costMicros": 0, "unknownCost": 0, "unknownTokens": 0]
            ]
        }
        return try JSONSerialization.data(withJSONObject: snapshot)
    }

    func testSyncedModelsMergeAliasesWithoutCountingLocalTwice() throws {
        let snapshot = try JSONDecoder().decode(NodeDailySummary.self, from: snapshotData(includesLocal: true))
        let models = try XCTUnwrap(DailyModelSummary.from(node: snapshot, local: [local]))

        XCTAssertEqual(models.rows.map(\.id), ["gpt-5.6-sol", "remote-model"])
        XCTAssertEqual(models.rows.map(\.usage.tokens), [120, 36])
        XCTAssertEqual(models.total.tokens, 156)
        XCTAssertEqual(models.total.costMicros, 25)
        XCTAssertEqual(models.total.unknownCost, 1)
        XCTAssertEqual(models.total.unknownTokens, 1)
        XCTAssertEqual(models.total.cacheUsage, PromptCacheUsage(readTokens: 78, inputTokens: 134))
    }

    func testRemoteOnlySnapshotIncludesLocalUsage() throws {
        let snapshot = try JSONDecoder().decode(NodeDailySummary.self, from: snapshotData(includesLocal: false))
        let models = try XCTUnwrap(DailyModelSummary.from(node: snapshot, local: [local]))

        XCTAssertEqual(models.rows.first?.usage.tokens, 170)
        XCTAssertEqual(models.total.tokens, 206)
        XCTAssertEqual(models.total.costMicros, 35)
        XCTAssertEqual(models.total.unknownCost, 3)
        XCTAssertEqual(models.total.cacheUsage, PromptCacheUsage(readTokens: 82, inputTokens: 154))
    }

    func testLegacySnapshotUsesLocalModelsOnlyWhenLocalDataIsSufficient() throws {
        let legacy = try JSONDecoder().decode(
            NodeDailySummary.self, from: snapshotData(includesLocal: true, includesModels: false)
        )
        let legacyWithRemote = try JSONDecoder().decode(
            NodeDailySummary.self, from: snapshotData(includesLocal: false, includesModels: false)
        )

        XCTAssertEqual(DailyModelSummary.from(node: nil, local: [local])?.total.tokens, 50)
        XCTAssertEqual(DailyModelSummary.from(node: legacy, local: [local])?.total.tokens, 50)
        XCTAssertNil(DailyModelSummary.from(node: legacyWithRemote, local: [local]))
    }

    @MainActor
    func testReloadPublishesModelsFromTheMenuSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let node = directory.appendingPathComponent("node", isDirectory: true)
        try FileManager.default.createDirectory(at: node, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try snapshotData(includesLocal: true).write(to: node.appendingPathComponent("summary.json"))
        let store = ProviderStore(
            config: TokenMeterConfig(menuBar: MenuBarConfig(primaryProviderId: nil), providers: []),
            databaseURL: directory.appendingPathComponent("tokenmeter.sqlite")
        )

        await store.reloadDailyNodeSummary()

        XCTAssertEqual(store.dailyModels?.rows.map(\.id), ["gpt-5.6-sol", "remote-model"])
        XCTAssertEqual(store.dailyModels?.total.tokens, 156)
    }
}
