import Foundation
import XCTest
@testable import TokenMeterCore

final class CommandCodeUsageProviderTests: XCTestCase {
    override func tearDown() {
        CommandCodeMockURLProtocol.handler = nil
        super.tearDown()
    }

    func testParsesFiveHourWeeklyAndMonthlyQuota() throws {
        let snapshot = try CommandCodeUsageParser.parse(
            creditsData: Data(Self.creditsJSON.utf8),
            subscriptionData: Data(Self.subscriptionJSON.utf8),
            providerId: "command-code",
            displayName: "Command Code",
            now: Date(timeIntervalSince1970: 1_788_180_000)
        )

        XCTAssertEqual(snapshot.status, .ok)
        let metrics = try XCTUnwrap(snapshot.groups.first?.items)
        XCTAssertEqual(metrics.map(\.label), ["5h", "7d", "30d"])
        XCTAssertEqual(metrics.map(\.usedPercent), [25, 20, 20])
        XCTAssertEqual(metrics.map(\.remainingPercent), [75, 80, 80])
        XCTAssertEqual(metrics.map(\.windowDurationMinutes), [300, 10_080, 43_200])
        XCTAssertEqual(metrics[0].resetAt, Date(timeIntervalSince1970: 1_788_189_584.628))
        XCTAssertEqual(metrics[1].resetAt, Date(timeIntervalSince1970: 1_788_876_384.628))
        XCTAssertEqual(metrics[2].resetAt, ISO8601DateFormatter().date(from: "2026-09-30T10:15:17Z"))
        XCTAssertEqual(metrics[0].detail, "$3.50 / $14.00")
        XCTAssertEqual(metrics[2].detail, "套餐余额 $56.00 / $70.00 · 充值 $5.00 · 赠送 $2.00")
        XCTAssertEqual(snapshot.summary, "5h 75% · 7d 80% · 30d 80%")
    }

    func testUnknownPlanKeepsRollingWindowsWithoutInventingMonthlyPercent() throws {
        let subscription = Self.subscriptionJSON.replacingOccurrences(
            of: "individual-goat",
            with: "individual-future"
        )

        let snapshot = try CommandCodeUsageParser.parse(
            creditsData: Data(Self.creditsJSON.utf8),
            subscriptionData: Data(subscription.utf8),
            providerId: "command-code",
            displayName: "Command Code"
        )

        XCTAssertEqual(snapshot.groups.first?.items.map(\.label), ["5h", "7d"])
    }

