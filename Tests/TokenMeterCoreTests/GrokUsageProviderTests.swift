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

    func testSpawnTimesOutWhenChildWritesNothing() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("grok-spawn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let stub = try writeExecutable("exec /bin/sleep 86400")
        defer { try? FileManager.default.removeItem(at: stub) }

        let started = Date()
        XCTAssertThrowsError(
            try GrokUsageProvider.spawnBilling(executable: stub.path, grokHome: home, timeout: 0.4)
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("命令超时"),
                "got \(error.localizedDescription)"
            )
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testSpawnRPCErrorSurfacesMessage() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("grok-rpc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let stub = try writeExecutable(
            """
            cat >/dev/null
            printf '%s\\n' '{"jsonrpc":"2.0","id":2,"error":{"message":"weekly limit"}}'
            """
        )
        defer { try? FileManager.default.removeItem(at: stub) }

        XCTAssertThrowsError(
            try GrokUsageProvider.spawnBilling(executable: stub.path, grokHome: home, timeout: 2)
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.lowercased().contains("weekly limit"),
                "got \(error.localizedDescription)"
            )
        }
    }

    func testSpawnRPCWeeklyLimitIsQuotaExhausted() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("grok-quota-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"https://auth.x.ai::abc":{"key":"secret","expires_at":"2099-01-01T00:00:00Z"}}"#.utf8)
            .write(to: home.appendingPathComponent("auth.json"))
        let stub = try writeExecutable(
            """
            cat >/dev/null
            printf '%s\\n' '{"jsonrpc":"2.0","id":2,"error":{"message":"weekly limit"}}'
            """
        )
        defer { try? FileManager.default.removeItem(at: stub) }

        let provider = GrokUsageProvider(
            config: config(),
            grokHome: home,
            grokExecutable: { stub.path }
        )
        let snapshot = await provider.fetchProviderUsage()
        XCTAssertEqual(snapshot.status, .error)
        XCTAssertEqual(snapshot.message, "额度用尽")
    }

    private func writeExecutable(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grok-stub-\(UUID().uuidString)")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
