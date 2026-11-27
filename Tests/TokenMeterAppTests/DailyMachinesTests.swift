import Foundation
import XCTest
@testable import TokenMeterApp
import TokenMeterCore

final class DailyMachinesTests: XCTestCase {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = .current
        return result
    }

    private func machine(_ id: String, local: Bool = false, usage: [String: Int64] = [:]) -> [String: Any] {
        var row: [String: Any] = [
            "id": id, "name": id, "os": local ? "darwin" : "linux", "local": local,
            "active": !usage.isEmpty,
            "observed": 1, "tokens": 0, "costMicros": 0, "unknownTokens": 0, "unknownCost": 0,
            "events": 0, "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0
        ]
        for (key, value) in usage { row[key] = value }
        return row
    }

    private func write(_ rows: [[String: Any]], to directory: URL, day: String = "2026-11-25") throws {
        let report: [String: Any] = ["day": day, "devices": rows, "agents": []]
        let data = try JSONSerialization.data(withJSONObject: report)
        try data.write(to: directory.appendingPathComponent("summary.json"), options: .atomic)
    }

    private func testDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testOnlyMultipleActiveMachinesHaveRowsIncludingTwoRemoteMachines() throws {
        let directory = try testDirectory()
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 16)))
        let local = machine("Mac", local: true)
        let linux = machine("Linux", usage: ["tokens": 9, "input": 9, "events": 1])
        try write([local, linux], to: directory)
        let first = try XCTUnwrap(DesktopNode.dailySummary(now: now, directory: directory))
        XCTAssertTrue(first.visibleMachines.isEmpty)

        let other = machine("Worker", usage: ["tokens": 1, "input": 1, "events": 1])
        try write([other, local, linux], to: directory)
        let second = try XCTUnwrap(DesktopNode.dailySummary(now: now, directory: directory))
        XCTAssertEqual(Set(second.visibleMachines.map(\.id)), ["Linux", "Worker"])
    }

    func testCrossingLocalMidnightHidesThePreviousSummary() throws {
        let directory = try testDirectory()
        let first = machine("Mac", local: true, usage: ["tokens": 12, "input": 12])
        let second = machine("Linux", usage: ["tokens": 10, "input": 10])
        try write([first, second], to: directory)
        let midnight = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 26)))
        let previousDay = try XCTUnwrap(DesktopNode.dailySummary(now: midnight.addingTimeInterval(-1), directory: directory))
        XCTAssertEqual(previousDay.visibleMachines.map(\.id), ["Mac", "Linux"])
        XCTAssertNil(DesktopNode.dailySummary(now: midnight, directory: directory))
    }

    func testRowsFormatTokensOnceAndDistinguishUnreportedValues() throws {
        let directory = try testDirectory()
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 12)))
        let known = machine("Mac", local: true, usage: [
            "tokens": 4_000_000_000, "input": 100, "cacheRead": 135, "cacheWrite": 35,
            "output": 3_999_999_730, "costMicros": 1_250_000, "unknownCost": 1, "events": 8
        ])
        let partial = machine("Linux", usage: ["events": 1, "unknownTokens": 1, "unknownCost": 1])
        try write([known, partial], to: directory)
        let rows = try XCTUnwrap(DesktopNode.dailySummary(now: now, directory: directory)).visibleMachines
        let mac = try XCTUnwrap(rows.first { $0.id == "Mac" })
        let linux = try XCTUnwrap(rows.first { $0.id == "Linux" })
        XCTAssertEqual(mac.usage.tokenAmount.dailyText, "4000.0M")
        XCTAssertEqual(mac.usage.cacheUsage.percentText, "50.0%")
        XCTAssertEqual(mac.usage.formattedCost(currency: .usd, usdToCny: 7), "$1.25+")
        XCTAssertEqual(mac.usage.formattedCost(currency: .cny, usdToCny: 7), "¥8.75+")
        XCTAssertEqual(linux.usage.tokenAmount.dailyText, "—")
        XCTAssertEqual(linux.usage.cacheUsage.percentText, "暂无数据")
        XCTAssertEqual(linux.usage.formattedCost(currency: .usd, usdToCny: 7), "未知")
    }
}
