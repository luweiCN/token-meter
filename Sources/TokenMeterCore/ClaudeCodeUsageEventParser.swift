import Foundation

public final class ClaudeCodeUsageEventParser: UsageEventParser {
    private var sessionKey: String?
    private var projectPath: String?
    private var cliVersion: String?
    private var startedAt: Date?
    private var updatedAt: Date?
    private var events: [UsageEvent] = []
    private var eventSeq: Int
    private let dateFormatters = ClaudeCodeUsageEventParser.makeDateFormatters()

    public init(resuming state: ParserState?) {
        eventSeq = state?.lastEventSeq ?? 0
        // 续读的追加片段里若缺 sessionId / cwd / version，从 state 恢复，避免丢会话身份。
        sessionKey = state?.sessionKey
        projectPath = state?.projectPath
        cliVersion = state?.cliVersion
        startedAt = state?.startedAt
        updatedAt = state?.updatedAt
    }

    public func consume(_ line: JSONLLine) {
        guard let object = JSONDictionary.object(from: line.text) else { return }

        sessionKey = firstString(in: object, keys: ["sessionId", "session_id", "leafUuid", "leaf_uuid"]) ?? sessionKey
        projectPath = firstString(in: object, keys: ["cwd", "project_path", "projectPath"]) ?? projectPath
        cliVersion = firstString(in: object, keys: ["version", "cliVersion", "cli_version"]) ?? cliVersion

        let timestamp = timestamp(in: object)
        if let timestamp {
            if startedAt == nil { startedAt = timestamp }
            updatedAt = timestamp
        }

        guard let message = JSONDictionary.dictionary(object, "message"),
              let usageObject = JSONDictionary.dictionary(message, "usage"),
              let observedAt = timestamp else {
            return
        }

        let type = firstString(in: object, keys: ["type"])
        let role = firstString(in: message, keys: ["role"])
        guard type == nil || type == "assistant" || role == "assistant" else { return }

        let inputTokens = JSONDictionary.int64(usageObject, "input_tokens") ?? 0
        let outputTokens = JSONDictionary.int64(usageObject, "output_tokens") ?? 0
        let cacheReadTokens = JSONDictionary.int64(usageObject, "cache_read_input_tokens") ?? 0
        let (write5m, write1h) = cacheWriteTiers(in: usageObject)

        guard inputTokens + outputTokens + cacheReadTokens + write5m + write1h > 0 else { return }

        eventSeq += 1
        events.append(
            UsageEvent(
                eventSeq: eventSeq,
                observedAt: observedAt,
                modelName: firstString(in: message, keys: ["model", "modelName", "model_name"]),
                messageId: firstString(in: message, keys: ["id"]),
                requestId: firstString(in: object, keys: ["requestId", "request_id"]),
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                reasoningTokens: 0,
                cacheReadTokens: cacheReadTokens,
                cacheWrite5mTokens: write5m,
                cacheWrite1hTokens: write1h,
                reportedCostUSDMicros: nil,
                sourceOffset: line.offset,
                isSidechain: bool(in: object, keys: ["isSidechain", "is_sidechain"]) ?? false
            )
        )
    }

    public func finish(sourceURL: URL) throws -> (session: ParsedSession, state: ParserState) {
        guard let sessionKey else { throw LocalAgentParserError.missingSessionKey }

        let session = ParsedSession(
            sourceKind: .claudeJSONL,
            sessionKey: sessionKey,
            projectPath: projectPath,
            cliVersion: cliVersion,
            startedAt: startedAt,
            updatedAt: updatedAt,
            events: events,
            rawMeta: ["source": "claude-code"]
        )
        return (
            session,
            ParserState(
                lastEventSeq: eventSeq,
                lastCumulative: nil,
                sessionKey: sessionKey,
                projectPath: projectPath,
                cliVersion: cliVersion,
                startedAt: startedAt,
                updatedAt: updatedAt
            )
        )
    }

    /// Claude 新版把缓存写入拆成 5 分钟 / 1 小时两档，两档单价不同。
    /// 老版本只有合计字段，此时整笔归入 5m 档。
    private func cacheWriteTiers(in usage: [String: Any]) -> (write5m: Int64, write1h: Int64) {
        if let breakdown = JSONDictionary.dictionary(usage, "cache_creation") {
            return (
                JSONDictionary.int64(breakdown, "ephemeral_5m_input_tokens") ?? 0,
                JSONDictionary.int64(breakdown, "ephemeral_1h_input_tokens") ?? 0
            )
        }
        return (JSONDictionary.int64(usage, "cache_creation_input_tokens") ?? 0, 0)
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

    private func bool(in object: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = object[key] as? Bool { return value }
        }
        return nil
    }

    /// Codex 与 omp 的 parser 也会复用这个，避免三份重复定义。
    static func makeDateFormatters() -> [ISO8601DateFormatter] {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [withFractional, plain]
    }
}
