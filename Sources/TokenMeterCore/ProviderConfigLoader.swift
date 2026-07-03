import Foundation

public enum ProviderConfigLoader {
    public static func decode(_ data: Data) throws -> TokenMeterConfig {
        let decoder = JSONDecoder()
        return try decoder.decode(TokenMeterConfig.self, from: data)
    }

    public static func defaultConfig() -> TokenMeterConfig {
        TokenMeterConfig(
            menuBar: MenuBarConfig(primaryProviderId: "codex"),
            providers: [
                ProviderConfig(
                    id: "codex",
                    type: .codex,
                    displayName: "Codex",
                    enabled: true,
                    credential: nil,
                    endpoint: nil,
                    manualUsage: nil
                ),
                ProviderConfig(
                    id: "claude-code",
                    type: .claudeCode,
                    displayName: "Claude Code",
                    enabled: true,
                    credential: nil,
                    endpoint: nil,
                    manualUsage: nil
                ),
                ProviderConfig(
                    id: "opencode-go",
                    type: .opencodeGo,
                    displayName: "OpenCode Go",
                    enabled: false,
                    credential: nil,
                    endpoint: nil,
                    manualUsage: nil
                ),
                ProviderConfig(
                    id: "zhipu",
                    type: .zhipu,
                    displayName: "智谱",
                    enabled: true,
                    credential: CredentialConfig(
                        environmentVariable: "ZHIPU_API_KEY"
                    ),
                    endpoint: "https://bigmodel.cn/api/monitor/usage/quota/limit",
                    manualUsage: nil
                ),
                ProviderConfig(
                    id: "zhipu-http",
                    type: .zhipu,
                    displayName: "智谱 HTTP",
                    enabled: false,
                    credential: CredentialConfig(environmentVariable: "ZHIPU_API_KEY"),
                    endpoint: "https://bigmodel.cn/api/monitor/usage/quota/limit",
                    manualUsage: nil
                )
            ]
        )
    }

    public static func load(from url: URL) throws -> TokenMeterConfig {
        try decode(Data(contentsOf: url))
    }
}
