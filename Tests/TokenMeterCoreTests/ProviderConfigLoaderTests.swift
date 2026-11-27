import XCTest
@testable import TokenMeterCore

final class ProviderConfigLoaderTests: XCTestCase {
    func testDefaultConfigContainsInitialProviders() throws {
        let config = ProviderConfigLoader.defaultConfig()

        XCTAssertEqual(config.providers.filter(\.enabled).map(\.id), [
            "codex",
            "claude-code",
            "opencode-go",
            "command-code",
            "zhipu",
            "grok",
            "qoder"
        ])

        let openCodeGo = try XCTUnwrap(config.providers.first { $0.id == "opencode-go" })
        XCTAssertEqual(openCodeGo.type, .opencodeGo)
        XCTAssertNil(openCodeGo.quotaCache)

        let commandCode = try XCTUnwrap(config.providers.first { $0.id == "command-code" })
        XCTAssertEqual(commandCode.type, .commandCode)
        XCTAssertEqual(commandCode.credential?.environmentVariable, "COMMAND_CODE_API_KEY")
        XCTAssertEqual(commandCode.endpoint, "https://api.commandcode.ai")

        let zhipu = try XCTUnwrap(config.providers.first { $0.id == "zhipu" })
        XCTAssertEqual(zhipu.endpoint, "https://bigmodel.cn/api/monitor/usage/quota/limit")
        XCTAssertNil(zhipu.credential?.filePath)

        let qoder = try XCTUnwrap(config.providers.first { $0.id == "qoder" })
        XCTAssertEqual(qoder.type, .qoder)
        XCTAssertNil(qoder.credential)
    }

    func testExistingConfigCanEnableAntigravityWithoutAutomaticallyPollingIt() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"providers":[]}"#.utf8).write(to: file)
        let config = try ProviderConfigLoader.load(from: file)
        XCTAssertEqual(config.providers.map(\.type), [.antigravity])
        XCTAssertFalse(try XCTUnwrap(config.providers.first).enabled)
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
