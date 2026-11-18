import Foundation
import TokenMeterCore

extension ClaudeCreditAmount {
    var displayText: String {
        value.formatted(.currency(code: currency).locale(Locale(identifier: "zh_CN")))
    }
}

extension AccountCredits {
    var balanceLabel: String {
        switch self {
        case .codex: return "账户余额"
        case .claude: return "预付余额"
        }
    }

    var reportedBalanceText: String? {
        switch self {
        case .codex(.amount(let number)):
            return number.formatted(.number.precision(.fractionLength(0...38)).locale(Locale(identifier: "zh_CN"))) + " 积分"
        case .codex(.unlimited): return "无限额"
        case .codex(.available): return "有可用积分"
        case .codex(.noCredits): return "无可用积分"
        case .codex(.unavailable): return nil
        case .claude(let prepaid, _): return prepaid?.displayText
        }
    }

    var balanceText: String { reportedBalanceText ?? "暂不可用" }
}
