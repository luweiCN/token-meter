import XCTest
@testable import TokenMeterCore

final class OpenCodeGoDashboardParserTests: XCTestCase {
    func testParsesRollingWeeklyMonthlyLabels() {
        let windows = OpenCodeGoDashboardParser.parse(items: [
            (label: "Rolling Usage", value: "12%", reset: "Resets in 1 hour 49 minutes"),
            (label: "Weekly Usage", value: "68%", reset: "Resets in 2 days 13 hours"),
            (label: "Monthly Usage", value: "3%", reset: "Resets in 27 days 18 hours")
        ])

        XCTAssertEqual(windows, [
            OpenCodeGoUsageWindowData(label: "5h", usagePercent: 12, resetsInSeconds: (1 * 3600 + 49 * 60)),
            OpenCodeGoUsageWindowData(label: "Weekly", usagePercent: 68, resetsInSeconds: (2 * 86_400 + 13 * 3600)),
            OpenCodeGoUsageWindowData(label: "Monthly", usagePercent: 3, resetsInSeconds: (27 * 86_400 + 18 * 3600))
        ])
    }

    func testParsesChineseLabels() {
        let windows = OpenCodeGoDashboardParser.parse(items: [
            (label: "滚动用量", value: "2%", reset: "重置于 1 小时 49 分钟"),
            (label: "每周用量", value: "0%", reset: "重置于 2 天 13 小时"),
            (label: "每月用量", value: "0%", reset: nil)
        ])

        XCTAssertEqual(windows, [
            OpenCodeGoUsageWindowData(label: "5h", usagePercent: 2, resetsInSeconds: (1 * 3600 + 49 * 60)),
            OpenCodeGoUsageWindowData(label: "Weekly", usagePercent: 0, resetsInSeconds: (2 * 86_400 + 13 * 3600)),
            OpenCodeGoUsageWindowData(label: "Monthly", usagePercent: 0, resetsInSeconds: nil)
        ])
    }

    func testToleratesWhitespaceAndPercentSuffix() {
        let windows = OpenCodeGoDashboardParser.parse(items: [
            (label: "  Rolling Usage  ", value: " 25.5% ", reset: "Resets in 12m")
        ])

        XCTAssertEqual(windows.first?.label, "5h")
        XCTAssertEqual(windows.first?.usagePercent, 25.5)
        XCTAssertEqual(windows.first?.resetsInSeconds, 12 * 60)
    }

    func testIgnoresUnrecognizedLabelsAndNonNumericValues() {
        let windows = OpenCodeGoDashboardParser.parse(items: [
            (label: "Something Else", value: "12%", reset: nil),
            (label: "Rolling Usage", value: "abc", reset: nil)
        ])

        XCTAssertTrue(windows.isEmpty)
    }

    func testIgnoresUnusedBalanceItemWhenPresent() {
        let windows = OpenCodeGoDashboardParser.parse(items: [
            (label: "Rolling Usage", value: "12%", reset: nil),
            (label: "Balance", value: "$5.00", reset: nil),
            (label: "Monthly Usage", value: "3%", reset: nil)
        ])

        XCTAssertEqual(windows.map(\.label), ["5h", "Monthly"])
    }

    func testResetsInSecondsParsesEnglishAndChineseUnits() {
        XCTAssertEqual(OpenCodeGoDashboardParser.resetsInSeconds(from: "Resets in 1h 49m"), 1 * 3600 + 49 * 60)
        XCTAssertEqual(OpenCodeGoDashboardParser.resetsInSeconds(from: "Resets in 2d 13h"), 2 * 86_400 + 13 * 3600)
        XCTAssertEqual(OpenCodeGoDashboardParser.resetsInSeconds(from: "重置于 27 天 18 小时"), 27 * 86_400 + 18 * 3600)
        XCTAssertEqual(OpenCodeGoDashboardParser.resetsInSeconds(from: "重置于 45 分钟"), 45 * 60)
        XCTAssertNil(OpenCodeGoDashboardParser.resetsInSeconds(from: nil))
        XCTAssertNil(OpenCodeGoDashboardParser.resetsInSeconds(from: ""))
        XCTAssertNil(OpenCodeGoDashboardParser.resetsInSeconds(from: "重置于"))
    }
}

final class OpenCodeGoSnapshotBuilderTests: XCTestCase {
    func testBuildsThreePeerWindows() {
        let snapshot = OpenCodeGoSnapshotBuilder.snapshot(
            windows: [
                OpenCodeGoUsageWindowData(label: "5h", usagePercent: 20, resetsInSeconds: 3_600),
                OpenCodeGoUsageWindowData(label: "Weekly", usagePercent: 35, resetsInSeconds: 86_400),
                OpenCodeGoUsageWindowData(label: "Monthly", usagePercent: 60, resetsInSeconds: nil)
            ],
            providerId: "opencode-go",
            displayName: "OpenCode Go"
        )

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.message, "5h 80% · Weekly 65% · Monthly 40%")

        // 三窗口平级，全在主组（弹窗环两只 5h/7d、月度降条；菜单栏取首尾）
        XCTAssertEqual(snapshot.groups.count, 1)
        let primary = try! XCTUnwrap(snapshot.groups.first)
        XCTAssertEqual(primary.title, "OpenCode Go")
        XCTAssertEqual(primary.items.map(\.label), ["5h", "7d", "Monthly"])
        XCTAssertEqual(primary.items.map(\.remainingPercent), [80, 65, 40])
        XCTAssertEqual(primary.items[0].windowDurationMinutes, 300)
        XCTAssertEqual(primary.items[1].windowDurationMinutes, 7 * 24 * 60)
        XCTAssertEqual(primary.items[2].windowDurationMinutes, 30 * 24 * 60)

        // 环下方的「还剩多久刷新」：dashboard 的 resetsInSeconds → resetAt/resetText
        // （countdownText 对秒敏感，断言用精度 + 格式而非精确文本。）
        XCTAssertEqual(primary.items[0].resetAt?.timeIntervalSinceNow ?? 0, 3_600, accuracy: 5)
        XCTAssertEqual(primary.items[1].resetAt?.timeIntervalSinceNow ?? 0, 86_400, accuracy: 5)
        XCTAssertNotNil(primary.items[0].resetText)
        XCTAssertNotNil(primary.items[1].resetText)
        XCTAssertNil(primary.items[2].resetAt)
        XCTAssertNil(primary.items[2].resetText)
    }

    func testHandlesMissingWindowsGracefully() {
        let snapshot = OpenCodeGoSnapshotBuilder.snapshot(
            windows: [OpenCodeGoUsageWindowData(label: "Monthly", usagePercent: 3)],
            providerId: "opencode-go",
            displayName: "OpenCode Go"
        )

        XCTAssertEqual(snapshot.groups.first?.items.map(\.label), ["Monthly"])
        XCTAssertEqual(snapshot.message, "Monthly 97%")
    }
}

final class OpenCodeGoConfigParserTests: XCTestCase {
    func testParsesOpenCodeGoConfigFile() throws {
        let json = """
        {
          "workspaceId": "workspace-123",
          "authCookie": "cookie-abc"
        }
        """

        let config = try OpenCodeGoConfigParser.parse(Data(json.utf8))

        XCTAssertEqual(config.workspaceId, "workspace-123")
        XCTAssertEqual(config.authCookie, "cookie-abc")
    }
}
