import XCTest
@testable import TokenMeterCore

@MainActor
final class CodexAccountClientTests: XCTestCase {
    func testReadAndConsumeUseRealProtocolBridgeWithFakeServer() async throws {
        let fixture = try AccountBridgeFixture()
        defer { fixture.remove() }
        let account = try await fixture.client.read()
        XCTAssertEqual(account.availableCount, 3)
        XCTAssertEqual(account.displayCredits?.availableCount, 3)
        XCTAssertEqual(account.displayCredits?.credits.count, 1)
        XCTAssertEqual(account.credits?.first?.grantedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(account.credits?.first?.isEligible(at: Date()), true)
        let cachedDisplay = String(decoding: try JSONEncoder().encode(account.displayCredits), as: UTF8.self)
        XCTAssertFalse(cachedDisplay.contains("test-credit"))
        let fingerprint = try XCTUnwrap(account.accountFingerprint)
        let outcome = try await fixture.client.consume(creditID: "test-credit", idempotencyKey: "same-attempt", accountFingerprint: fingerprint)
        XCTAssertEqual(outcome, .reset)
        let requests = try fixture.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?["creditId"] as? String, "test-credit")
        XCTAssertEqual(requests.first?["idempotencyKey"] as? String, "same-attempt")
    }

    func testChangedAccountCannotConsume() async throws {
        let fixture = try AccountBridgeFixture()
        defer { fixture.remove() }
        do {
            _ = try await fixture.client.consume(creditID: "test-credit", idempotencyKey: "attempt", accountFingerprint: "other-account")
            XCTFail("Account mismatch must fail")
        } catch {}
        XCTAssertTrue(try fixture.requests().isEmpty)
    }

    func testOldServerWithoutCreditSelectionCannotConsume() async throws {
        let fixture = try AccountBridgeFixture()
        defer { fixture.remove() }
        try "unsupported".write(to: fixture.root.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
        let account = try await fixture.client.read()
        do {
            _ = try await fixture.client.consume(creditID: "test-credit", idempotencyKey: "attempt", accountFingerprint: try XCTUnwrap(account.accountFingerprint))
            XCTFail("Missing credit selection must fail closed")
        } catch {}
        XCTAssertTrue(try fixture.requests().isEmpty)
    }

    func testExpiredOrUnavailableCreditCannotConsume() async throws {
        for mode in ["expired", "unavailable"] {
            let fixture = try AccountBridgeFixture()
            defer { fixture.remove() }
            try mode.write(to: fixture.root.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
            let account = try await fixture.client.read()
            _ = try? await fixture.client.consume(creditID: "test-credit", idempotencyKey: "attempt", accountFingerprint: try XCTUnwrap(account.accountFingerprint))
            XCTAssertTrue(try fixture.requests().isEmpty)
        }
    }

    func testCancellationWhileReadingStopsBeforeConsumption() async throws {
        let fixture = try AccountBridgeFixture()
        defer { fixture.remove() }
        let account = try await fixture.client.read()
        try "slow".write(to: fixture.root.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
        let task = Task { try await fixture.client.consume(creditID: "test-credit", idempotencyKey: "attempt", accountFingerprint: try XCTUnwrap(account.accountFingerprint)) }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("waiting").path) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("waiting").path))
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled request must not succeed") } catch {}
        XCTAssertTrue(try fixture.requests().isEmpty)
    }

    func testMissingDetailsAndUnknownStatusesCannotBeRedeemed() throws {
        let data = Data(#"{"limits":{"rateLimits":{},"rateLimitResetCredits":{"availableCount":4,"credits":null}}}"#.utf8)
        let state = try CodexAccountState.parse(data)
        XCTAssertEqual(state.availableCount, 4)
        XCTAssertNil(state.credits)
        XCTAssertEqual(state.displayCredits?.availableCount, 4)
        XCTAssertNil(state.accountFingerprint)
    }
}

@MainActor
private struct AccountBridgeFixture {
    let root: URL
    let client: CodexAccountClient

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-bridge-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let payload = Data(#"{"sub":"test-user"}"#.utf8).base64EncodedString()
        let auth: [String: Any] = ["tokens": ["account_id": "test-account", "id_token": "test.\(payload).signature"]]
        try JSONSerialization.data(withJSONObject: auth).write(to: root.appendingPathComponent("auth.json"))
        let executable = root.appendingPathComponent("codex")
        try Self.server.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        client = CodexAccountClient(home: root, searchPath: root.path + ":" + CodexUsageProvider.executableSearchPath())
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func requests() throws -> [[String: Any]] {
        let file = root.appendingPathComponent("consumed.jsonl")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try String(contentsOf: file).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    static let server = #"""
    #!/usr/bin/env node
    const fs = require('fs'), path = require('path'), readline = require('readline');
    const home = process.env.CODEX_HOME;
    const mode = fs.existsSync(path.join(home, 'mode')) ? fs.readFileSync(path.join(home, 'mode'), 'utf8') : '';
    if (process.argv.includes('generate-json-schema')) {
      const out = process.argv[process.argv.indexOf('--out') + 1];
      fs.mkdirSync(path.join(out, 'v2'), { recursive: true });
      fs.writeFileSync(path.join(out, 'v2/ConsumeAccountRateLimitResetCreditParams.json'), JSON.stringify({ properties: mode === 'unsupported' ? {} : { creditId: {}, idempotencyKey: {} } }));
      process.exit(0);
    }
    readline.createInterface({ input: process.stdin }).on('line', line => {
      const m = JSON.parse(line);
      const reply = result => process.stdout.write(JSON.stringify({ id: m.id, result }) + '\n');
      if (m.method === 'initialize') reply({});
      if (m.method === 'account/read') reply({ account: { type: 'chatgpt' } });
      if (m.method === 'account/rateLimits/read') {
        const result = { rateLimits: {}, rateLimitResetCredits: { availableCount: 3, credits: [{ id: 'test-credit', resetType: 'codexRateLimits', status: mode === 'unavailable' ? 'consumed' : 'available', grantedAt: 1700000000, expiresAt: Math.floor(Date.now() / 1000) + (mode === 'expired' ? -1 : 1800) }] } };
        if (mode === 'slow') { fs.writeFileSync(path.join(home, 'waiting'), 'yes'); setTimeout(() => reply(result), 3000); }
        else reply(result);
      }
      if (m.method === 'account/rateLimitResetCredit/consume') {
        fs.appendFileSync(path.join(home, 'consumed.jsonl'), JSON.stringify(m.params) + '\n');
        reply({ outcome: 'reset' });
      }
    });
    """#
}
