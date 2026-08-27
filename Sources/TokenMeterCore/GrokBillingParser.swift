import Foundation

public enum GrokBillingParser {
    public enum ParseError: LocalizedError {
        case missingUsageFields

        public var errorDescription: String? {
            "Grok 响应中没有可用的额度字段"
        }
    }

    public static func parse(
        data: Data,
        providerId: String,
        displayName: String,
        fetchedAt: Date = Date()
    ) throws -> ProviderUsageSnapshot {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw ParseError.missingUsageFields
        }

        guard let usedPercent = percent(in: root) else {
            throw ParseError.missingUsageFields
        }

        let start = date(in: root, keys: [
            ["billingCycle", "billingPeriodStart"],
            ["currentPeriod", "start"],
            ["billingPeriodStart"],
            ["config", "billingCycle", "billingPeriodStart"],
            ["config", "currentPeriod", "start"],
            ["config", "billingPeriodStart"]
        ])
        let end = date(in: root, keys: [
            ["billingCycle", "billingPeriodEnd"],
            ["currentPeriod", "end"],
            ["billingPeriodEnd"],
            ["config", "billingCycle", "billingPeriodEnd"],
            ["config", "currentPeriod", "end"],
            ["config", "billingPeriodEnd"]
        ])

        let window = windowKind(start: start, end: end)
        let remaining = clamp(100 - usedPercent)
        let metric = UsageMetric(
            id: "\(providerId)-\(window.label)",
            label: window.label,
            kind: .quota,
            usedPercent: usedPercent,
            remainingPercent: remaining,
            resetText: end.map(countdownText),
            status: .ok,
            detail: nil,
            resetAt: end,
            windowDurationMinutes: window.minutes
        )

        return ProviderUsageSnapshot(
            providerId: providerId,
            displayName: displayName,
            status: .ok,
            fetchedAt: fetchedAt,
            summary: "\(window.label) \(UsageFormatter.numberText(remaining))%",
            message: nil,
            groups: [
                UsageGroup(id: providerId, title: displayName, subtitle: nil, items: [metric])
            ]
        )
    }

    private static func percent(in root: [String: Any]) -> Double? {
        let directKeys = [
            ["creditUsagePercent"],
            ["usedPercent"],
            ["usagePercent"],
            ["config", "creditUsagePercent"],
            ["config", "usedPercent"],
            ["config", "usagePercent"]
        ]
        for path in directKeys {
            if let value = number(in: root, path: path) {
                return clamp(value)
            }
        }

        let used = number(in: root, path: ["usage", "totalUsed"])
            ?? number(in: root, path: ["totalUsed"])
            ?? number(in: root, path: ["config", "usage", "totalUsed"])
        let limit = number(in: root, path: ["monthlyLimit"])
            ?? number(in: root, path: ["config", "monthlyLimit"])
        if let used, let limit, limit > 0 {
            return clamp(used / limit * 100)
        }
        return nil
    }

    private static func windowKind(start: Date?, end: Date?) -> (label: String, minutes: Int) {
        guard let start, let end else {
            return ("7d", 10_080)
        }
        let days = Calendar(identifier: .gregorian).dateComponents([.day], from: start, to: end).day ?? 0
        if (27...33).contains(days) {
            return ("30d", 43_200)
        }
        return ("7d", 10_080)
    }

    private static func date(in root: [String: Any], keys: [[String]]) -> Date? {
        for path in keys {
            if let raw = string(in: root, path: path) {
                let fractional = ISO8601DateFormatter()
                fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) {
                    return date
                }
            }
        }
        return nil
    }

    private static func number(in object: [String: Any], path: [String]) -> Double? {
        var current: Any = object
        for key in path {
            guard let dictionary = current as? [String: Any], let next = dictionary[key] else {
                return nil
            }
            current = next
        }
        return numeric(current)
    }

    private static func string(in object: [String: Any], path: [String]) -> String? {
        var current: Any = object
        for key in path {
            guard let dictionary = current as? [String: Any], let next = dictionary[key] else {
                return nil
            }
            current = next
        }
        return current as? String
    }

    private static func numeric(_ value: Any) -> Double? {
        if let number = value as? Double, number.isFinite { return number }
        if let number = value as? Int { return Double(number) }
        if let number = value as? Int64 { return Double(number) }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let double = number.doubleValue
            return double.isFinite ? double : nil
        }
        if let text = value as? String, let double = Double(text), double.isFinite {
            return double
        }
        if let object = value as? [String: Any] {
            if let wrapped = object["val"] ?? object["value"] {
                return numeric(wrapped)
            }
        }
        return nil
    }

    private static func clamp(_ value: Double) -> Double {
        max(0, min(100, value))
    }

    private static func countdownText(until date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSinceNow))
        if seconds >= 86_400 {
            return "\(seconds / 86_400)d\((seconds % 86_400) / 3600)h"
        }
        if seconds >= 3_600 {
            return "\(seconds / 3_600)h\((seconds % 3_600) / 60)m"
        }
        return "\(seconds / 60)m"
    }
}
