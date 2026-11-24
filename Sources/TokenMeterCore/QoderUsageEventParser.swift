import Foundation

/// Qoder CLI 与 Qoder Desktop 共用的 `~/.qoder-cn/projects` 会话解析器。
///
/// Desktop 不复制会话正文；归属由其 `main.sqlite.chat_sessions.session_id` 判定。
/// Assistant 的 `usage` 是逐模型请求事实，`result.total_credits` 属累计值，不在这里消费。
public final class QoderUsageEventParser: UsageEventParser {
    private let desktopSessionIDs: Set<String>
    private let isSubagentSource: Bool
    private let dateFormatters = ClaudeCodeUsageEventParser.makeDateFormatters()
    private var sessionKey: String?
    private var projectPath: String?
    private var cliVersion: String?
    private var startedAt: Date?
    private var updatedAt: Date?
    private var events: [UsageEvent] = []
    private var eventSeq: Int

    public required convenience init(resuming state: ParserState?) {
        self.init(resuming: state, desktopSessionIDs: [], isSubagentSource: false)
    }

    init(resuming state: ParserState?, desktopSessionIDs: Set<String>, isSubagentSource: Bool = false) {
        self.desktopSessionIDs = desktopSessionIDs
        self.isSubagentSource = isSubagentSource
        sessionKey = state?.sessionKey
        projectPath = state?.projectPath
        cliVersion = state?.cliVersion
        startedAt = state?.startedAt
        updatedAt = state?.updatedAt
        eventSeq = state?.lastEventSeq ?? 0
    }

    public func consume(_ line: JSONLLine) {
        guard let object = JSONDictionary.object(from: line.text) else { return }

        sessionKey = nonempty(JSONDictionary.string(object, "sessionId"))
            ?? nonempty(JSONDictionary.string(object, "session_id"))
            ?? sessionKey
        projectPath = nonempty(JSONDictionary.string(object, "cwd")) ?? projectPath
        cliVersion = nonempty(JSONDictionary.string(object, "version")) ?? cliVersion

        if let date = timestamp(in: object) {
            startedAt = minDate(startedAt, date)
            updatedAt = maxDate(updatedAt, date)
        }

        guard JSONDictionary.string(object, "type") == "assistant",
              let message = JSONDictionary.dictionary(object, "message"),
              let usage = JSONDictionary.dictionary(message, "usage"),
              let observedAt = timestamp(in: object) else { return }

        let tokenKeys = [
            "input_tokens", "output_tokens", "cache_read_input_tokens",
            "cache_creation_input_tokens", "cache_creation",
        ]
        let tokenFieldsPresent = tokenKeys.contains { hasJSONValue(usage[$0]) }
        let creditUsage = parsedCredits(usage)
        let cacheWrite = cacheWriteTiers(in: usage)
        let inputTokens = nonnegative(usage, "input_tokens")
        let outputTokens = nonnegative(usage, "output_tokens")
        let cacheReadTokens = nonnegative(usage, "cache_read_input_tokens")
        let hasNonzeroToken = inputTokens > 0
            || outputTokens > 0
            || cacheReadTokens > 0
            || cacheWrite.fiveMinutes > 0
            || cacheWrite.oneHour > 0
        let hasPositiveCredits = (creditUsage?.actualPicos ?? 0) > 0
            || (creditUsage?.originalPicos ?? 0) > 0
        // Qoder 1.1.58 的真实 Qwen3.8-Max 会话会保留全部 Token key、把值全部写成 0，
        // 同一请求却上报正数 Credits。正数消费证明请求真实发生过，此时全零计数器是
        // “Token 未提供”，不是可向用户展示的实际 0。没有 Credits 的显式全零仍保留为 0。
        let tokensReported = tokenFieldsPresent && (hasNonzeroToken || !hasPositiveCredits)
        guard tokenFieldsPresent || creditUsage != nil else { return }

        let requestID = nonempty(JSONDictionary.string(usage, "request_id"))
        let fallbackID = nonempty(JSONDictionary.string(message, "id"))
        let dedupeKey = requestID.map { "request:\($0)" }
            ?? fallbackID.map { "message:\($0)" }

        eventSeq += 1
        events.append(UsageEvent(
            eventSeq: eventSeq,
            observedAt: observedAt,
            modelName: nonempty(JSONDictionary.string(message, "model")),
            messageId: requestID ?? fallbackID,
            dedupeKey: dedupeKey,
            dedupeScopeKey: dedupeKey == nil ? nil : "qoder",
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWrite5mTokens: cacheWrite.fiveMinutes,
            cacheWrite1hTokens: cacheWrite.oneHour,
            tokensReported: tokensReported,
            creditUsage: creditUsage,
            sourceOffset: line.offset,
            isSidechain: isSubagentSource || (object["isSidechain"] as? Bool) == true
        ))
    }

