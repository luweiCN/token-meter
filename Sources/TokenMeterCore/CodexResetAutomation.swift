import Foundation

public enum CodexResetAutomationStatus: String {
    case disabled, waiting, checking, needsLogin, missingDetails, succeeded, nothingToReset, noCredit, uncertain, unavailable, unsupportedCLI

    public var message: String {
        switch self {
        case .disabled: return "自动使用已关闭"
        case .waiting: return "等待重置卡进入到期前 1 小时"
        case .checking: return "正在检查重置卡"
        case .needsLogin: return "需要有效的本机 Codex 登录状态"
        case .missingDetails: return "无法取得卡片明细，请更新 Codex CLI"
        case .succeeded: return "已自动使用重置卡"
        case .nothingToReset: return "当前用量暂时无需重置"
        case .noCredit: return "目标重置卡已不可用"
        case .uncertain: return "使用结果待确认，将核对同一次请求"
        case .unavailable: return "暂时无法检查，请确认网络与登录状态"
        case .unsupportedCLI: return "请更新 Codex CLI，当前版本不支持指定重置卡"
        }
    }
}

@MainActor
public final class CodexResetAutomation {
    public private(set) var status: CodexResetAutomationStatus = .disabled
    private let client: CodexAccountServicing
    private let store: CodexResetRedemptionStore
    private let now: () -> Date
    private let owner = UUID().uuidString
    private var inFlight = false

    public init(client: CodexAccountServicing, store: CodexResetRedemptionStore, now: @escaping () -> Date = Date.init) {
        self.client = client
        self.store = store
        self.now = now
    }

    @discardableResult
    public func check(isEnabled: () -> Bool) async -> Bool {
        guard isEnabled(), !Task.isCancelled else { status = .disabled; return false }
        guard !inFlight else { return false }
        inFlight = true
        if status == .disabled { status = .waiting }
        defer { inFlight = false }
        var attempt: CodexResetRedemptionStore.Attempt?
        do {
            let account = try await client.read()
            guard isEnabled(), !Task.isCancelled else { status = .disabled; return false }
            let current = now()
            guard abs(current.timeIntervalSince(account.fetchedAt)) <= 60 else { status = .unavailable; return false }
            guard let fingerprint = account.accountFingerprint, !fingerprint.isEmpty else { status = .needsLogin; return false }
            guard let credits = account.credits else { status = .missingDetails; return false }
            guard (account.availableCount ?? 0) > 0,
                  let credit = credits.filter({ $0.isEligible(at: current) })
                    .min(by: { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }) else {
                if status != .succeeded { status = .waiting }
                return false
            }
            attempt = try store.claim(
                account: fingerprint, credit: codexFingerprint(Data(credit.id.utf8)),
                quota: account.quotaFingerprint, owner: owner, now: current
            )
            guard let attempt else { return false }
            guard isEnabled(), !Task.isCancelled, credit.isEligible(at: now()) else { status = .disabled; return false }
            status = .checking
            let outcome = try await client.consume(creditID: credit.id, idempotencyKey: attempt.key, accountFingerprint: fingerprint)
            // 先落盘成功状态，再由调用者刷新显示；刷新失败不能生成第二次消费。
            try store.finish(attempt, outcome: outcome, now: now())
            switch outcome {
            case .reset, .alreadyRedeemed: status = .succeeded; return true
            case .nothingToReset: status = .nothingToReset
            case .noCredit: status = .noCredit
            }
        } catch {
            if let attempt { try? store.finish(attempt, outcome: nil, now: now()) }
            if !isEnabled() { status = .disabled }
            else if case CodexAccountError.unsupportedResetAPI = error { status = .unsupportedCLI }
            else if case CodexAccountError.accountChanged = error { status = .needsLogin }
            else if case CodexAccountError.creditNotEligible = error { status = .waiting }
            else { status = attempt == nil ? .unavailable : .uncertain }
        }
        return false
    }
}
