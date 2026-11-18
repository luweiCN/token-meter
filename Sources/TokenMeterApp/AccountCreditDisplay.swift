import Foundation
import TokenMeterCore

extension ClaudeCreditAmount {
    var displayText: String {
        value.formatted(.currency(code: currency).locale(Locale(identifier: "zh_CN")))
    }
}

struct AccountBalanceDisplay {
    let label: String
    let compact: String
    let full: String
    var help: String { "\(label) \(full)" }
}

extension AccountCredits {
    var displayBalance: AccountBalanceDisplay? {
        switch self {
        case .codex(.amount(let amount)) where amount > 0:
            let style = Decimal.FormatStyle.number.locale(Locale(identifier: "zh_CN"))
            let precision: NumberFormatStyleConfiguration.Precision = amount < 0.01
                ? .significantDigits(1...2) : .fractionLength(0...2)
            return AccountBalanceDisplay(
                label: "账户余额", compact: amount.formatted(style.precision(precision)) + " 积分",
                full: amount.formatted(style.precision(.fractionLength(0...38))) + " 积分"
            )
        case .codex(.unlimited):
            return AccountBalanceDisplay(label: "账户余额", compact: "积分不限额", full: "无限额")
        case .codex(.available):
            return AccountBalanceDisplay(label: "账户余额", compact: "有可用积分", full: "有可用积分")
        case .claude(let prepaid?, _) where prepaid.value > 0:
            let amount = prepaid.displayText
            return AccountBalanceDisplay(label: "预付余额", compact: "预付 \(amount)", full: amount)
        case .codex(.amount), .codex(.noCredits), .codex(.unavailable), .claude:
            return nil
        }
    }
}
