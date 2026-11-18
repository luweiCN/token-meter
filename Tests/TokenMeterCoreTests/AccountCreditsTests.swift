import XCTest
@testable import TokenMeterCore

final class AccountCreditsTests: XCTestCase {
    func testCodexDistinguishesAmountsFlagsAndUnavailableValues() {
        XCTAssertEqual(CodexCreditBalance.parse(["balance": "0", "hasCredits": false]), .amount(0))
        XCTAssertEqual(CodexCreditBalance.parse(["balance": "-1.125", "hasCredits": false]), .amount(-1.125))
        XCTAssertEqual(CodexCreditBalance.parse(["balance": "9", "unlimited": true]), .unlimited)
        XCTAssertEqual(CodexCreditBalance.parse(["balance": NSNull(), "hasCredits": true]), .available)
        XCTAssertEqual(CodexCreditBalance.parse(["hasCredits": false]), .noCredits)
        XCTAssertEqual(CodexCreditBalance.parse(["balance": "123unknown"]), .unavailable)
        XCTAssertEqual(CodexCreditBalance.parse(nil), .unavailable)
    }

    func testCodexWalletWorksWithoutWindowsAndDoesNotUseModelBuckets() throws {
        let onlyWallet = Data(#"{"rateLimits":{"credits":{"balance":"12.375"}}}"#.utf8)
        let snapshot = try CodexUsageParser.parse(data: onlyWallet, providerId: "codex", displayName: "Codex")
        XCTAssertEqual(snapshot.renamed(to: "工作").accountCredits, .codex(.amount(12.375)))
        XCTAssertEqual(snapshot.withResetCredits(.init(availableCount: 2, credits: [])).accountCredits, snapshot.accountCredits)
        let buckets = Data(#"{"rateLimitsByLimitId":{"spark":{"credits":{"balance":"999"}},"codex":{"credits":{"balance":"3"}}}}"#.utf8)
        XCTAssertEqual(try CodexUsageParser.parse(data: buckets, providerId: "codex", displayName: "Codex").accountCredits, .codex(.amount(3)))
        let modelOnly = Data(#"{"rateLimitsByLimitId":{"spark":{"credits":{"balance":"999"}}}}"#.utf8)
        XCTAssertThrowsError(try CodexUsageParser.parse(data: modelOnly, providerId: "codex", displayName: "Codex"))
    }

    func testClaudeAmountsFollowCurrencyAndKeepMissingFieldsUnknown() throws {
        XCTAssertEqual(ClaudeCreditAmount.prepaid(from: Data(#"{"amount":0,"currency":"usd"}"#.utf8))?.value, 0)
        XCTAssertEqual(ClaudeCreditAmount.prepaid(from: Data(#"{"amount":750,"currency":"JPY"}"#.utf8))?.value, 750)
        XCTAssertNil(ClaudeCreditAmount.prepaid(from: Data(#"{"amount":750}"#.utf8)))
        XCTAssertNil(ClaudeCreditAmount.prepaid(from: Data(#"{"amount":true,"currency":"USD"}"#.utf8)))
        let legacy = try XCTUnwrap(ClaudeExtraUsage.parse(["is_enabled": true, "used_credits": 305]))
        XCTAssertEqual(legacy.used?.currency, "USD")
        XCTAssertEqual(legacy.used?.value, 3.05)
        XCTAssertNil(legacy.monthlyLimit)
        let disabled = try XCTUnwrap(ClaudeExtraUsage.parse(["is_enabled": false, "used_credits": NSNull()]))
        XCTAssertEqual(disabled.enabled, false)
        XCTAssertNil(disabled.used)
    }

    func testClaudeReadsBudgetAndPrepaidIndependentlyAndUsesAuthenticatedOrg() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ClaudeAccountProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let claude = try XCTUnwrap(ProviderConfigLoader.defaultConfig().providers.first { $0.type == .claudeCode })
        let provider = ClaudeCodeUsageProvider(config: claude, urlSession: session)
        for token in ["both", "no-wallet", "no-profile", "no-usage"] {
            let result = await provider.fetchAccountUsage(token: token)
            guard case let .claude(wallet, budget) = result.accountCredits else { return XCTFail("缺少账户状态") }
            XCTAssertEqual(wallet?.value, ["both", "no-usage"].contains(token) ? 18.5 : nil)
            XCTAssertEqual(budget?.used?.value, token == "no-usage" ? nil : 6)
            XCTAssertEqual(budget?.monthlyLimit?.value, token == "no-usage" ? nil : 25)
            XCTAssertEqual(result.groups.first?.items.first?.remainingPercent, token == "no-usage" ? nil : 70)
        }
    }

    func testCacheKeepsWindowsButClearsUnverifiedWallets() throws {
        let provider = "codex"
        let data = Data(#"{"rateLimits":{"primary":{"usedPercent":40,"windowDurationMins":300},"credits":{"balance":"18"}}}"#.utf8)
        let previous = try CodexUsageParser.parse(data: data, providerId: provider, displayName: "Codex")
        let failure = providerErrorSnapshot(providerId: provider, displayName: "Codex", message: "无法查询", accountCredits: .codex(.unavailable))
        let merged = try XCTUnwrap(ProviderSnapshotCache.merge(previous: [previous], refreshed: [failure]).first)
        XCTAssertEqual(merged.groups, previous.groups)
        XCTAssertEqual(merged.accountCredits, .codex(.unavailable))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("snapshots.json")
        try ProviderSnapshotDiskCache.write([previous], to: url)
        XCTAssertEqual(try ProviderSnapshotDiskCache.read(from: url).first?.accountCredits, .codex(.unavailable))
        let legacy = Data(#"{"providerId":"codex","displayName":"Codex","status":"ok","fetchedAt":0,"groups":[]}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ProviderUsageSnapshot.self, from: legacy).accountCredits)
    }

    func testOnePersistedBalancePinCanBeReplacedAndCleared() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)
        let store = SettingsStore(database: database)
        XCTAssertNil(try store.snapshot().menuBarAppearance.pinnedBalanceProviderId)
        var version = try store.snapshot().version
        for id: String? in ["codex", "claude-code", nil] {
            try store.setPinnedBalanceProvider(id)
            let saved = try SettingsStore(database: database).snapshot()
            XCTAssertEqual(saved.menuBarAppearance.pinnedBalanceProviderId, id)
            XCTAssertEqual(saved.version, version + 1)
            version = saved.version
        }
    }
}

private final class ClaudeAccountProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let org = "a1111111-b222-c333-d444-e55555555555"
        let url = request.url!
        let token = request.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(url.host, "api.anthropic.com")
        XCTAssertEqual(request.httpMethod, "GET")
        let status: Int
        let body: String
        switch url.path {
        case "/api/oauth/usage":
            status = token == "Bearer no-usage" ? 503 : 200
            body = #"{"five_hour":{"utilization":30},"extra_usage":{"is_enabled":true,"used_credits":600,"monthly_limit":2500,"currency":"USD"}}"#
        case "/api/oauth/profile":
            status = 200
            body = token == "Bearer no-profile" ? "{}" : #"{"organization":{"uuid":"\#(org)"}}"#
        case "/api/oauth/organizations/\(org)/prepaid/credits":
            XCTAssertNotEqual(token, "Bearer no-profile")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-organization-uuid"), org)
            status = token == "Bearer no-wallet" ? 403 : 200
            body = #"{"amount":1850,"currency":"USD"}"#
        default:
            XCTFail("未知账户查询")
            status = 404
            body = "{}"
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
