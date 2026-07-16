import Foundation

public enum UsageFormatter {
    /// 菜单栏主标题：今日已用 token 总量（K/M/B 缩写），取代旧的「服务商 剩余%」。
    /// 0（一天刚开始，或库为空/未迁移时 summary 为 empty）回落到产品名，
    /// 免得菜单栏挂一个没有上下文的孤零零 "0"。
    public static func menuBarTitle(todayTokens: Int64) -> String {
        guard todayTokens > 0 else { return "TokenMeter" }
        return compactTokens(todayTokens)
    }

    /// token 数缩写（775 / 3.4K / 512.4M / 2398.5M），菜单栏标题与弹窗大数字共用。
    /// 这两处显示的都是【今日】用量——单日数字永远停在 M 单位：升到 1 位小数的 B
    /// 会把百万级变化吞掉，十亿级也就四位数 M，完全排得下。
    public static func compactTokens(_ value: Int64) -> String {
        let v = Double(value)
        if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%.1fK", v / 1_000) }
        return String(Int(v))
    }

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
