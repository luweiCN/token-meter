import XCTest
@testable import TokenMeterCore

final class OpenCodeGoDashboardParserTests: XCTestCase {
    func testParsesRollingWeeklyMonthlyLabels() {
        let windows = OpenCodeGoDashboardParser.parse(items: [
            (label: "Rolling Usage", value: "12%"),
            (label: "Weekly Usage", value: "68%"),
            (label: "Monthly Usage", value: "3%")
        ])

        XCTAssertEqual(windows, [
            OpenCodeGoUsageWindowData(label: "5h", usagePercent: 12),
            OpenCodeGoUsageWindowData(label: "Weekly", usagePercent: 68),
            OpenCodeGoUsageWindowData(label: "Monthly", usagePercent: 3)
        ])
    }

    func testParsesChineseLabels() {
        let windows = OpenCodeGoDashboardParser.parse(items: [
            (label: "滚动用量", value: "2%"),
            (label: "每周用量", value: "0%"),
            (label: "每月用量", value: "0%")
        ])

        XCTAssertEqual(windows, [
            OpenCodeGoUsageWindowData(label: "5h", usagePercent: 2),
            OpenCodeGoUsageWindowData(label: "Weekly", usagePercent: 0),
            OpenCodeGoUsageWindowData(label: "Monthly", usagePercent: 0)
        ])
    }

    func testToleratesWhitespaceAndPercentSuffix() {
        let windows = OpenCodeGoDashboardParser.parse(items: [
            (label: "  Rolling Usage  ", value: " 25.5% ")
        ])

        XCTAssertEqual(windows.first?.label, "5h")
        XCTAssertEqual(windows.first?.usagePercent, 25.5)
    }

    func testIgnoresUnrecognizedLabelsAndNonNumericValues() {
        let windows = OpenCodeGoDashboardParser.parse(items: [
            (label: "Something Else", value: "12%"),
            (label: "Rolling Usage", value: "abc")
        ])

        XCTAssertTrue(windows.isEmpty)
    }

    func testIgnoresUnusedBalanceItemWhenPresent() {
        let windows = OpenCodeGoDashboardParser.parse(items: [
            (label: "Rolling Usage", value: "12%"),
            (label: "Balance", value: "$5.00"),
            (label: "Monthly Usage", value: "3%")
        ])

        XCTAssertEqual(windows.map(\.label), ["5h", "Monthly"])
    }
}

final class OpenCodeGoSnapshotBuilderTests: XCTestCase {
    func testBuildsThreePeerWindows() {
        let snapshot = OpenCodeGoSnapshotBuilder.snapshot(
            windows: [
                OpenCodeGoUsageWindowData(label: "5h", usagePercent: 20),
                OpenCodeGoUsageWindowData(label: "Weekly", usagePercent: 35),
                OpenCodeGoUsageWindowData(label: "Monthly", usagePercent: 60)
            ],
            providerId: "opencode-go",
            displayName: "OpenCode Go"
        )

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.message, "5h 80% · Weekly 65% · Monthly 40%")

        // 三窗口平级，全在主组（弹窗三环；菜单栏取首尾：5h + Monthly）
        XCTAssertEqual(snapshot.groups.count, 1)
        let primary = try! XCTUnwrap(snapshot.groups.first)
        XCTAssertEqual(primary.title, "OpenCode Go")
        XCTAssertEqual(primary.items.map(\.label), ["5h", "7d", "Monthly"])
        XCTAssertEqual(primary.items.map(\.remainingPercent), [80, 65, 40])
        XCTAssertEqual(primary.items[0].windowDurationMinutes, 300)
        XCTAssertEqual(primary.items[1].windowDurationMinutes, 7 * 24 * 60)
        XCTAssertEqual(primary.items[2].windowDurationMinutes, 30 * 24 * 60)
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
