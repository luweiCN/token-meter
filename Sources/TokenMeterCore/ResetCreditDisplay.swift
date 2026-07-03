import Foundation

public enum ResetCreditDisplayTone: Equatable {
    case ok
    case warning
    case bad
}

public struct ResetCreditDisplayItem: Equatable {
    public let index: Int
    public let credit: ResetCredit
    public let progress: Double
    public let remainingText: String
    public let tone: ResetCreditDisplayTone

    public init(
        index: Int,
        credit: ResetCredit,
        progress: Double,
        remainingText: String,
        tone: ResetCreditDisplayTone
    ) {
        self.index = index
        self.credit = credit
        self.progress = progress
        self.remainingText = remainingText
        self.tone = tone
    }
}

public enum ResetCreditDisplay {
    public static func items(
        for summary: ResetCreditSummary,
        now: Date = Date()
    ) -> [ResetCreditDisplayItem] {
        summary.credits
            .filter { credit in
                guard let expiresAt = credit.expiresAt else {
                    return true
                }
                return expiresAt > now
            }
            .sorted { lhs, rhs in
                switch (lhs.expiresAt, rhs.expiresAt) {
                case let (lhs?, rhs?):
                    return lhs < rhs
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return false
                }
            }
            .enumerated()
            .map { offset, credit in
                item(index: offset + 1, credit: credit, now: now)
            }
    }

    public static func item(
        index: Int,
        credit: ResetCredit,
        now: Date = Date()
    ) -> ResetCreditDisplayItem {
        let remainingSeconds = credit.expiresAt.map { max(0, $0.timeIntervalSince(now)) }
        return ResetCreditDisplayItem(
            index: index,
            credit: credit,
            progress: progress(for: credit, now: now),
            remainingText: remainingText(remainingSeconds: remainingSeconds),
            tone: tone(remainingSeconds: remainingSeconds)
        )
    }

    private static func progress(for credit: ResetCredit, now: Date) -> Double {
        guard let issuedAt = credit.issuedAt,
              let expiresAt = credit.expiresAt,
              expiresAt > issuedAt else {
            return 0
        }

        let total = expiresAt.timeIntervalSince(issuedAt)
        let remaining = expiresAt.timeIntervalSince(now)
        return max(0, min(1, remaining / total))
    }

    private static func remainingText(remainingSeconds: TimeInterval?) -> String {
        guard let remainingSeconds else {
            return "--"
        }

        if remainingSeconds < 86_400 {
            return "今天到期"
        }

        let days = Int(ceil(remainingSeconds / 86_400))
        return "剩 \(days) 天"
    }

    private static func tone(remainingSeconds: TimeInterval?) -> ResetCreditDisplayTone {
        guard let remainingSeconds else {
            return .warning
        }

        if remainingSeconds < 86_400 {
            return .bad
        }
        if remainingSeconds <= 7 * 86_400 {
            return .warning
        }
        return .ok
    }
}
