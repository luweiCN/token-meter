import CoreFoundation
import Foundation

public enum AccountCredits: Codable, Equatable {
    case codex(CodexCreditBalance)
    case claude(prepaid: ClaudeCreditAmount?, extraUsage: ClaudeExtraUsage?)

    var hasReportedData: Bool {
        switch self {
        case .codex(let balance): return balance != .unavailable
        case .claude(let prepaid, let usage): return prepaid != nil || usage != nil
        }
    }

    var unavailable: Self {
        switch self {
        case .codex: return .codex(.unavailable)
        case .claude: return .claude(prepaid: nil, extraUsage: nil)
        }
    }
}

public enum CodexCreditBalance: Codable, Equatable {
    case amount(Decimal), unlimited, available, noCredits, unavailable

    static func parse(_ object: Any?) -> Self {
        guard let credits = object as? [String: Any] else { return .unavailable }
        if credits["unlimited"] as? Bool == true { return .unlimited }
        if let raw = credits["balance"] as? String,
           raw.range(of: #"^[+-]?[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
           let number = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) {
            return .amount(number)
        }
        guard let available = credits["hasCredits"] as? Bool else { return .unavailable }
        return available ? .available : .noCredits
    }
}

public struct ClaudeCreditAmount: Codable, Equatable {
    public let value: Decimal
    public let currency: String

    init?(minorUnits: Decimal?, currency: String?) {
        guard let minorUnits, !minorUnits.isNaN, let code = currency?.uppercased(),
              code.utf8.count == 3, code.utf8.allSatisfy({ (65...90).contains($0) }) else { return nil }
        self.currency = code
        // 与 Claude Code 的使用积分计量口径一致：这三种币种直接以整币返回。
        value = ["JPY", "KRW", "VND"].contains(code) ? minorUnits : minorUnits / 100
    }

    static func prepaid(from data: Data) -> Self? {
        struct Response: Decodable { let amount: Decimal; let currency: String }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        return Self(minorUnits: response.amount, currency: response.currency)
    }
}

public struct ClaudeExtraUsage: Codable, Equatable {
    public let enabled: Bool?
    public let used: ClaudeCreditAmount?
    public let monthlyLimit: ClaudeCreditAmount?

    static func parse(_ object: Any?) -> Self? {
        guard let row = object as? [String: Any] else { return nil }
        // 旧版 extra_usage 没有 currency 时，Claude Code 以 USD 显示该月支出。
        let currency = row["currency"] == nil || row["currency"] is NSNull ? "USD" : row["currency"] as? String
        func amount(_ key: String) -> ClaudeCreditAmount? {
            guard let number = row[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return ClaudeCreditAmount(minorUnits: Decimal(string: number.stringValue), currency: currency)
        }
        let usage = Self(enabled: row["is_enabled"] as? Bool, used: amount("used_credits"), monthlyLimit: amount("monthly_limit"))
        return usage.enabled != nil || usage.used != nil || usage.monthlyLimit != nil ? usage : nil
    }
}
