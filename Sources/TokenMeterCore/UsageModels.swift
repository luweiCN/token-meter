import Foundation

public enum UsageStatus: String, Codable, Equatable {
    case ok
    case warning
    case error
    case unknown
}

public enum UsageMetricKind: String, Codable, Equatable {
    case quota
    case balance
    case tokens
}

public struct UsageMetric: Codable, Equatable {
    public let id: String
    public let label: String
    public let kind: UsageMetricKind
    public let usedPercent: Double?
    public let remainingPercent: Double?
    public let resetText: String?
    public let status: UsageStatus
    public let detail: String?
    public let resetAt: Date?
    public let windowDurationMinutes: Int?
    public let usedAmount: String?
    public let remainingAmount: String?
    public let totalAmount: String?
    public let unit: String?

    public init(
        id: String,
        label: String,
        kind: UsageMetricKind,
        usedPercent: Double?,
        remainingPercent: Double?,
        resetText: String?,
        status: UsageStatus,
        detail: String?,
        resetAt: Date? = nil,
        windowDurationMinutes: Int? = nil,
        usedAmount: String? = nil,
        remainingAmount: String? = nil,
        totalAmount: String? = nil,
        unit: String? = nil
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.usedPercent = usedPercent
        self.remainingPercent = remainingPercent
        self.resetText = resetText
        self.status = status
        self.detail = detail
        self.resetAt = resetAt
        self.windowDurationMinutes = windowDurationMinutes
        self.usedAmount = usedAmount
        self.remainingAmount = remainingAmount
        self.totalAmount = totalAmount
        self.unit = unit
    }
}

public struct UsageGroup: Codable, Equatable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let items: [UsageMetric]

    public init(id: String, title: String, subtitle: String?, items: [UsageMetric]) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.items = items
    }
}

public struct ResetCreditSummary: Codable, Equatable {
    public let availableCount: Int
    public let credits: [ResetCredit]

    public init(availableCount: Int, credits: [ResetCredit]) {
        self.availableCount = availableCount
        self.credits = credits
    }
}

public struct ResetCredit: Codable, Equatable {
    public let issuedAt: Date?
    public let expiresAt: Date?

    public init(issuedAt: Date?, expiresAt: Date?) {
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }
}

public struct ProviderUsageSnapshot: Codable, Equatable {
    public let providerId: String
    public let displayName: String
    public let status: UsageStatus
    public let fetchedAt: Date
    public let summary: String?
    public let message: String?
    public let groups: [UsageGroup]
    public let resetCredits: ResetCreditSummary?
    public internal(set) var accountCredits: AccountCredits?

    public init(
        providerId: String,
        displayName: String,
        status: UsageStatus,
        fetchedAt: Date,
        summary: String?,
        message: String?,
        groups: [UsageGroup],
        resetCredits: ResetCreditSummary? = nil,
        accountCredits: AccountCredits? = nil
    ) {
        self.providerId = providerId
        self.displayName = displayName
        self.status = status
        self.fetchedAt = fetchedAt
        self.summary = summary
        self.message = message
        self.groups = groups
        self.resetCredits = resetCredits
        self.accountCredits = accountCredits
    }

    /// 应用供应商别名（设置页的 displayName override）：换 displayName 的同时，
    /// 把「与旧名同名的组」的 title 一起换——弹窗以 group.title == displayName
    /// 判定主组（QuotaDisplayModel.isPrimary），两者不同步换主组就会丢。
    public func renamed(to newName: String) -> ProviderUsageSnapshot {
        guard !newName.isEmpty, newName != displayName else { return self }
        let renamedGroups = groups.map { group in
            group.title == displayName
                ? UsageGroup(id: group.id, title: newName, subtitle: group.subtitle, items: group.items)
                : group
        }
        return ProviderUsageSnapshot(
            providerId: providerId,
            displayName: newName,
            status: status,
            fetchedAt: fetchedAt,
            summary: summary,
            message: message,
            groups: renamedGroups,
            resetCredits: resetCredits,
            accountCredits: accountCredits
        )
    }
}
