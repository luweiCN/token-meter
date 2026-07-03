import Foundation
import XCTest
@testable import TokenMeterCore

final class ZhipuUsageProviderTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testDoesNotUseFileCredentialWhenEnvironmentCredentialIsRejected() async throws {
        let credentialFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("token-meter-zhipu-good-key-\(UUID().uuidString)")
        try "good-key".write(to: credentialFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: credentialFile) }

        let config = ProviderConfig(
            id: "zhipu",
            type: .zhipu,
            displayName: "智谱",
            enabled: true,
            credential: CredentialConfig(
                environmentVariable: "ZHIPU_API_KEY",
                filePath: credentialFile.path
            ),
            endpoint: "https://bigmodel.cn/api/monitor/usage/quota/limit",
            manualUsage: nil
        )

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)

        var seenAuthorizationHeaders: [String] = []
        MockURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
            seenAuthorizationHeaders.append(authorization)

            if authorization == "bad-key" {
                return HTTPResponse(
                    statusCode: 200,
                    body: """
                    {
                      "code": 1000,
                      "msg": "身份验证失败。",
                      "success": false
                    }
                    """
                )
            }

            return HTTPResponse(
                statusCode: 200,
                body: """
                {
                  "code": 200,
                  "msg": "操作成功",
                  "data": {
                    "limits": [
                      { "type": "TOKENS_LIMIT", "unit": 3, "percentage": 26 },
                      { "type": "TOKENS_LIMIT", "unit": 6, "percentage": 87 },
                      { "type": "TIME_LIMIT", "unit": 5, "percentage": 3 }
                    ],
                    "level": "max"
                  },
                  "success": true
                }
                """
            )
        }

        let provider = ZhipuUsageProvider(
            config: config,
            urlSession: session,
            environment: ["ZHIPU_API_KEY": "bad-key"]
        )

        let snapshot = await provider.fetchUsage()

        XCTAssertEqual(snapshot.status, .error)
        XCTAssertEqual(snapshot.message, "身份验证失败。")
        XCTAssertEqual(seenAuthorizationHeaders, ["bad-key"])
    }

    func testStripsSurroundingQuotesFromEnvironmentCredential() async throws {
        let config = ProviderConfig(
            id: "zhipu",
            type: .zhipu,
            displayName: "智谱",
            enabled: true,
            credential: CredentialConfig(environmentVariable: "ZHIPU_API_KEY"),
            endpoint: "https://bigmodel.cn/api/monitor/usage/quota/limit",
            manualUsage: nil
        )

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)

        var seenAuthorizationHeaders: [String] = []
        MockURLProtocol.handler = { request in
            seenAuthorizationHeaders.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            return HTTPResponse(
                statusCode: 200,
                body: """
                {
                  "code": 200,
                  "msg": "操作成功",
                  "data": {
                    "limits": [
                      { "type": "TOKENS_LIMIT", "unit": 3, "percentage": 1 }
                    ]
                  },
                  "success": true
                }
                """
            )
        }

        let provider = ZhipuUsageProvider(
            config: config,
            urlSession: session,
            environment: ["ZHIPU_API_KEY": "  \"good-key\"  "]
        )

        _ = await provider.fetchUsage()

        XCTAssertEqual(seenAuthorizationHeaders, ["good-key"])
    }
}

private struct HTTPResponse {
    let statusCode: Int
    let body: String
}

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> HTTPResponse)?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                XCTFail("MockURLProtocol.handler is not configured")
                return
            }

            let mockResponse = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: mockResponse.statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!

            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(mockResponse.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
