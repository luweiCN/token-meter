import Foundation

public enum ProviderType: String, Codable, Equatable {
    case claudeCode
    case codex
    case manual
    case opencodeGo
    case opencodeSQLite
    case quotaCache
    case shellCommand
    case zhipu
}

public struct TokenMeterConfig: Codable, Equatable {
    public let menuBar: MenuBarConfig
    public let providers: [ProviderConfig]

    public init(menuBar: MenuBarConfig, providers: [ProviderConfig]) {
        self.menuBar = menuBar
        self.providers = providers
    }

    enum CodingKeys: String, CodingKey {
        case menuBar
        case providers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.menuBar = try container.decodeIfPresent(MenuBarConfig.self, forKey: .menuBar) ?? MenuBarConfig(primaryProviderId: nil)
        self.providers = try container.decode([ProviderConfig].self, forKey: .providers)
    }
}

public struct MenuBarConfig: Codable, Equatable {
    public let primaryProviderId: String?

    public init(primaryProviderId: String?) {
        self.primaryProviderId = primaryProviderId
    }
}

public struct ProviderConfig: Codable, Equatable {
    public let id: String
    public let type: ProviderType
    public let displayName: String
    public let enabled: Bool
    public let credential: CredentialConfig?
    public let command: CommandConfig?
    public let databasePath: String?
    public let endpoint: String?
    public let manualUsage: ManualUsageConfig?
    public let quotaCache: QuotaCacheConfig?

    public init(
        id: String,
        type: ProviderType,
        displayName: String,
        enabled: Bool,
        credential: CredentialConfig?,
        command: CommandConfig? = nil,
        databasePath: String? = nil,
        endpoint: String?,
        manualUsage: ManualUsageConfig?,
        quotaCache: QuotaCacheConfig? = nil
    ) {
        self.id = id
        self.type = type
        self.displayName = displayName
        self.enabled = enabled
        self.credential = credential
        self.command = command
        self.databasePath = databasePath
        self.endpoint = endpoint
        self.manualUsage = manualUsage
        self.quotaCache = quotaCache
    }
}

public struct CommandConfig: Codable, Equatable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]

    public init(executable: String, arguments: [String], environment: [String: String] = [:]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }
}

public struct QuotaCacheConfig: Codable, Equatable {
    public let directory: String
    public let providerId: String

    public init(directory: String, providerId: String) {
        self.directory = directory
        self.providerId = providerId
    }
}

public struct CredentialConfig: Codable, Equatable {
    public let environmentVariable: String?
    public let filePath: String?

    public init(environmentVariable: String?, filePath: String? = nil) {
        self.environmentVariable = environmentVariable
        self.filePath = filePath
    }
}

public struct ManualUsageConfig: Codable, Equatable {
    public let status: UsageStatus
    public let label: String
    public let used: Double?
    public let remaining: Double?
    public let total: Double?
    public let unit: String?
    public let message: String?

    public init(
        status: UsageStatus,
        label: String,
        used: Double?,
        remaining: Double?,
        total: Double?,
        unit: String?,
        message: String?
    ) {
        self.status = status
        self.label = label
        self.used = used
        self.remaining = remaining
        self.total = total
        self.unit = unit
        self.message = message
    }
}
