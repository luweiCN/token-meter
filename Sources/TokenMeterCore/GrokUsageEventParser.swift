import Foundation

public final class GrokUsageEventParser: UsageEventParser {
    private var sessionKey: String?
    private var projectPath: String?
    private var modelName: String?
    private var rootSessionKey: String?
    private var subagentLabel: String?
    private var startedAt: Date?
    private var updatedAt: Date?
    private var events: [UsageEvent] = []
    private var eventSeq: Int
    private var grokSawUsage: Bool
    private var resumeOffset: Int64

    public init(resuming state: ParserState?) {
        eventSeq = state?.lastEventSeq ?? 0
        sessionKey = state?.sessionKey
        projectPath = state?.projectPath
        modelName = state?.modelName
        rootSessionKey = state?.rootSessionKey
        subagentLabel = state?.subagentLabel
        startedAt = state?.startedAt
        updatedAt = state?.updatedAt
        grokSawUsage = state?.grokSawUsage ?? false
        resumeOffset = state?.resumeOffset ?? 0
    }

    public func consume(_ line: JSONLLine) {
        resumeOffset = line.nextOffset
        guard let object = JSONDictionary.object(from: line.text) else { return }

        let params = JSONDictionary.dictionary(object, "params")
        if let id = params.flatMap({ JSONDictionary.string($0, "sessionId") }), !id.isEmpty {
            sessionKey = id
        }

        let timestamp = observedAt(object: object, params: params)
        if let timestamp {
            if startedAt == nil { startedAt = timestamp }
            updatedAt = timestamp
        }

        guard let usage = usageObject(params: params) else { return }
        grokSawUsage = true

        let rawInput = firstInt64(in: usage, keys: ["inputTokens", "input_tokens", "promptTokens"])
        let rawOutput = firstInt64(in: usage, keys: ["outputTokens", "output_tokens", "completionTokens"])
        let cacheRead = firstInt64(in: usage, keys: [
            "cachedReadTokens", "cacheReadTokens", "cache_read_input_tokens"
        ])
        let cacheWrite = firstInt64(in: usage, keys: [
            "cacheCreationTokens", "cacheWriteTokens", "cache_creation_input_tokens"
        ])
        let reasoning = firstInt64(in: usage, keys: [
            "reasoningTokens", "thoughtTokens", "thinkingTokens"
        ])
        let input = max(0, rawInput - cacheRead)
        guard input + rawOutput + cacheRead + cacheWrite + reasoning > 0 else { return }
        guard let observedAt = timestamp else { return }

        if let unique = uniqueModelUsageKey(in: usage) {
            modelName = unique
        }

        eventSeq += 1
        let eventId = eventId(object: object, params: params) ?? "turn-\(eventSeq)"
        let session = sessionKey ?? "unknown"
        events.append(
            UsageEvent(
                eventSeq: eventSeq,
                observedAt: observedAt,
                modelName: modelName,
                messageId: eventId,
                dedupeKey: "grok:\(session):\(eventId):\(line.offset)",
                inputTokens: input,
                outputTokens: rawOutput,
                reasoningTokens: reasoning,
                cacheReadTokens: cacheRead,
                cacheWrite5mTokens: cacheWrite,
                cacheWrite1hTokens: 0,
                reportedCostUSDMicros: nil,
                sourceOffset: line.offset
            )
        )
    }

    public func finish(sourceURL: URL) throws -> (session: ParsedSession?, state: ParserState) {
        if sessionKey == nil || sessionKey?.isEmpty == true {
            let fromPath = sourceURL.deletingLastPathComponent().lastPathComponent
            if !fromPath.isEmpty, fromPath != "updates.jsonl" {
                sessionKey = fromPath
            }
        }

        let state = ParserState(
            lastEventSeq: eventSeq,
            lastCumulative: nil,
            sessionKey: sessionKey,
            projectPath: projectPath,
            modelName: modelName,
            startedAt: startedAt,
            updatedAt: updatedAt,
            rootSessionKey: rootSessionKey,
            subagentLabel: subagentLabel,
            grokSawUsage: grokSawUsage,
            resumeOffset: resumeOffset
        )

        guard !events.isEmpty, let sessionKey, !sessionKey.isEmpty else {
            return (nil, state)
        }

        let session = ParsedSession(
            sourceKind: .grokJSONL,
            sessionKey: sessionKey,
            projectPath: projectPath,
            cliVersion: nil,
            startedAt: startedAt ?? events.first?.observedAt,
            updatedAt: updatedAt ?? events.last?.observedAt,
            events: events,
            rawMeta: ["source": "grok"],
            rootSessionKey: rootSessionKey,
            subagentLabel: subagentLabel
        )
        return (session, state)
    }

    private func usageObject(params: [String: Any]?) -> [String: Any]? {
        guard let params,
              let update = JSONDictionary.dictionary(params, "update") else { return nil }
        return JSONDictionary.dictionary(update, "usage")
    }

    private func eventId(object: [String: Any], params: [String: Any]?) -> String? {
        if let params,
           let meta = JSONDictionary.dictionary(params, "_meta"),
           let id = JSONDictionary.string(meta, "eventId"), !id.isEmpty {
            return id
        }
        if let meta = JSONDictionary.dictionary(object, "_meta"),
           let id = JSONDictionary.string(meta, "eventId"), !id.isEmpty {
            return id
        }
        return nil
    }

    private func uniqueModelUsageKey(in usage: [String: Any]) -> String? {
        guard let models = JSONDictionary.dictionary(usage, "modelUsage"), models.count == 1 else {
            return nil
        }
        return models.keys.first
    }

    private func observedAt(object: [String: Any], params: [String: Any]?) -> Date? {
        if let params,
           let meta = JSONDictionary.dictionary(params, "_meta"),
           let ms = JSONDictionary.int64(meta, "agentTimestampMs") {
            return Date(timeIntervalSince1970: Double(ms) / 1000.0)
        }
        if let meta = JSONDictionary.dictionary(object, "_meta"),
           let ms = JSONDictionary.int64(meta, "agentTimestampMs") {
            return Date(timeIntervalSince1970: Double(ms) / 1000.0)
        }
        if let seconds = JSONDictionary.int64(object, "timestamp") {
            if seconds >= 1_000_000_000_000 {
                return Date(timeIntervalSince1970: Double(seconds) / 1000.0)
            }
            return Date(timeIntervalSince1970: Double(seconds))
        }
        return nil
    }

    private func firstInt64(in object: [String: Any], keys: [String]) -> Int64 {
        for key in keys {
            if let value = JSONDictionary.int64(object, key) {
                return max(0, value)
            }
        }
        return 0
    }
}
