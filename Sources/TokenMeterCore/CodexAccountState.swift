import CryptoKit
import Foundation

public struct CodexRedeemableCredit: Sendable {
    public static let autoRedeemLeadTime: TimeInterval = 3_600
    public let id: String
    public let resetType: String
    public let status: String
    public let grantedAt: Date?
    public let expiresAt: Date?

    public func isEligible(at now: Date) -> Bool {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              resetType == "codexRateLimits", status == "available", let expiresAt else { return false }
        let remaining = expiresAt.timeIntervalSince(now)
        return remaining > 0 && remaining <= Self.autoRedeemLeadTime
    }
}

public struct CodexAccountState: Sendable {
    public var accountFingerprint: String?
    public let availableCount: Int?
    public var credits: [CodexRedeemableCredit]?
    public var quotaFingerprint: String
    public let usageData: Data
    public var fetchedAt: Date

    public var displayCredits: ResetCreditSummary? {
        guard let availableCount else { return nil }
        return ResetCreditSummary(availableCount: availableCount, credits: (credits ?? [])
            .filter { $0.status == "available" }
            .map { ResetCredit(issuedAt: $0.grantedAt, expiresAt: $0.expiresAt) })
    }

    public func snapshot(providerId: String, displayName: String) throws -> ProviderUsageSnapshot {
        try CodexUsageParser.parse(data: usageData, providerId: providerId, displayName: displayName)
            .withResetCredits(displayCredits)
    }

    public static func parse(_ data: Data, now: Date = Date()) throws -> CodexAccountState {
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = envelope["limits"] as? [String: Any] else { throw CodexAccountError.invalidResponse }
        let summary = limits["rateLimitResetCredits"] as? [String: Any]
        let rows = summary?["credits"] as? [[String: Any]]
        let credits = rows?.map { row in
            CodexRedeemableCredit(
                id: row["id"] as? String ?? "", resetType: row["resetType"] as? String ?? "",
                status: row["status"] as? String ?? "", grantedAt: timestamp(row["grantedAt"]),
                expiresAt: timestamp(row["expiresAt"])
            )
        }
        let quota = limits["rateLimits"] as? [String: Any] ?? [:]
        let eligibility = quota.filter { ["primary", "secondary", "rateLimitReachedType"].contains($0.key) }
        let fingerprint = try JSONSerialization.data(withJSONObject: eligibility, options: .sortedKeys)
        return CodexAccountState(
            accountFingerprint: envelope["accountFingerprint"] as? String,
            availableCount: (summary?["availableCount"] as? Int).map { max(0, $0) }, credits: credits,
            quotaFingerprint: codexFingerprint(fingerprint),
            usageData: try JSONSerialization.data(withJSONObject: limits), fetchedAt: now
        )
    }

    private static func timestamp(_ value: Any?) -> Date? {
        guard let seconds = value as? Double, seconds.isFinite, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

func codexFingerprint(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

public enum CodexResetOutcome: String, Decodable, Sendable {
    case reset, alreadyRedeemed, nothingToReset, noCredit
}

public enum CodexAccountError: LocalizedError {
    case invalidResponse, requestFailed, timedOut
    case unsupportedResetAPI, accountChanged, creditNotEligible

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Codex 返回的数据不完整，请检查 CLI 版本与登录状态"
        case .requestFailed: return "Codex 请求未能确认，请检查网络与登录状态"
        case .timedOut: return "Codex 请求超时"
        case .unsupportedResetAPI: return "请更新 Codex CLI，当前版本不支持指定重置卡"
        case .accountChanged: return "Codex 登录账户已变化，已停止本次自动使用"
        case .creditNotEligible: return "目标卡片已不在可使用的时间范围内"
        }
    }
}

@MainActor
public protocol CodexAccountServicing {
    func read() async throws -> CodexAccountState
    func consume(creditID: String, idempotencyKey: String, accountFingerprint: String) async throws -> CodexResetOutcome
}
