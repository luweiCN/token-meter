import Foundation

public final class OmpUsageEventParser: UsageEventParser {
    private var sessionKey: String?
    private var projectPath: String?
    private var modelName: String?
    private var startedAt: Date?
    private var updatedAt: Date?
    private var events: [UsageEvent] = []
    private var eventSeq: Int
    private let dateFormatters = ClaudeCodeUsageEventParser.makeDateFormatters()

    public init(resuming state: ParserState?) {
        eventSeq = state?.lastEventSeq ?? 0
        // session / model_change 行只在文件开头出现；续读片段没有它们，从 state 恢复会话身份。
        sessionKey = state?.sessionKey
        projectPath = state?.projectPath
        modelName = state?.modelName
        startedAt = state?.startedAt
        updatedAt = state?.updatedAt
    }

    public func consume(_ line: JSONLLine) {
        guard let object = JSONDictionary.object(from: line.text) else { return }

        let timestamp = timestamp(in: object)
        if let timestamp {
            if startedAt == nil { startedAt = timestamp }
            updatedAt = timestamp
        }

        switch JSONDictionary.string(object, "type") {
        // omp 真实用的是 "session"（46/46 抽样文件都有，带 id + cwd）。
        // "session_meta" 是 Codex 的结构，omp 里一次都没出现过——照抄它会让
        // projectPath 永远为 nil，而 fixture 若也照抄，测试永远绿着。
        //
        // 绝不能把 "session_init" 也放进来。943/1002 个 omp 文件是子 agent 文件，
        // 它们同时有 session 行（UUID + cwd）和随后的 session_init 行（8 位短 spawn
        // id、无 cwd）。这个 case 分支不是「识别」而是「赋值」，后命中的会覆盖先命中的，
        // sessionKey 就从 UUID 变成了短串。
        case "session", "session_meta":
            sessionKey = firstString(in: object, keys: ["id", "sessionId", "session_id"]) ?? sessionKey
            projectPath = firstString(in: object, keys: ["cwd", "directory"]) ?? projectPath
            modelName = firstString(in: object, keys: ["model", "modelName"]) ?? modelName
        case "model_change", "modelChange":
            modelName = firstString(in: object, keys: ["model", "modelName"]) ?? modelName
        case "message":
            guard let message = JSONDictionary.dictionary(object, "message"),
                  let usage = JSONDictionary.dictionary(message, "usage"),
                  let observedAt = timestamp else {
                return
            }
            modelName = firstString(in: message, keys: ["model", "modelName"]) ?? modelName

            // omp 的 input 不含 cache，原样取值。
            // Codex 那边要减 cached，这里不能照抄——两家的 input 语义相反。
            let inputTokens = JSONDictionary.int64(usage, "input") ?? 0
            let outputTokens = JSONDictionary.int64(usage, "output") ?? 0
            let cacheReadTokens = JSONDictionary.int64(usage, "cacheRead") ?? 0
            let cacheWriteTokens = JSONDictionary.int64(usage, "cacheWrite") ?? 0
            let reasoningTokens = JSONDictionary.int64(usage, "reasoningTokens") ?? 0

            guard inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens > 0 else { return }

            eventSeq += 1
            events.append(
                UsageEvent(
                    eventSeq: eventSeq,
                    observedAt: observedAt,
                    modelName: modelName,
                    messageId: nil,
                    requestId: nil,
                    // omp 无稳定的逐消息指纹，保持今天的行为：不参与去重。
                    dedupeKey: nil,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    reasoningTokens: reasoningTokens,
                    cacheReadTokens: cacheReadTokens,
                    // omp 不区分缓存写入档位，整笔归 5m
                    cacheWrite5mTokens: cacheWriteTokens,
                    cacheWrite1hTokens: 0,
                    reportedCostUSDMicros: reportedCost(in: usage),
                    sourceOffset: line.offset,
                    isSidechain: false
                )
            )
        default:
            return
        }
    }

    public func finish(sourceURL: URL) throws -> (session: ParsedSession?, state: ParserState) {
        let resolvedSessionKey = sessionKey ?? sourceURL.deletingPathExtension().lastPathComponent
        guard !resolvedSessionKey.isEmpty else { throw LocalAgentParserError.missingSessionKey }

        let session = ParsedSession(
            sourceKind: .ompJSONL,
            sessionKey: resolvedSessionKey,
            projectPath: projectPath,
            cliVersion: nil,
            startedAt: startedAt,
            updatedAt: updatedAt,
            events: events,
            rawMeta: ["source": "omp"]
        )
        return (
            session,
            ParserState(
                lastEventSeq: eventSeq,
                lastCumulative: nil,
                sessionKey: resolvedSessionKey,
                projectPath: projectPath,
                modelName: modelName,
                startedAt: startedAt,
                updatedAt: updatedAt
            )
        )
    }

    /// cost == 0 表示 omp 不知道单价（套餐制），交给 CostCalculator 自算。
    /// 存 0 会让「不知道」看起来像「免费」。
    private func reportedCost(in usage: [String: Any]) -> Int64? {
        guard let cost = JSONDictionary.dictionary(usage, "cost"),
              let total = JSONDictionary.double(cost, "total"),
              total > 0 else {
            return nil
        }
        return Int64((total * 1_000_000).rounded())
    }

    private func timestamp(in object: [String: Any]) -> Date? {
        guard let value = firstString(in: object, keys: ["timestamp", "created_at", "createdAt"]) else { return nil }
        for formatter in dateFormatters {
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = JSONDictionary.string(object, key), !value.isEmpty { return value }
        }
        return nil
    }
}
