import XCTest
@testable import TokenMeterCore

final class CodexUsageParserTests: XCTestCase {
    func testParsesMultipleRateLimitBuckets() throws {
        let json = """
        {
          "rateLimitsByLimitId": {
            "codex_bengalfox": {
              "limitId": "codex_bengalfox",
              "limitName": "GPT-5.3-Codex-Spark",
              "primary": {
                "usedPercent": 0,
                "resetsAt": 1782951904,
                "windowDurationMins": 300
              },
              "secondary": {
                "usedPercent": 0,
                "resetsAt": 1783538704,
                "windowDurationMins": 10080
              }
            },
            "codex": {
              "limitId": "codex",
              "limitName": null,
              "primary": {
                "usedPercent": 52,
                "resetsAt": 1782940713,
                "windowDurationMins": 300
              },
              "secondary": {
                "usedPercent": 33,
                "resetsAt": 1783388700,
                "windowDurationMins": 10080
              }
            }
          }
        }
        """

        let snapshot = try CodexUsageParser.parse(
            data: Data(json.utf8),
            providerId: "codex",
            displayName: "Codex",
            fetchedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.groups.map(\.title), ["Codex", "GPT-5.3-Codex-Spark"])
        XCTAssertEqual(snapshot.groups[0].items.map(\.label), ["5h", "7d"])
        XCTAssertEqual(snapshot.groups[0].items[0].remainingPercent, 48)
        XCTAssertEqual(snapshot.groups[0].items[0].windowDurationMinutes, 300)
        XCTAssertEqual(snapshot.groups[0].items[0].resetAt, Date(timeIntervalSince1970: 1_782_940_713))
        XCTAssertEqual(snapshot.groups[0].items[1].remainingPercent, 67)
        XCTAssertEqual(snapshot.groups[0].items[1].windowDurationMinutes, 10_080)
        XCTAssertEqual(snapshot.groups[1].items[0].remainingPercent, 100)
        XCTAssertEqual(snapshot.groups[1].items[1].remainingPercent, 100)
    }

    func testLabelsFollowWindowDurationWhenPrimaryBecomesWeekly() throws {
        // 2026-07 Codex 取消 5h 窗口：primary 直接是周窗口、secondary 为 null。
        // 标签必须跟着 windowDurationMins 走，不能再把 primary 硬标成「5h」。
        let json = """
        {
          "rateLimitsByLimitId": {
            "codex": {
              "limitId": "codex",
              "limitName": null,
              "primary": {
                "usedPercent": 22,
                "resetsAt": 1784487810,
                "windowDurationMins": 10080
              },
              "secondary": null
            }
          }
        }
        """

        let snapshot = try CodexUsageParser.parse(
            data: Data(json.utf8),
            providerId: "codex",
            displayName: "Codex",
            fetchedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(snapshot.groups.map(\.title), ["Codex"])
        XCTAssertEqual(snapshot.groups[0].items.map(\.label), ["7d"])
        XCTAssertEqual(snapshot.groups[0].items[0].remainingPercent, 78)
    }

    func testWindowLabelFormatsArbitraryDurations() {
        XCTAssertEqual(CodexUsageParser.windowLabel(minutes: 300), "5h")
        XCTAssertEqual(CodexUsageParser.windowLabel(minutes: 10_080), "7d")
        XCTAssertEqual(CodexUsageParser.windowLabel(minutes: 1_440), "1d")
        XCTAssertEqual(CodexUsageParser.windowLabel(minutes: 90), "90m")
        XCTAssertEqual(CodexUsageParser.windowLabel(minutes: nil), "额度")
    }

    func testExecutableSearchCoversStandaloneInstallLocation() throws {
        // 只装桌面版/PATH 没配好的用户：standalone 固定装点必须在候选目录里，
        // 全部落空时错误文案才会指向「缺 CLI」而不是模糊的取数失败。
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-search-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        XCTAssertFalse(CodexUsageProvider.codexExecutableExists(homeDirectory: home.path))

        let bin = home.appendingPathComponent(".codex/packages/standalone/current/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let codex = bin.appendingPathComponent("codex")
        try "#!/bin/sh\n".write(to: codex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)

        XCTAssertTrue(CodexUsageProvider.codexExecutableExists(homeDirectory: home.path))
        XCTAssertTrue(
            CodexUsageProvider.executableSearchPath(homeDirectory: home.path)
                .contains(".codex/packages/standalone/current/bin")
        )
    }

    func testResetCreditsParserReadsIssuedAndExpiresDates() throws {
        let json = """
        {
          "credits": [
            {
              "id": "redacted-for-test",
              "granted_at": "2026-06-18T00:32:44Z",
              "expires_at": "2026-07-18T00:32:44Z"
            }
          ]
        }
        """

        let summary = try CodexResetCreditsParser.parse(data: Data(json.utf8))

        XCTAssertEqual(summary.availableCount, 1)
        XCTAssertEqual(summary.credits.count, 1)
        XCTAssertEqual(summary.credits[0].issuedAt, ISO8601DateFormatter().date(from: "2026-06-18T00:32:44Z"))
        XCTAssertEqual(summary.credits[0].expiresAt, ISO8601DateFormatter().date(from: "2026-07-18T00:32:44Z"))
    }
}
