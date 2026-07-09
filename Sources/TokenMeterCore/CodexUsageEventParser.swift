import Foundation

public final class CodexUsageEventParser: UsageEventParser {
    private var sessionKey: String?
    private var projectPath: String?
    private var modelName: String?
    private var startedAt: Date?
    private var updatedAt: Date?
    private var events: [UsageEvent] = []
    private var eventSeq: Int
    private var cumulative: CumulativeTokenTotals?
    private let dateFormatters = ClaudeCodeUsageEventParser.makeDateFormatters()

    public init(resuming state: ParserState?) {
        eventSeq = state?.lastEventSeq ?? 0
        cumulative = state?.lastCumulative
        // session_meta / turn_context 只在文件开头出现一次；续读的追加片段里没有它们，
        // 必须从 state 恢复会话身份，否则 finish() 会缺 sessionKey、事件也会丢掉 model。
        sessionKey = state?.sessionKey
        projectPath = state?.projectPath
        modelName = state?.modelName
        startedAt = state?.startedAt
        updatedAt = state?.updatedAt
    }

    public func consume(_ line: JSONLLine) {
        guard let object = JSONDictionary.object(from: line.text) else { return }
        let payload = JSONDictionary.dictionary(object, "payload")

        if let timestamp = timestamp(in: object) {
            if startedAt == nil { startedAt = timestamp }
            updatedAt = timestamp
        }

        switch JSONDictionary.string(object, "type") {
        case "session_meta":
            sessionKey = payload.flatMap { JSONDictionary.string($0, "id") } ?? sessionKey
            projectPath = payload.flatMap { JSONDictionary.string($0, "cwd") } ?? projectPath
        case "turn_context":
            modelName = payload.flatMap { JSONDictionary.string($0, "model") } ?? modelName
            projectPath = payload.flatMap { JSONDictionary.string($0, "cwd") } ?? projectPath
        case "event_msg":
            guard let payload,
                  JSONDictionary.string(payload, "type") == "token_count",
                  let info = JSONDictionary.dictionary(payload, "info"),
                  let observedAt = timestamp(in: object) else {
                return
            }

            let delta: RawTokenTotals
            if let last = JSONDictionary.dictionary(info, "last_token_usage") {
                delta = RawTokenTotals(last)
                if let total = JSONDictionary.dictionary(info, "total_token_usage") {
                    cumulative = RawTokenTotals(total).asCumulative
                }
            } else if let total = JSONDictionary.dictionary(info, "total_token_usage") {
                let current = RawTokenTotals(total)
                delta = current.subtracting(cumulative)
                cumulative = current.asCumulative
            } else {
                return
            }

            // 纯状态汇报事件：last 的 input/output 都是 0，而 total_tokens 报的是
            // 当前上下文窗口大小，不是消耗。实测 5366 条里有 49 条，累计计数器
            // 在这些事件上也一动没动。把 total_tokens 当成 output 会凭空造 token。
            guard delta.inputTokens > 0 || delta.outputTokens > 0 else { return }

            eventSeq += 1
            events.append(
                UsageEvent(
                    eventSeq: eventSeq,
                    observedAt: observedAt,
                    modelName: modelName,
                    messageId: nil,
                    requestId: nil,
                    // Codex 的 input 含 cached，必须减掉，否则缓存 token 被计两遍。
                    // 最大的 session 里 cached 占 input 的 94.6%，漏了这行数字翻倍。
                    inputTokens: max(0, delta.inputTokens - delta.cachedInputTokens),
                    outputTokens: delta.outputTokens,
                    reasoningTokens: delta.reasoningTokens,
                    cacheReadTokens: delta.cachedInputTokens,
                    cacheWrite5mTokens: 0,
                    cacheWrite1hTokens: 0,
                    reportedCostUSDMicros: nil,
                    sourceOffset: line.offset,
                    isSidechain: false
                )
            )
        default:
            return
        }
    }

    public func finish(sourceURL: URL) throws -> (session: ParsedSession, state: ParserState) {
        guard let sessionKey else { throw LocalAgentParserError.missingSessionKey }

        let session = ParsedSession(
            sourceKind: .codexJSONL,
            sessionKey: sessionKey,
            projectPath: projectPath,
            cliVersion: nil,
            startedAt: startedAt,
            updatedAt: updatedAt,
            events: events,
            rawMeta: ["source": "codex"]
        )
        return (
            session,
            ParserState(
                lastEventSeq: eventSeq,
                lastCumulative: cumulative,
                sessionKey: sessionKey,
                projectPath: projectPath,
                modelName: modelName,
                startedAt: startedAt,
                updatedAt: updatedAt
            )
        )
    }

    private func timestamp(in object: [String: Any]) -> Date? {
        if let value = JSONDictionary.string(object, "timestamp") {
            for formatter in dateFormatters {
                if let date = formatter.date(from: value) { return date }
            }
            if let seconds = Double(value) { return dateFromEpoch(seconds) }
        }
        if let numeric = JSONDictionary.double(object, "timestamp") {
            return dateFromEpoch(numeric)
        }
        return nil
    }

    /// Codex 有时写秒、有时写毫秒。用 10^11 作阈值区分（约公元 5138 年的秒数）。
    private func dateFromEpoch(_ value: Double) -> Date {
        value > 100_000_000_000 ? Date(timeIntervalSince1970: value / 1000) : Date(timeIntervalSince1970: value)
    }
}

/// Codex `token_count` 事件里的原始四元组。
/// 语义：`input` **含** `cached`，`output` **含** `reasoning`。
private struct RawTokenTotals {
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let outputTokens: Int64
    let reasoningTokens: Int64

    init(_ object: [String: Any]) {
        inputTokens = JSONDictionary.int64(object, "input_tokens") ?? 0
        cachedInputTokens = JSONDictionary.int64(object, "cached_input_tokens") ?? 0
        outputTokens = JSONDictionary.int64(object, "output_tokens") ?? 0
        reasoningTokens = JSONDictionary.int64(object, "reasoning_output_tokens") ?? 0
    }

    private init(inputTokens: Int64, cachedInputTokens: Int64, outputTokens: Int64, reasoningTokens: Int64) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
    }

    var asCumulative: CumulativeTokenTotals {
        CumulativeTokenTotals(
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens
        )
    }

    /// 累计值差分。若新值小于基线（compacted 导致的重置），把新值本身当作增量。
    /// 实测：本机 5366 条事件、569 个 compacted，累计值一次都没减过。这是防御。
    func subtracting(_ baseline: CumulativeTokenTotals?) -> RawTokenTotals {
        guard let baseline, inputTokens >= baseline.inputTokens, outputTokens >= baseline.outputTokens else {
            return self
        }
        return RawTokenTotals(
            inputTokens: inputTokens - baseline.inputTokens,
            cachedInputTokens: max(0, cachedInputTokens - baseline.cachedInputTokens),
            outputTokens: outputTokens - baseline.outputTokens,
            reasoningTokens: max(0, reasoningTokens - baseline.reasoningTokens)
        )
    }
}
