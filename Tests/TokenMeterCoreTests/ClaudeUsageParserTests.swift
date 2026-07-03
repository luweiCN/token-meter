import XCTest
@testable import TokenMeterCore

final class ClaudeUsageParserTests: XCTestCase {
    func testParsesBaseAndSonnetUsage() throws {
        let json = """
        {
          "five_hour": {
            "utilization": 12.5,
            "resets_at": "2026-07-02T08:10:00Z"
          },
          "seven_day": {
            "utilization": 87,
            "resets_at": "2026-07-06T08:10:00Z"
          },
          "seven_day_sonnet": {
            "utilization": 44,
            "resets_at": "2026-07-06T08:10:00Z"
          },
          "seven_day_fable": {
            "utilization": 30,
            "resets_at": "2026-07-06T08:10:00Z"
          },
          "seven_day_opus": null
        }
        """

        let snapshot = try ClaudeUsageParser.parse(
            data: Data(json.utf8),
            providerId: "claude-code",
            displayName: "Claude Code",
            fetchedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.groups.map(\.title), ["Claude Code", "Sonnet", "Fable"])
        XCTAssertEqual(snapshot.groups[0].items.map(\.label), ["5h", "7d"])
        XCTAssertEqual(snapshot.groups[0].items[0].remainingPercent, 87.5)
        XCTAssertEqual(snapshot.groups[0].items[0].windowDurationMinutes, 300)
        XCTAssertNotNil(snapshot.groups[0].items[0].resetAt)
        XCTAssertEqual(snapshot.groups[0].items[1].remainingPercent, 13)
        XCTAssertEqual(snapshot.groups[0].items[1].windowDurationMinutes, 10_080)
        XCTAssertEqual(snapshot.groups[1].items.map(\.label), ["7d"])
        XCTAssertEqual(snapshot.groups[1].items[0].remainingPercent, 56)
        XCTAssertEqual(snapshot.groups[1].items[0].windowDurationMinutes, 10_080)
        XCTAssertEqual(snapshot.groups[2].items.map(\.label), ["7d"])
        XCTAssertEqual(snapshot.groups[2].items[0].remainingPercent, 70)
        XCTAssertEqual(snapshot.groups[2].items[0].windowDurationMinutes, 10_080)
    }

    func testParsesScopedWeeklyModelLimitsFromLimitsArray() throws {
        let json = """
        {
          "five_hour": {
            "utilization": 47,
            "resets_at": "2026-07-02T02:09:59Z"
          },
          "seven_day": {
            "utilization": 5,
            "resets_at": "2026-07-02T05:59:59Z"
          },
          "limits": [
            {
              "kind": "session",
              "group": "session",
              "percent": 47,
              "resets_at": "2026-07-02T02:09:59Z",
              "scope": null
            },
            {
              "kind": "weekly_all",
              "group": "weekly",
              "percent": 5,
              "resets_at": "2026-07-02T05:59:59Z",
              "scope": null
            },
            {
              "kind": "weekly_scoped",
              "group": "weekly",
              "percent": 9,
              "resets_at": "2026-07-02T05:59:59Z",
              "scope": {
                "model": {
                  "display_name": "Fable"
                },
                "surface": null
              }
            }
          ]
        }
        """

        let snapshot = try ClaudeUsageParser.parse(
            data: Data(json.utf8),
            providerId: "claude-code",
            displayName: "Claude Code",
            fetchedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(snapshot.groups.map(\.title), ["Claude Code", "Fable"])
        XCTAssertEqual(snapshot.groups.count, 2)
        guard snapshot.groups.count == 2 else {
            return
        }
        XCTAssertEqual(snapshot.groups[1].items[0].label, "7d")
        XCTAssertEqual(snapshot.groups[1].items[0].remainingPercent, 91)
        XCTAssertEqual(snapshot.groups[1].items[0].windowDurationMinutes, 10_080)
        XCTAssertNotNil(snapshot.groups[1].items[0].resetAt)
    }
}
