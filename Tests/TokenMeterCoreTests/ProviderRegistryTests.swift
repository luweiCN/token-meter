import XCTest
@testable import TokenMeterCore

final class ProviderRegistryTests: XCTestCase {
    func testRegistryCreatesProvidersForDefaultConfig() {
        let providers = ProviderRegistry.makeProviders(from: ProviderConfigLoader.defaultConfig())

        XCTAssertEqual(providers.map(\.id), [
            "codex",
            "claude-code",
            "zhipu"
        ])
    }

    func testManualProviderReturnsConfiguredUsage() async {
        let provider = ManualUsageProvider(
            config: ProviderConfig(
                id: "codex",
                type: .manual,
                displayName: "Codex",
                enabled: true,
                credential: nil,
                endpoint: nil,
                manualUsage: ManualUsageConfig(
                    status: .ok,
                    label: "今日",
                    used: 42,
                    remaining: 58,
                    total: 100,
                    unit: "tokens",
                    message: nil
                )
            )
        )

        let snapshot = await provider.fetchUsage()

        XCTAssertEqual(snapshot.providerId, "codex")
        XCTAssertEqual(snapshot.displayName, "Codex")
        XCTAssertEqual(snapshot.used, 42)
        XCTAssertEqual(snapshot.remaining, 58)
    }

    func testShellQuotaParserStripsTmuxStyleAndReadsRemainingPercent() throws {
        let snapshot = try ShellQuotaParser.parse(
            output: "#[fg=colour5,bold]codex #[default]#[fg=colour6]5h #[fg=colour2]69% #[fg=colour8]2h47m #[fg=colour8]· #[fg=colour6]7d #[fg=colour2]70% #[fg=colour8]5d7h",
            providerId: "codex",
            displayName: "Codex"
        )

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.remaining, 69)
        XCTAssertEqual(snapshot.message, "codex 5h 69% 2h47m · 7d 70% 5d7h")
    }

    func testQuotaCacheParserReadsAllPercentRemainingEntries() throws {
        let json = """
        {
          "result": {
            "entries": [
              {
                "name": "Zhipu 5h",
                "group": "Zhipu",
                "label": "5h:",
                "percentRemaining": 83,
                "resetTimeIso": "2026-06-27T15:05:14.968Z"
              },
              {
                "name": "Zhipu Weekly",
                "group": "Zhipu",
                "label": "Weekly:",
                "percentRemaining": 93,
                "resetTimeIso": "2026-07-02T07:22:54.977Z"
              },
              {
                "name": "Zhipu MCP",
                "group": "Zhipu",
                "label": "MCP:",
                "percentRemaining": 97,
                "resetTimeIso": "2026-07-18T07:22:54.998Z"
              }
            ],
            "errors": []
          }
        }
        """

        let snapshot = try QuotaCacheParser.parse(
            data: Data(json.utf8),
            providerId: "zhipu",
            displayName: "智谱"
        )

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.remaining, 83)
        XCTAssertEqual(snapshot.message, "5h 83% · Weekly 93% · MCP 97%")
    }
}
