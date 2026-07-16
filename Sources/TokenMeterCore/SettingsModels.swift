import Foundation

public enum SettingsUpdatedBy: String, Codable, Equatable {
    case swift
    case electron
    case migrator
    case importer
}

public struct ProviderConfigOverride: Codable, Equatable {
    public let providerId: String
    public let enabled: Bool?
    public let displayName: String?
    public let menuRank: Int?
    public let showInMenuBar: Bool?
    public let showInCharts: Bool?

    public init(
        providerId: String,
        enabled: Bool?,
        displayName: String?,
        menuRank: Int?,
        showInMenuBar: Bool?,
        showInCharts: Bool?
    ) {
        self.providerId = providerId
        self.enabled = enabled
        self.displayName = displayName
        self.menuRank = menuRank
        self.showInMenuBar = showInMenuBar
        self.showInCharts = showInCharts
    }
}

public struct SettingsSnapshot: Codable, Equatable {
    public let version: Int
    public let menuBarPrimaryProviderId: String?
    public let autoRefreshSeconds: Int
    public let enabledAgentKinds: [String]
    public let providerOverrides: [ProviderConfigOverride]
    /// 额度用量告警阈值（usedPercent 达到即通知）。0 = 关闭。Electron 设置页写入。
    public let quotaUsedThresholdPercent: Int

    public init(
        version: Int,
        menuBarPrimaryProviderId: String?,
        autoRefreshSeconds: Int,
        enabledAgentKinds: [String],
        providerOverrides: [ProviderConfigOverride],
        quotaUsedThresholdPercent: Int = 0
    ) {
        self.version = version
        self.menuBarPrimaryProviderId = menuBarPrimaryProviderId
        self.autoRefreshSeconds = autoRefreshSeconds
        self.enabledAgentKinds = enabledAgentKinds
        self.providerOverrides = providerOverrides
        self.quotaUsedThresholdPercent = quotaUsedThresholdPercent
    }
}

public struct SettingsPatch: Codable, Equatable {
    public let menuBarPrimaryProviderId: String?
    public let autoRefreshSeconds: Int?
    public let enabledAgentKinds: [String]?

    public init(
        menuBarPrimaryProviderId: String? = nil,
        autoRefreshSeconds: Int? = nil,
        enabledAgentKinds: [String]? = nil
    ) {
        self.menuBarPrimaryProviderId = menuBarPrimaryProviderId
        self.autoRefreshSeconds = autoRefreshSeconds
        self.enabledAgentKinds = enabledAgentKinds
    }

    var hasChanges: Bool {
        menuBarPrimaryProviderId != nil || autoRefreshSeconds != nil || enabledAgentKinds != nil
    }
}

public struct SettingsApplyRequest: Codable, Equatable {
    public let requestedVersion: Int
    public let status: String

    public init(requestedVersion: Int, status: String) {
        self.requestedVersion = requestedVersion
        self.status = status
    }
}

public enum SettingsStoreError: Error, Equatable {
    case staleVersion(expected: Int, actual: Int)
    case invalidValue(String)
    case invalidStoredValue(String)
}