    func testMissingSubscriptionResponseKeepsRollingWindows() throws {
        let snapshot = try CommandCodeUsageParser.parse(
            creditsData: Data(Self.creditsJSON.utf8),
            subscriptionData: nil,
            providerId: "command-code",
            displayName: "Command Code"
        )

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.groups.first?.items.map(\.label), ["5h", "7d"])
    }

    func testCredentialResolutionPrefersKeychainThenEnvironmentThenAuthFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let authURL = directory.appendingPathComponent("auth.json")
        try Data(#"{"apiKey":"file-key"}"#.utf8).write(to: authURL)
        let credential = CredentialConfig(environmentVariable: "COMMAND_CODE_API_KEY")

        XCTAssertEqual(
            CommandCodeCredentialResolver.resolve(
                providerId: "command-code",
                credential: credential,
                environment: ["COMMAND_CODE_API_KEY": "env-key"],
                authFileURL: authURL,
                keychainToken: { _ in "keychain-key" },
                loginShellValue: { _ in nil }
            ),
            "keychain-key"
        )
        XCTAssertEqual(
            CommandCodeCredentialResolver.resolve(
                providerId: "command-code",
                credential: credential,
                environment: ["COMMAND_CODE_API_KEY": "  \"env-key\"  "],
                authFileURL: authURL,
                keychainToken: { _ in nil },
                loginShellValue: { _ in nil }
            ),
            "env-key"
        )
        XCTAssertEqual(
            CommandCodeCredentialResolver.resolve(
                providerId: "command-code",
                credential: credential,
                environment: [:],
                authFileURL: authURL,
                keychainToken: { _ in nil },
                loginShellValue: { name in
                    XCTAssertEqual(name, "COMMAND_CODE_API_KEY")
                    return "shell-key"
                }
            ),
            "shell-key"
        )
        XCTAssertEqual(
            CommandCodeCredentialResolver.resolve(
                providerId: "command-code",
                credential: credential,
                environment: [:],
                authFileURL: authURL,
                keychainToken: { _ in nil },
                loginShellValue: { _ in nil }
            ),
            "file-key"
        )
    }

    func testFetchesQuotaWithEnvironmentAPIKeyWithoutCLI() async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [CommandCodeMockURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)

        CommandCodeMockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer env-key")
            switch request.url?.path {
            case "/alpha/whoami":
                return CommandCodeHTTPResponse(
                    statusCode: 200,
                    body: #"{"success":true,"user":{},"org":{"id":"org-1"}}"#
                )
            case "/alpha/billing/credits":
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                               [URLQueryItem(name: "orgId", value: "org-1")])
                return CommandCodeHTTPResponse(statusCode: 200, body: Self.creditsJSON)
            case "/alpha/billing/subscriptions":
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                               [URLQueryItem(name: "orgId", value: "org-1")])
                return CommandCodeHTTPResponse(statusCode: 200, body: Self.subscriptionJSON)
            default:
                return CommandCodeHTTPResponse(statusCode: 404, body: "{}")
            }
        }

        let provider = CommandCodeUsageProvider(
            config: ProviderConfig(
                id: "command-code",
                type: .commandCode,
                displayName: "Command Code",
                enabled: true,
                credential: CredentialConfig(environmentVariable: "COMMAND_CODE_API_KEY"),
                endpoint: "https://api.commandcode.ai",
                manualUsage: nil
            ),
            urlSession: session,
            environment: ["COMMAND_CODE_API_KEY": "env-key"],
            authFileURL: URL(fileURLWithPath: "/nonexistent/command-code-auth.json"),
            keychainToken: { _ in nil },
            loginShellValue: { _ in nil }
        )

        let snapshot = await provider.fetchProviderUsage()

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.groups.first?.items.map(\.label), ["5h", "7d", "30d"])
    }

    func testMissingAPIKeyReturnsActionableErrorWithoutMakingRequest() async {
        let provider = CommandCodeUsageProvider(
            config: ProviderConfig(
                id: "command-code",
                type: .commandCode,
                displayName: "Command Code",
                enabled: true,
                credential: CredentialConfig(environmentVariable: "COMMAND_CODE_API_KEY"),
                endpoint: "https://api.commandcode.ai",
                manualUsage: nil
            ),
            environment: [:],
            authFileURL: URL(fileURLWithPath: "/nonexistent/command-code-auth.json"),
            keychainToken: { _ in nil },
            loginShellValue: { _ in nil }
        )

        let snapshot = await provider.fetchProviderUsage()

        XCTAssertEqual(snapshot.status, .error)
        XCTAssertTrue(snapshot.message?.contains("API Key") == true)
        XCTAssertTrue(snapshot.message?.contains("设置页") == true)
    }

    private static let creditsJSON = #"""
    {
      "credits": {
        "monthlyCredits": 56,
        "purchasedCredits": 5,
        "freeCredits": 2,
        "belowThreshold": false,
        "creditThreshold": 1
      },
      "windowLimits": {
        "limited": true,
        "exceeded": null,
        "fiveHour": {
          "used": 3.5,
          "cap": 14,
          "exceeded": false,
          "resetAt": 1788189584628
        },
        "weekly": {
          "used": 7,
          "cap": 35,
          "exceeded": false,
          "resetAt": 1788876384628
        }
      }
    }
    """#

    private static let subscriptionJSON = #"""
    {
      "success": true,
      "data": {
        "planId": "individual-goat",
        "status": "active",
        "currentPeriodStart": "2026-08-31T10:15:17.000Z",
        "currentPeriodEnd": "2026-09-30T10:15:17.000Z"
      }
    }
    """#
}

private struct CommandCodeHTTPResponse {
    let statusCode: Int
    let body: String
}

private final class CommandCodeMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> CommandCodeHTTPResponse)?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                XCTFail("CommandCodeMockURLProtocol.handler is not configured")
                return
            }
            let mock = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: mock.statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(mock.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
