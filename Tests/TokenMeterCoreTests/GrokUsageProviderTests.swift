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
        XCTAssertTrue(snapshot.message?.contains("未登录") == true)
        XCTAssertTrue(snapshot.message?.contains("grok login") == true)
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
        let stub = try writeACPStub(
            """
            import json,sys
            for line in sys.stdin:
                msg=json.loads(line)
                rid=msg.get("id")
                method=msg.get("method")
                if method in ("initialize","authenticate"):
                    print(json.dumps({"jsonrpc":"2.0","id":rid,"result":{}}), flush=True)
                else:
                    print(json.dumps({"jsonrpc":"2.0","id":rid,"error":{"message":"weekly limit"}}), flush=True)
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

    func testSpawnPrefersUnderscorePrefixedBilling() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("grok-uscore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let stub = try writeACPStub(
            """
            import json,sys
            for line in sys.stdin:
                msg=json.loads(line)
                method=msg.get("method")
                rid=msg.get("id")
                if method=="initialize":
                    print(json.dumps({"jsonrpc":"2.0","id":rid,"result":{"protocolVersion":1}}), flush=True)
                elif method=="authenticate":
                    print(json.dumps({"jsonrpc":"2.0","id":rid,"result":{}}), flush=True)
                elif method=="x.ai/billing":
                    print(json.dumps({"jsonrpc":"2.0","id":rid,"error":{"code":-32601,"message":"Method not found"}}), flush=True)
                elif method=="_x.ai/billing":
                    print(json.dumps({"jsonrpc":"2.0","id":rid,"result":{"config":{"creditUsagePercent":12}}}), flush=True)
            """
        )
        defer { try? FileManager.default.removeItem(at: stub) }

        let data = try GrokUsageProvider.spawnBilling(executable: stub.path, grokHome: home, timeout: 3)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let percent = (object?["config"] as? [String: Any])?["creditUsagePercent"] as? Double
            ?? (object?["creditUsagePercent"] as? Double)
        XCTAssertEqual(percent, 12)
    }

    func testACPMethodNotFoundFallsBackToREST() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("grok-rest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"https://auth.x.ai::abc":{"key":"secret","expires_at":"2099-01-01T00:00:00Z"}}"#.utf8)
            .write(to: home.appendingPathComponent("auth.json"))

        let provider = GrokUsageProvider(
            config: config(),
            grokHome: home,
            grokExecutable: { "/usr/bin/true" },
            fetchBilling: { throw GrokSpawnError.rpc("Method not found") },
            fetchREST: { token in
                XCTAssertEqual(token, "secret")
                return Data(#"{"config":{"creditUsagePercent":51}}"#.utf8)
            }
        )
        let snapshot = await provider.fetchProviderUsage()
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.groups[0].items[0].usedPercent, 51)
    }

    func testRESTFailureFallsBackToGRPC() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("grok-grpc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"https://auth.x.ai::abc":{"key":"secret","expires_at":"2099-01-01T00:00:00Z"}}"#.utf8)
            .write(to: home.appendingPathComponent("auth.json"))

        let provider = GrokUsageProvider(
            config: config(),
            grokHome: home,
            grokExecutable: { "/usr/bin/true" },
            fetchBilling: { throw GrokSpawnError.rpc("Method not found") },
            fetchREST: { _ in throw GrokSpawnError.noResult },
            fetchGRPC: { token in
                XCTAssertEqual(token, "secret")
                return Data(#"{"creditUsagePercent":40}"#.utf8)
            }
        )
        let snapshot = await provider.fetchProviderUsage()
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.groups[0].items[0].usedPercent, 40)
    }

    func testHTTPUnauthorizedIsLoginErrorWithoutTokenLeak() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("grok-401-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"https://auth.x.ai::abc":{"key":"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.aaa","expires_at":"2099-01-01T00:00:00Z"}}"#.utf8)
            .write(to: home.appendingPathComponent("auth.json"))

        let provider = GrokUsageProvider(
            config: config(),
            grokHome: home,
            grokExecutable: { "/usr/bin/true" },
            fetchBilling: { throw GrokSpawnError.rpc("Method not found") },
            fetchREST: { _ in throw GrokSpawnError.unauthorized },
            fetchGRPC: { _ in throw GrokSpawnError.unauthorized }
        )
        let snapshot = await provider.fetchProviderUsage()
        XCTAssertEqual(snapshot.status, .error)
        XCTAssertTrue(snapshot.message?.contains("未登录") == true)
        XCTAssertTrue(snapshot.message?.contains("grok login") == true)
        XCTAssertFalse(snapshot.message?.contains("eyJ") == true)
    }

    func testSpawnRPCWeeklyLimitIsQuotaExhausted() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("grok-quota-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"https://auth.x.ai::abc":{"key":"secret","expires_at":"2099-01-01T00:00:00Z"}}"#.utf8)
            .write(to: home.appendingPathComponent("auth.json"))
        let stub = try writeACPStub(
            """
            import json,sys
            for line in sys.stdin:
                msg=json.loads(line)
                rid=msg.get("id")
                method=msg.get("method")
                if method in ("initialize","authenticate"):
                    print(json.dumps({"jsonrpc":"2.0","id":rid,"result":{}}), flush=True)
                else:
                    print(json.dumps({"jsonrpc":"2.0","id":rid,"error":{"message":"weekly limit"}}), flush=True)
            """
        )
        defer { try? FileManager.default.removeItem(at: stub) }

        let provider = GrokUsageProvider(
            config: config(),
            grokHome: home,
            grokExecutable: { stub.path },
            fetchREST: { _ in throw GrokSpawnError.noResult },
            fetchGRPC: { _ in throw GrokSpawnError.noResult }
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

    private func writeACPStub(_ python: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grok-acp-\(UUID().uuidString)")
        let body = "#!/usr/bin/env python3\n\(python)\n"
        try Data(body.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
