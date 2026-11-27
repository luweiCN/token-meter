import Foundation

public enum AccountCredits: Codable, Equatable {
    case codex(CodexCreditBalance)
    case claude(prepaid: ClaudeCreditAmount?, extraUsage: ClaudeExtraUsage?)
}

public enum CodexCreditBalance: Codable, Equatable {
    case amount(Decimal), unlimited, available, noCredits, unavailable
}

public struct ClaudeCreditAmount: Codable, Equatable {
    public let value: Decimal
    public let currency: String
}

public struct ClaudeExtraUsage: Codable, Equatable {
    public let enabled: Bool?
    public let used: ClaudeCreditAmount?
    public let monthlyLimit: ClaudeCreditAmount?
}
