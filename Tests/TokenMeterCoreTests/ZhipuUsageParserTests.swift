import XCTest
@testable import TokenMeterCore

final class ZhipuUsageParserTests: XCTestCase {
    func testParsesCommonQuotaShape() throws {
        let json = """
        {
          "data": {
            "used": 12.5,
            "remaining": 87.5,
            "total": 100
          }
        }
        """

        let snapshot = try ZhipuUsageParser.parse(
            data: Data(json.utf8),
            providerId: "zhipu",
            displayName: "智谱"
        )

        XCTAssertEqual(snapshot.providerId, "zhipu")
        XCTAssertEqual(snapshot.displayName, "智谱")
        XCTAssertEqual(snapshot.used, 12.5)
        XCTAssertEqual(snapshot.remaining, 87.5)
        XCTAssertEqual(snapshot.total, 100)
        XCTAssertEqual(snapshot.unit, "CNY")
    }

    func testParsesAlternativeQuotaKeys() throws {
        let json = """
        {
          "quota": {
            "used_quota": 2000,
            "remain_quota": 3000,
            "total_quota": 5000
          }
        }
        """

        let snapshot = try ZhipuUsageParser.parse(
            data: Data(json.utf8),
            providerId: "zhipu",
            displayName: "智谱"
        )

        XCTAssertEqual(snapshot.used, 2000)
        XCTAssertEqual(snapshot.remaining, 3000)
        XCTAssertEqual(snapshot.total, 5000)
    }

    func testThrowsWhenBusinessResponseIsFailure() throws {
        let json = """
        {
          "code": 1001,
          "msg": "Header中未收到Authorization参数，无法进行身份验证。",
          "success": false
        }
        """

        XCTAssertThrowsError(
            try ZhipuUsageParser.parse(
                data: Data(json.utf8),
                providerId: "zhipu",
                displayName: "智谱"
            )
        )
    }

    func testParsesLiveCodingPlanLimitsShape() throws {
        let json = """
        {
          "code": 200,
          "msg": "操作成功",
          "data": {
            "limits": [
              {
                "type": "TIME_LIMIT",
                "unit": 5,
                "number": 1,
                "usage": 4000,
                "currentValue": 140,
                "remaining": 3860,
                "percentage": 3,
                "nextResetTime": 1784359374998
              },
              {
                "type": "TOKENS_LIMIT",
                "unit": 3,
                "number": 5,
                "percentage": 26,
                "nextResetTime": 1782936132385
              },
              {
                "type": "TOKENS_LIMIT",
                "unit": 6,
                "number": 1,
                "percentage": 86,
                "nextResetTime": 1782976974977
              }
            ],
            "level": "max"
          },
          "success": true
        }
        """

        let snapshot = try ZhipuUsageParser.parse(
            data: Data(json.utf8),
            providerId: "zhipu",
            displayName: "智谱"
        )

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.remaining, 74)
        XCTAssertEqual(snapshot.message, "5h 74% · Weekly 14% · MCP 97%")
        XCTAssertEqual(snapshot.unit, "%")
    }

    func testParsesLiveCodingPlanLimitsAsSeparateMetrics() throws {
        let json = """
        {
          "code": 200,
          "msg": "操作成功",
          "data": {
            "limits": [
              {
                "type": "TIME_LIMIT",
                "unit": 5,
                "usage": 4000,
                "currentValue": 140,
                "remaining": 3860,
                "percentage": 3,
                "nextResetTime": 1784359374998
              },
              {
                "type": "TOKENS_LIMIT",
                "unit": 3,
                "percentage": 26,
                "nextResetTime": 1782936132385
              },
              {
                "type": "TOKENS_LIMIT",
                "unit": 6,
                "percentage": 86,
                "nextResetTime": 1782976974977
              }
            ],
            "level": "max"
          },
          "success": true
        }
        """

        let snapshot = try ZhipuUsageParser.parseProviderUsage(
            data: Data(json.utf8),
            providerId: "zhipu",
            displayName: "智谱",
            fetchedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.groups.count, 1)
        XCTAssertEqual(snapshot.groups[0].title, "智谱 Coding Plan")
        XCTAssertEqual(snapshot.groups[0].items.map(\.label), ["5h", "7d", "MCP"])
        XCTAssertEqual(snapshot.groups[0].items.map(\.remainingPercent), [74, 14, 97])
        XCTAssertEqual(snapshot.groups[0].items[0].windowDurationMinutes, 300)
        XCTAssertEqual(snapshot.groups[0].items[1].windowDurationMinutes, 10_080)
        XCTAssertEqual(snapshot.groups[0].items[2].detail, "140/4000 次")
    }
}
