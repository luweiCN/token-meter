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
