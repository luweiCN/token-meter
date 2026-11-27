import Foundation

public enum ProviderConfigLoader {
    private static let bundled: TokenMeterConfig = {
        guard let url = Bundle.module.url(forResource: "account-providers", withExtension: "json"),
              let config = try? decode(Data(contentsOf: url)) else {
            preconditionFailure("Missing bundled account provider configuration")
        }
        return config
    }()

    public static func decode(_ data: Data) throws -> TokenMeterConfig {
        let decoder = JSONDecoder()
        return try decoder.decode(TokenMeterConfig.self, from: data)
    }

    public static func defaultConfig() -> TokenMeterConfig {
        bundled
    }

    package static func current() -> TokenMeterConfig {
        let environment = ProcessInfo.processInfo.environment

        if let path = environment["TOKENMETER_CONFIG"],
           let config = try? ProviderConfigLoader.load(from: URL(fileURLWithPath: path)) {
            return config
        }

        let homeConfigURL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".token-meter/config.json")

        if let config = try? ProviderConfigLoader.load(from: homeConfigURL) {
            return config
        }

        return ProviderConfigLoader.defaultConfig()
    }

    public static func load(from url: URL) throws -> TokenMeterConfig {
        let config = try decode(Data(contentsOf: url))
        guard let antigravity = bundled.providers.first(where: { $0.type == .antigravity }),
              !config.providers.contains(where: { $0.type == .antigravity || $0.id == antigravity.id }) else { return config }
        return TokenMeterConfig(menuBar: config.menuBar, providers: config.providers + [antigravity])
    }
}
