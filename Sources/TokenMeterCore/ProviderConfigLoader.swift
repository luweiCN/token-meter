import Foundation

public enum ProviderConfigLoader {
    private static let antigravity = ProviderConfig(
        id: AntigravityQuota.providerID, type: .antigravity, displayName: AntigravityQuota.shortName,
        enabled: false, credential: nil, endpoint: nil, manualUsage: nil
    )
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
                    enabled: true,
                    credential: nil,
                    endpoint: nil,
                    manualUsage: nil
                ),
                ProviderConfig(
                    id: "command-code",
                    type: .commandCode,
                    displayName: "Command Code",
                    enabled: true,
                    credential: CredentialConfig(environmentVariable: "COMMAND_CODE_API_KEY"),
                    endpoint: "https://api.commandcode.ai",
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
                ),
                ProviderConfig(
                    id: "grok",
                    type: .grok,
                    displayName: "Grok Build",
                    enabled: true,
                    credential: nil,
                    endpoint: nil,
                    manualUsage: nil
                ),
                antigravity,
                ProviderConfig(
                    id: "qoder",
                    type: .qoder,
                    displayName: "Qoder",
                    enabled: true,
                    credential: nil,
                    endpoint: nil,
                    manualUsage: nil
                )
            ]
        )
    }

    public static func load(from url: URL) throws -> TokenMeterConfig {
        let config = try decode(Data(contentsOf: url))
        guard !config.providers.contains(where: { $0.type == .antigravity || $0.id == antigravity.id }) else { return config }
        return TokenMeterConfig(menuBar: config.menuBar, providers: config.providers + [antigravity])
    }
}
