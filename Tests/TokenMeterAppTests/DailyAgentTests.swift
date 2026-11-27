import Foundation
import XCTest
@testable import TokenMeterApp
import TokenMeterCore

final class DailyAgentTests: XCTestCase {
    private func snapshot(localDevice: Bool, localOnly: Bool, credits: String? = nil) throws -> NodeDailySummary {
        var metric: [String: Any] = [
            "tokens": 115, "costMicros": 30, "input": 35, "cacheRead": 60,
            "cacheWrite": 5, "unknownCost": 1, "unknownTokens": 0
        ]
        let device = metric.merging(["id": "host", "name": "host", "observed": 10, "local": localDevice, "active": true]) { _, v in v }
        metric["id"] = "qoder-cli"
        metric["localOnly"] = localOnly
        metric["creditsPicos"] = credits
        return try JSONDecoder().decode(NodeDailySummary.self, from: JSONSerialization.data(withJSONObject: [
            "day": "2026-11-25", "devices": [device], "agents": [metric]
        ]))
    }

    private var local: MenuBarTodaySummary.ProviderToday {
        var row = MenuBarTodaySummary.ProviderToday(providerId: "qoder-cli", tokens: 50, costUsdMicros: 10,
                                                   creditsPicos: 8, creditEvents: 1, sessions: 2)
        row.cacheUsage = PromptCacheUsage(readTokens: 4, inputTokens: 20)
        row.unknownCostEvents = 2
        return row
    }

    func testRemoteAndLocalDoNotDoubleCountOrBorrowLocalSessions() throws {
        let mixed = try snapshot(localDevice: true, localOnly: false, credits: "12")
        let rows = DailyAgentRow.rows(node: mixed, local: [local])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.usage.tokens, 115)
        XCTAssertEqual(rows.first?.usage.cacheUsage.percentText, "60.0%")
        XCTAssertEqual(rows.first?.creditsPicos, 12)
        XCTAssertNil(rows.first?.sessions)
        let localNode = try snapshot(localDevice: true, localOnly: true, credits: "8")
        XCTAssertEqual(DailyAgentRow.rows(node: localNode, local: [local]).first?.sessions, 2)
    }

    func testIndependentSourcesRemainVisibleDuringStartup() throws {
        let registered = DailyAgentRow.rows(node: nil, local: [local])
        XCTAssertEqual(registered.first?.usage.unknownCost, 2)
        XCTAssertEqual(registered.first?.usage.cacheUsage.percentText, "20.0%")
        XCTAssertEqual(registered.first?.sessions, 2)
        let peer = try snapshot(localDevice: false, localOnly: false, credits: "12")
        let remoteOnly = DailyAgentRow.rows(node: peer, local: [])
        XCTAssertEqual(remoteOnly.first?.usage.tokens, 115)
        XCTAssertNil(remoteOnly.first?.sessions)
        XCTAssertTrue(peer.visibleMachines.isEmpty)
        let both = DailyAgentRow.rows(node: peer, local: [local])
        XCTAssertEqual(both.first?.usage.tokens, 165)
        XCTAssertEqual(both.first?.usage.costMicros, 40)
        XCTAssertEqual(both.first?.usage.cacheUsage.percentText, "53.3%")
        XCTAssertEqual(both.first?.creditsPicos, 20)
        XCTAssertNil(both.first?.sessions)
        XCTAssertEqual(MenuBarProviderName.label("openclaw"), "OpenClaw")
        XCTAssertEqual(MenuBarProviderName.label("hermes"), "Hermes Agent")
    }

    func testIncompleteLocalSessionCountsStayHiddenWithAndWithoutNode() throws {
        var incomplete = local
        incomplete.sessionCountIsComplete = false
        let node = try snapshot(localDevice: true, localOnly: true)
        for snapshot in [nil, node] {
            let row = try XCTUnwrap(DailyAgentRow.rows(node: snapshot, local: [incomplete]).first)
            XCTAssertNil(row.sessions)
            XCTAssertGreaterThan(row.usage.tokens, 0)
        }
        let zero = MenuBarTodaySummary.ProviderToday(providerId: local.providerId, tokens: 10, costUsdMicros: 5, sessions: 0)
        XCTAssertEqual(DailyAgentRow.rows(node: node, local: [zero]).first?.sessions, 0)
    }

    func testMalformedCountsCannotOverflowTheMenu() throws {
        let corrupt: [String: Int64] = [
            "tokens": .max, "costMicros": 0, "input": .max, "cacheRead": 1,
            "cacheWrite": 0, "unknownCost": 0, "unknownTokens": 0
        ]
        let data = try JSONSerialization.data(withJSONObject: corrupt)
        XCTAssertThrowsError(try JSONDecoder().decode(DailyUsage.self, from: data))
        let max = DailyUsage(tokens: .max, unknownTokens: 0, costMicros: 0, unknownCost: 0, cacheUsage: .init())
        XCTAssertNil(max.adding(DailyUsage(local: local)))
    }
}
