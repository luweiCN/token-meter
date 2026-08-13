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
    /// 多选窗口标签（如 ["5h", "30d"]）：设置页新交互写入，优先于 menuBarGlyphWindow。
    /// 独立列存储（menubar_glyph_windows），避免旧列 CHECK 约束限制。
    public let menuBarGlyphWindows: [String]?
    public let menuBarNumberWindows: [String]?

    public init(
        providerId: String,
        enabled: Bool?,
        displayName: String?,
        menuRank: Int?,
        showInMenuBar: Bool?,
        showInCharts: Bool?,
        menuBarGlyphWindow: MenuBarWindowChoice? = nil,
        menuBarNumberWindow: MenuBarWindowChoice? = nil,
        menuBarGlyphWindows: [String]? = nil,
        menuBarNumberWindows: [String]? = nil
    ) {
        self.providerId = providerId
        self.enabled = enabled
        self.displayName = displayName
        self.menuRank = menuRank
        self.showInMenuBar = showInMenuBar
        self.showInCharts = showInCharts
        self.menuBarGlyphWindow = menuBarGlyphWindow
        self.menuBarNumberWindow = menuBarNumberWindow
        self.menuBarGlyphWindows = menuBarGlyphWindows
        self.menuBarNumberWindows = menuBarNumberWindows
    }
}

/// 菜单栏样式族（OpenDesign 稿 S0-S15，rawValue 与 Electron 端 / DB 存储一致）。
public enum MenuBarStyleId: String, Codable, Equatable, CaseIterable {
    case rings, vbars, hbar, digits, dots, caps, ticks, ring1
    case grid, sentinel, monogram, strip, tagnum, deck2, ringdeck, barsdeck
}

/// 按家窗口选择：short = 5h 类短窗、long = 7d 类长窗、both = 短窗+长窗两只、
/// all = 全部窗口（OpenCode Go 的 5h/周/月三只平级）。图形与数字各自独立。
public enum MenuBarWindowChoice: String, Codable, Equatable {
    case short, long, both, all
}

public enum MenuBarUsageTail: String, Codable, Equatable {
    case off, tok, cost
}

/// 菜单栏峰/谷标识的样式。峰=黄、谷=绿（与弹窗语义色同源）。
public enum PeakBadgeStyle: String, Codable, Equatable, CaseIterable {
    /// 色点 + 单字（默认，现状）
    case dotWord
    /// 只留色点，最省空间
    case dot
    /// 只留单字，字色随档位
    case word
    /// 胶囊底 + 单字，最醒目
    case pill
}

/// 金额显示币种。计价与存储永远以美元微元为准，人民币只在显示层换算。
public enum DisplayCurrency: String, Codable, Equatable {
    case usd
    case cny
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
    /// 是否在菜单栏显示峰/谷标识（有峰谷价服务商可见时）。
    public let showPeakBadge: Bool
    /// 峰/谷标识样式。
    public let peakBadgeStyle: PeakBadgeStyle

    public static let `default` = MenuBarAppearanceSettings(
        style: .rings,
        showName: true,
        showGlyph: true,
        showNumber: true,
        usage: .tok,
        windowOrder: .longFirst,
        showPeakBadge: true,
        peakBadgeStyle: .dotWord
    )

    public init(
        style: MenuBarStyleId,
        showName: Bool,
        showGlyph: Bool,
        showNumber: Bool,
        usage: MenuBarUsageTail,
        windowOrder: MenuBarWindowOrder,
        showPeakBadge: Bool = true,
        peakBadgeStyle: PeakBadgeStyle = .dotWord
    ) {
        self.style = style
        self.showName = showName
        self.showGlyph = showGlyph
        self.showNumber = showNumber
        self.usage = usage
        self.windowOrder = windowOrder
        self.showPeakBadge = showPeakBadge
        self.peakBadgeStyle = peakBadgeStyle
    }

