import XCTest
@testable import TokenMeterCore

final class GrokUsageProviderTests: XCTestCase {
    private func config() -> ProviderConfig {
        ProviderConfig(
            id: "grok",
            type: .grok,
            displayName: "Grok Build",
            enabled: true,
            credential: nil,
            endpoint: nil,
            manualUsage: nil
        )
    }

    func testMissingBinaryMessage() async {
        let provider = GrokUsageProvider(
            config: config(),
            grokHome: URL(fileURLWithPath: "/tmp/missing-grok-home"),
            grokExecutable: { nil }
        )
        let snapshot = await provider.fetchProviderUsage()
        XCTAssertEqual(snapshot.status, .error)
        XCTAssertTrue(snapshot.message?.contains("未检测到 Grok 命令行") == true)
    }

    func testMissingAuthMessageDoesNotContainToken() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("grok-auth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let provider = GrokUsageProvider(
            config: config(),
            grokHome: home,
            grokExecutable: { "/usr/bin/true" }
        )
        let snapshot = await provider.fetchProviderUsage()
        XCTAssertTrue(snapshot.message?.contains("未登录 Grok Build") == true)
        XCTAssertFalse(snapshot.message?.contains("eyJ") == true)
        XCTAssertFalse(snapshot.message?.contains("Bearer") == true)
    }

    func testExpiredAuthIsLoggedOut() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("grok-auth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let json = """
        {"https://auth.x.ai::abc":{"key":"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.aaa","expires_at":"2020-01-01T00:00:00Z"}}
        """
        try Data(json.utf8).write(to: home.appendingPathComponent("auth.json"))
        let provider = GrokUsageProvider(
            config: config(),
            grokHome: home,
            grokExecutable: { "/usr/bin/true" },
            now: { ISO8601DateFormatter().date(from: "2026-08-26T00:00:00Z")! }
        )
        let snapshot = await provider.fetchProviderUsage()
        XCTAssertTrue(snapshot.message?.contains("未登录") == true)
        XCTAssertFalse(snapshot.message?.contains("eyJ") == true)
    }

    func testUsableAuthParsesBillingViaInjectedFetch() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("grok-auth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let json = """
        {"https://auth.x.ai::abc":{"key":"secret","expires_at":"2099-01-01T00:00:00Z"}}
        """
        try Data(json.utf8).write(to: home.appendingPathComponent("auth.json"))
        let provider = GrokUsageProvider(
            config: config(),
            grokHome: home,
            grokExecutable: { "/usr/bin/true" },
            fetchBilling: { Data(#"{"creditUsagePercent":3}"#.utf8) }
        )
        let snapshot = await provider.fetchProviderUsage()
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.groups[0].items[0].usedPercent, 3)
        XCTAssertEqual(snapshot.groups[0].items[0].label, "7d")
    }
}
