import Foundation

public enum UsageFormatter {
    public static func menuBarTitle(for snapshots: [ProviderUsageSnapshot], primaryProviderId: String?) -> String {
        guard !snapshots.isEmpty else {
            return "TokenMeter"
        }

        let snapshot = snapshots.first { $0.providerId == primaryProviderId } ?? snapshots[0]
        if let remaining = primaryMetric(in: snapshot)?.remainingPercent {
            return "\(snapshot.displayName) \(numberText(remaining))%"
        }

        guard snapshot.status == .ok else {
            return "\(snapshot.displayName) \(statusText(snapshot.status))"
        }

        return "\(snapshot.displayName) \(statusText(snapshot.status))"
    }

    public static func menuBarTitle(for snapshots: [UsageSnapshot], primaryProviderId: String?) -> String {
        guard !snapshots.isEmpty else {
            return "TokenMeter"
        }

        let snapshot = snapshots.first { $0.providerId == primaryProviderId } ?? snapshots[0]
        guard snapshot.status == .ok else {
            return "\(snapshot.displayName) \(statusText(snapshot.status))"
        }

        if let remaining = snapshot.remaining {
            return "\(snapshot.displayName) \(numberText(remaining))\(unitSuffix(snapshot.unit))"
        }

        if let used = snapshot.used {
            return "\(snapshot.displayName) \(numberText(used))\(unitSuffix(snapshot.unit))"
        }

        return "\(snapshot.displayName) \(statusText(snapshot.status))"
    }

    public static func detailLine(for snapshot: UsageSnapshot) -> String {
        guard snapshot.status == .ok else {
            let message = snapshot.message ?? statusText(snapshot.status)
            return "\(snapshot.displayName)：\(message)"
        }

        if let message = snapshot.message, !message.isEmpty {
            return "\(snapshot.displayName)：\(message)"
        }

        let unit = snapshot.unit.map { " \($0)" } ?? ""

        switch (snapshot.used, snapshot.remaining) {
        case let (used?, remaining?):
            return "\(snapshot.displayName)：已用 \(numberText(used))\(unit)，剩余 \(numberText(remaining))\(unit)"
        case let (used?, nil):
            return "\(snapshot.displayName)：已用 \(numberText(used))\(unit)"
        case let (nil, remaining?):
            return "\(snapshot.displayName)：剩余 \(numberText(remaining))\(unit)"
        default:
            return "\(snapshot.displayName)：暂无数据"
        }
    }

    public static func primaryMetric(in snapshot: ProviderUsageSnapshot) -> UsageMetric? {
        snapshot.groups
            .lazy
            .flatMap(\.items)
            .first { $0.status == .ok && ($0.remainingPercent != nil || $0.usedPercent != nil) }
    }

    private static func statusText(_ status: UsageStatus) -> String {
        switch status {
        case .ok:
            return "正常"
        case .warning:
            return "提醒"
        case .error:
            return "异常"
        case .unknown:
            return "未知"
        }
    }

    public static func numberText(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }

        return String(format: "%.1f", value)
    }

    private static func unitSuffix(_ unit: String?) -> String {
        guard let unit else {
            return ""
        }

        if unit == "%" {
            return "%"
        }

        return " \(unit)"
    }
}