    // 旧数据没有 showPeakBadge/peakBadgeStyle：解码补默认，不炸老快照。
    private enum CodingKeys: String, CodingKey {
        case style
        case showName
        case showGlyph
        case showNumber
        case usage
        case windowOrder
        case showPeakBadge
        case peakBadgeStyle
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        style = try container.decodeIfPresent(MenuBarStyleId.self, forKey: .style) ?? .rings
        showName = try container.decodeIfPresent(Bool.self, forKey: .showName) ?? true
        showGlyph = try container.decodeIfPresent(Bool.self, forKey: .showGlyph) ?? true
        showNumber = try container.decodeIfPresent(Bool.self, forKey: .showNumber) ?? true
        usage = try container.decodeIfPresent(MenuBarUsageTail.self, forKey: .usage) ?? .tok
        windowOrder = try container.decodeIfPresent(MenuBarWindowOrder.self, forKey: .windowOrder) ?? .longFirst
        showPeakBadge = try container.decodeIfPresent(Bool.self, forKey: .showPeakBadge) ?? true
        peakBadgeStyle = try container.decodeIfPresent(PeakBadgeStyle.self, forKey: .peakBadgeStyle) ?? .dotWord
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(style, forKey: .style)
        try container.encode(showName, forKey: .showName)
        try container.encode(showGlyph, forKey: .showGlyph)
        try container.encode(showNumber, forKey: .showNumber)
        try container.encode(usage, forKey: .usage)
        try container.encode(windowOrder, forKey: .windowOrder)
        try container.encode(showPeakBadge, forKey: .showPeakBadge)
        try container.encode(peakBadgeStyle, forKey: .peakBadgeStyle)
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
    /// 金额显示币种。Electron 设置页写入，Swift 只读；默认人民币（用户裁定）。
    public let displayCurrency: DisplayCurrency

    public init(
        version: Int,
        menuBarPrimaryProviderId: String?,
        autoRefreshSeconds: Int,
        enabledAgentKinds: [String],
        providerOverrides: [ProviderConfigOverride],
        quotaUsedThresholdPercent: Int = 0,
        menuBarAppearance: MenuBarAppearanceSettings = .default,
        displayCurrency: DisplayCurrency = .cny
    ) {
        self.version = version
        self.menuBarPrimaryProviderId = menuBarPrimaryProviderId
        self.autoRefreshSeconds = autoRefreshSeconds
        self.enabledAgentKinds = enabledAgentKinds
        self.providerOverrides = providerOverrides
        self.quotaUsedThresholdPercent = quotaUsedThresholdPercent
        self.menuBarAppearance = menuBarAppearance
        self.displayCurrency = displayCurrency
    }

    // 旧数据没有 displayCurrency：解码补默认人民币，不炸老快照/测试载荷。
    private enum CodingKeys: String, CodingKey {
        case version
        case menuBarPrimaryProviderId
        case autoRefreshSeconds
        case enabledAgentKinds
        case providerOverrides
        case quotaUsedThresholdPercent
        case menuBarAppearance
        case displayCurrency
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        menuBarPrimaryProviderId = try container.decodeIfPresent(String.self, forKey: .menuBarPrimaryProviderId)
        autoRefreshSeconds = try container.decodeIfPresent(Int.self, forKey: .autoRefreshSeconds) ?? 300
        enabledAgentKinds = try container.decodeIfPresent([String].self, forKey: .enabledAgentKinds) ?? []
        providerOverrides = try container.decodeIfPresent([ProviderConfigOverride].self, forKey: .providerOverrides) ?? []
        quotaUsedThresholdPercent = try container.decodeIfPresent(Int.self, forKey: .quotaUsedThresholdPercent) ?? 0
        menuBarAppearance = try container.decodeIfPresent(MenuBarAppearanceSettings.self, forKey: .menuBarAppearance) ?? .default
        displayCurrency = try container.decodeIfPresent(DisplayCurrency.self, forKey: .displayCurrency) ?? .cny
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(menuBarPrimaryProviderId, forKey: .menuBarPrimaryProviderId)
        try container.encode(autoRefreshSeconds, forKey: .autoRefreshSeconds)
        try container.encode(enabledAgentKinds, forKey: .enabledAgentKinds)
        try container.encode(providerOverrides, forKey: .providerOverrides)
        try container.encode(quotaUsedThresholdPercent, forKey: .quotaUsedThresholdPercent)
        try container.encode(menuBarAppearance, forKey: .menuBarAppearance)
        try container.encode(displayCurrency, forKey: .displayCurrency)
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
