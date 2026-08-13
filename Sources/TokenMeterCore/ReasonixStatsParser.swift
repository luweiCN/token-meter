import Foundation

/// Reasonix 用量解析：`~/.reasonix/stats/YYYY-MM-DD.jsonl`（按日一个文件）。
///
/// 每行是一次 API 请求的用量流水：
///   {"ts":"2026-08-06T13:41:56.164497+08:00","model":"go-flash/deepseek-v4-flash","source":"cli",
///    "prompt":14881,"completion":20,"reasoning":18,"cache_hit":...,"cache_miss":14881,"total":14901,"requests":1}
/// 另有 turn 计数行（只有 source/turn 两字段，无 model/token 明细）——跳过。
///
/// 字段映射（与 usage_events 语义对齐）：
///   prompt = cache_hit + cache_miss，拆成 inputTokens=cache_miss、cacheReadTokens=cache_hit；
///   outputTokens=completion、reasoningTokens=reasoning（仅展示，不计入 totalTokens，与 OpenAI 口径一致）。
/// 每个文件构成一个 ParsedSession（sessionKey = 文件名），每请求行 = 一个 UsageEvent。
/// 去重键用 ts+model+total：ts 是微秒精度时间戳，天然唯一；同键重现 = 追加重复帧，按
/// UsageEventPrecedence 全序裁决（total 更大者胜）。
public final class ReasonixStatsParser: UsageEventParser {
    private var events: [UsageEvent] = []
    private var eventSeq: Int
    private var startedAt: Date?
    private var updatedAt: Date?
    /// 是否见过带 token 明细的请求行：区分「空统计文件」与「全是 turn 行的文件」。
    private var sawUsageRow = false
    private let dateFormatters = ClaudeCodeUsageEventParser.makeDateFormatters()

    public init(resuming state: ParserState?) {
        eventSeq = state?.lastEventSeq ?? 0
        startedAt = state?.startedAt
        updatedAt = state?.updatedAt
    }

    public func consume(_ line: JSONLLine) {
        guard let object = JSONDictionary.object(from: line.text) else { return }
        // turn 计数行没有 model/token 明细，直接跳过。
        guard let model = JSONDictionary.string(object, "model"), !model.isEmpty else { return }

        guard let timestamp = timestamp(in: object) else { return }
        if startedAt == nil { startedAt = timestamp }
        updatedAt = timestamp

        let prompt = JSONDictionary.int64(object, "prompt") ?? 0
        let completion = JSONDictionary.int64(object, "completion") ?? 0
        let reasoning = JSONDictionary.int64(object, "reasoning") ?? 0
        let cacheHit = JSONDictionary.int64(object, "cache_hit") ?? 0
        let cacheMiss = JSONDictionary.int64(object, "cache_miss") ?? 0
        let total = JSONDictionary.int64(object, "total") ?? 0

        guard prompt + completion + cacheHit + cacheMiss > 0 else { return }
        sawUsageRow = true

        eventSeq += 1
        let tsKey = JSONDictionary.string(object, "ts") ?? "\(timestamp.timeIntervalSince1970)"
        events.append(
            UsageEvent(
                eventSeq: eventSeq,
                observedAt: timestamp,
                modelName: model,
                messageId: nil,
                dedupeKey: "\(tsKey)-\(model)-\(total)",
                inputTokens: cacheMiss,
                outputTokens: completion,
                reasoningTokens: reasoning,
                cacheReadTokens: cacheHit,
                cacheWrite5mTokens: 0,
                cacheWrite1hTokens: 0,
                reportedCostUSDMicros: nil,
                sourceOffset: line.offset,
                isSidechain: false
            )
        )
    }

    public func finish(sourceURL: URL) throws -> (session: ParsedSession?, state: ParserState) {
        let sessionKey = sourceURL.lastPathComponent
        let state = ParserState(
            lastEventSeq: eventSeq,
            lastCumulative: nil,
            sessionKey: sessionKey,
            projectPath: nil,
            cliVersion: nil,
            startedAt: startedAt,
            updatedAt: updatedAt
        )

        guard sawUsageRow, let first = events.first, let last = events.last else {
            // 没有请求行（空文件 / 只有 turn 行）：不是用量文件，静默跳过。
            return (nil, state)
        }

        let session = ParsedSession(
            sourceKind: .reasonixStats,
            sessionKey: sessionKey,
            projectPath: nil,
            cliVersion: nil,
            startedAt: first.observedAt,
            updatedAt: last.observedAt,
            events: events,
            rawMeta: ["source": "reasonix"]
        )
        return (session, state)
    }

    private func timestamp(in object: [String: Any]) -> Date? {
        guard let value = JSONDictionary.string(object, "ts") else { return nil }
        for formatter in dateFormatters {
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}