    public func finish(sourceURL: URL) throws -> (session: ParsedSession?, state: ParserState) {
        let pathSessionKey = Self.sessionKey(from: sourceURL)
        guard let finalSessionKey = nonempty(sessionKey) ?? pathSessionKey else {
            throw LocalAgentParserError.missingSessionKey
        }
        let providerID = desktopSessionIDs.contains(finalSessionKey) ? "qoder-desktop" : "qoder-cli"
        let state = ParserState(
            lastEventSeq: eventSeq,
            sessionKey: finalSessionKey,
            projectPath: projectPath,
            cliVersion: cliVersion,
            startedAt: startedAt,
            updatedAt: updatedAt
        )
        let session = ParsedSession(
            sourceKind: .qoderJSONL,
            providerId: providerID,
            sessionKey: finalSessionKey,
            projectPath: projectPath,
            cliVersion: cliVersion,
            startedAt: startedAt,
            updatedAt: updatedAt,
            events: events,
            rawMeta: ["source": "qoder", "entrypoint": providerID]
        )
        return (session, state)
    }

    private func parsedCredits(_ usage: [String: Any]) -> ProviderCreditUsage? {
        guard hasJSONValue(usage["credits"]),
              let value = JSONDictionary.double(usage, "credits"),
              let actual = ProviderCreditUsage.picos(from: value) else { return nil }
        let original = JSONDictionary.double(usage, "original_credits")
            .flatMap(ProviderCreditUsage.picos(from:))
        return ProviderCreditUsage(
            actualPicos: actual,
            originalPicos: original,
            billable: usage["billable"] as? Bool
        )
    }

    private func cacheWriteTiers(in usage: [String: Any]) -> (fiveMinutes: Int64, oneHour: Int64) {
        if let breakdown = JSONDictionary.dictionary(usage, "cache_creation") {
            return (
                nonnegative(breakdown, "ephemeral_5m_input_tokens"),
                nonnegative(breakdown, "ephemeral_1h_input_tokens")
            )
        }
        return (nonnegative(usage, "cache_creation_input_tokens"), 0)
    }

    private func timestamp(in object: [String: Any]) -> Date? {
        guard let raw = JSONDictionary.string(object, "timestamp") else { return nil }
        for formatter in dateFormatters {
            if let date = formatter.date(from: raw) { return date }
        }
        if let value = Double(raw), value.isFinite {
            return Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1_000 : value)
        }
        return nil
    }

    private func nonnegative(_ object: [String: Any], _ key: String) -> Int64 {
        max(0, JSONDictionary.int64(object, key) ?? 0)
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private func hasJSONValue(_ value: Any?) -> Bool {
        value != nil && !(value is NSNull)
    }

    private func minDate(_ lhs: Date?, _ rhs: Date) -> Date { lhs.map { min($0, rhs) } ?? rhs }
    private func maxDate(_ lhs: Date?, _ rhs: Date) -> Date { lhs.map { max($0, rhs) } ?? rhs }

    private static func sessionKey(from sourceURL: URL) -> String? {
        if sourceURL.pathComponents.contains("subagents") {
            return sourceURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        }
        let value = sourceURL.deletingPathExtension().lastPathComponent
        return value == "state" ? nil : value
    }
}
