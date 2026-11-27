import XCTest
@testable import TokenMeterCore

final class ProviderSnapshotDiskCacheTests: XCTestCase {
    func testReadsCLISnapshotsIncludingWalletWarningsAndResetCards() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(try ProviderSnapshotDiskCache.read(from: url).isEmpty)
        let input = #"""
        [
          {"providerId":"codex","displayName":"Codex","status":"warning","fetchedAt":"2026-11-24T12:00:00Z",
           "message":"网络暂时不可用","groups":[{"id":"codex","title":"Codex","items":[
             {"id":"weekly","label":"7d","kind":"quota","status":"ok","remainingPercent":55,"windowDurationMinutes":10080,"resetAt":"2026-11-25T00:00:00.125+08:00"}
           ]}],"accountCredits":{"codex":{"_0":{"amount":{"_0":51007.11399125}}}},
           "resetCredits":{"availableCount":1,"credits":[{"expiresAt":"2026-12-01T00:00:00Z"}]}},
          {"providerId":"claude-code","displayName":"Claude Code","status":"ok","fetchedAt":"2026-11-24T12:00:01Z",
           "groups":[],"accountCredits":{"claude":{"prepaid":{"value":18.50,"currency":"USD"},
             "extraUsage":{"enabled":true,"used":{"value":6,"currency":"USD"}}}}},
          {"providerId":"other","displayName":"Other","status":"error","fetchedAt":"2026-11-24T12:00:01Z","groups":[]}
        ]
        """#
        try Data(input.utf8).write(to: url)
        let snapshots = try ProviderSnapshotDiskCache.read(from: url)
        XCTAssertEqual(snapshots.count, 3)
        XCTAssertEqual(snapshots[0].message, "网络暂时不可用")
        XCTAssertEqual(snapshots[0].groups.first?.items.first?.remainingPercent, 55)
        let resetAt = try XCTUnwrap(snapshots[0].groups.first?.items.first?.resetAt)
        let base = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-24T16:00:00Z"))
        XCTAssertEqual(resetAt.timeIntervalSince(base), 0.125, accuracy: 0.001)
        XCTAssertEqual(snapshots[0].accountCredits, .codex(.amount(try XCTUnwrap(Decimal(string: "51007.11399125")))))
        XCTAssertEqual(snapshots[0].resetCredits?.credits.first?.expiresAt, ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z"))
        guard case let .claude(prepaid, usage) = snapshots[1].accountCredits else { return XCTFail("缺少 Claude 积分") }
        XCTAssertEqual(prepaid, ClaudeCreditAmount(value: 18.50, currency: "USD"))
        XCTAssertEqual(usage?.used?.value, 6)
        XCTAssertNil(snapshots[2].accountCredits)
    }
}
