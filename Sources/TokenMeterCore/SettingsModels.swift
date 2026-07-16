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
    public let menuBarGlyphWindow: MenuBarWindowChoice?
    public let menuBarNumberWindow: MenuBarWindowChoice?

    public init(
        providerId: String,
        enabled: Bool?,
        displayName: String?,
        menuRank: Int?,
        showInMenuBar: Bool?,
        showInCharts: Bool?,
        menuBarGlyphWindow: MenuBarWindowChoice? = nil,
        menuBarNumberWindow: MenuBarWindowChoice? = nil
    ) {
        self.providerId = providerId
        self.enabled = enabled
        self.displayName = displayName
        self.menuRank = menuRank
        self.showInMenuBar = showInMenuBar
        self.showInCharts = showInCharts
        self.menuBarGlyphWindow = menuBarGlyphWindow
        self.menuBarNumberWindow = menuBarNumberWindow
    }
}

/// 菜单栏样式族（OpenDesign 稿 S0-S15，rawValue 与 Electron 端 / DB 存储一致）。
public enum MenuBarStyleId: String, Codable, Equatable, CaseIterable {
    case rings, vbars, hbar, digits, dots, caps, ticks, ring1
    case grid, sentinel, monogram, strip, tagnum, deck2, ringdeck, barsdeck
}

/// 按家窗口选择：short = 5h 类短窗、long = 7d 类长窗。图形与数字各自独立。
public enum MenuBarWindowChoice: String, Codable, Equatable {
    case short, long, both
}

public enum MenuBarUsageTail: String, Codable, Equatable {
    case off, tok, cost
}

/// both 时的呈现顺序（图形双元素与双数字一致翻转）。默认 longFirst 保持
/// 既有 S0 视觉（外环/第一位数字 = 7d）；用户裁定做成设置项而非写死。
public enum MenuBarWindowOrder: String, Codable, Equatable {
    case longFirst, shortFirst
}

public struct MenuBarAppearanceSettings: Codable, Equatable {
    public let style: MenuBarStyleId
    public let showName: Bool
    public let showGlyph: Bool
    public let showNumber: Bool
    public let usage: MenuBarUsageTail
    public let windowOrder: MenuBarWindowOrder

    public static let `default` = MenuBarAppearanceSettings(
        style: .rings,
        showName: true,
        showGlyph: true,
        showNumber: true,
        usage: .tok,
        windowOrder: .longFirst
    )

    public init(
        style: MenuBarStyleId,
        showName: Bool,
        showGlyph: Bool,
        showNumber: Bool,
        usage: MenuBarUsageTail,
        windowOrder: MenuBarWindowOrder
    ) {
        self.style = style
        self.showName = showName
        self.showGlyph = showGlyph
        self.showNumber = showNumber
        self.usage = usage
        self.windowOrder = windowOrder
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
    /// 菜单栏外观（样式/元素/今日尾巴/窗口顺序）。Electron 设置页写入，Swift 只读。
    public let menuBarAppearance: MenuBarAppearanceSettings

    public init(
        version: Int,
        menuBarPrimaryProviderId: String?,
        autoRefreshSeconds: Int,
        enabledAgentKinds: [String],
        providerOverrides: [ProviderConfigOverride],
        quotaUsedThresholdPercent: Int = 0,
        menuBarAppearance: MenuBarAppearanceSettings = .default
    ) {
        self.version = version
        self.menuBarPrimaryProviderId = menuBarPrimaryProviderId
        self.autoRefreshSeconds = autoRefreshSeconds
        self.enabledAgentKinds = enabledAgentKinds
        self.providerOverrides = providerOverrides
        self.quotaUsedThresholdPercent = quotaUsedThresholdPercent
        self.menuBarAppearance = menuBarAppearance
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
