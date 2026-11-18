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

    var balanceText: String { formattedBalance(precision: .fractionLength(0...38)) }

    var compactBalanceText: String {
        switch self {
        case .codex(.amount(let amount)) where amount != 0 && abs(amount) < 0.01:
            return formattedBalance(precision: .significantDigits(1...2))
        case .codex(.unlimited): return "积分不限额"
        case .codex(.unavailable): return "积分暂不可用"
        case .claude(let prepaid, _):
            return prepaid.map { "预付 \($0.displayText)" } ?? "预付余额暂不可用"
        default: return formattedBalance(precision: .fractionLength(0...2))
        }
    }

    private func formattedBalance(precision: NumberFormatStyleConfiguration.Precision) -> String {
        switch self {
        case .codex(.amount(let number)):
            return number.formatted(.number.precision(precision).locale(Locale(identifier: "zh_CN"))) + " 积分"
        case .codex(.unlimited): return "无限额"
        case .codex(.available): return "有可用积分"
        case .codex(.noCredits): return "无可用积分"
        case .codex(.unavailable): return "暂不可用"
        case .claude(let prepaid, _): return prepaid?.displayText ?? "暂不可用"
        }
    }
}
