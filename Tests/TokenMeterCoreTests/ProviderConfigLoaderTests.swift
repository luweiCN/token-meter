import XCTest
@testable import TokenMeterCore

final class ProviderConfigLoaderTests: XCTestCase {
    func testDefaultConfigContainsInitialProviders() throws {
        let config = ProviderConfigLoader.defaultConfig()

        XCTAssertEqual(config.providers.filter(\.enabled).map(\.id), [
            "codex",
            "claude-code",
            "zhipu"
        ])

        let openCodeGo = try XCTUnwrap(config.providers.first { $0.id == "opencode-go" })
        XCTAssertEqual(openCodeGo.type, .opencodeGo)
        XCTAssertNil(openCodeGo.quotaCache)

        let zhipu = try XCTUnwrap(config.providers.first { $0.id == "zhipu" })
        XCTAssertEqual(zhipu.endpoint, "https://bigmodel.cn/api/monitor/usage/quota/limit")
        XCTAssertNil(zhipu.credential?.filePath)
    }

    func testDecodesExampleConfig() throws {
        let json = """
        {
          "menuBar": {
            "primaryProviderId": "zhipu"
          },
          "providers": [
            {
              "id": "codex",
              "type": "manual",
              "displayName": "Codex",
              "enabled": true,
              "manualUsage": {
                "status": "ok",
                "label": "今日",
                "used": 1200,
                "remaining": 8800,
                "total": 10000,
                "unit": "tokens"
              }
            },
            {
              "id": "zhipu",
              "type": "zhipu",
              "displayName": "智谱",
              "enabled": true,
              "credential": {
                "environmentVariable": "ZHIPU_API_KEY"
              }
            }
          ]
        }
        """

        let config = try ProviderConfigLoader.decode(Data(json.utf8))

        XCTAssertEqual(config.menuBar.primaryProviderId, "zhipu")
        XCTAssertEqual(config.providers.count, 2)
        XCTAssertEqual(config.providers[0].manualUsage?.remaining, 8800)
        XCTAssertEqual(config.providers[1].credential?.environmentVariable, "ZHIPU_API_KEY")
    }
}
