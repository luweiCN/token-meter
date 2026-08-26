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
    private var fallbackEvents: [UsageEvent] = []
    private var eventSeq: Int
    private var grokSawUsage: Bool
    private var resumeOffset: Int64
    private var lastTotal: Int64?
    private var activeTurn: ActiveTurn?
    private var fallbackTurnIndex: Int
    private let resumedWithoutUsage: Bool
    private let resumedEventSeq: Int

    private struct ActiveTurn {
        var baseline: Int64
        var maxTotal: Int64
        var timestamp: Date
        var offset: Int64
        var index: Int
    }

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
        lastTotal = state?.lastCumulative?.inputTokens
        fallbackTurnIndex = 0
        resumedWithoutUsage = !(state?.grokSawUsage ?? false)
        resumedEventSeq = state?.lastEventSeq ?? 0
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

        let sessionUpdate = params
            .flatMap { JSONDictionary.dictionary($0, "update") }
            .flatMap { JSONDictionary.string($0, "sessionUpdate") }
        if sessionUpdate == "user_message_chunk" {
            flushFallbackTurn()
            let baseline = lastTotal ?? 0
            activeTurn = ActiveTurn(
                baseline: baseline,
                maxTotal: baseline,
                timestamp: timestamp ?? Date(),
                offset: line.offset,
                index: fallbackTurnIndex
            )
            fallbackTurnIndex += 1
        }

        if let usage = usageObject(params: params) {
            grokSawUsage = true
            consumeUsage(usage, object: object, params: params, timestamp: timestamp, line: line)
            return
        }

        if let total = metaInt64(object: object, params: params, key: "totalTokens"), total >= 0 {
            consumeTotalTokens(total, timestamp: timestamp, offset: line.offset)
        }
    }

    private func consumeUsage(
        _ usage: [String: Any],
        object: [String: Any],
        params: [String: Any]?,
        timestamp: Date?,
        line: JSONLLine
    ) {

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

    private func consumeTotalTokens(_ total: Int64, timestamp: Date?, offset: Int64) {
        if let previous = lastTotal, total < previous {
            return
        }
        if activeTurn == nil {
            let baseline = lastTotal ?? 0
            activeTurn = ActiveTurn(
                baseline: baseline,
                maxTotal: baseline,
                timestamp: timestamp ?? Date(),
                offset: offset,
                index: fallbackTurnIndex
            )
            fallbackTurnIndex += 1
        }
        if var turn = activeTurn {
            if total > turn.maxTotal {
                turn.maxTotal = total
                if let timestamp { turn.timestamp = timestamp }
                turn.offset = offset
                activeTurn = turn
            }
        }
        lastTotal = total
    }

    private func flushFallbackTurn() {
        guard let turn = activeTurn else { return }
        activeTurn = nil
        let delta = turn.maxTotal - turn.baseline
        guard delta > 0 else { return }
        eventSeq += 1
        let session = sessionKey ?? "unknown"
        fallbackEvents.append(
            UsageEvent(
                eventSeq: eventSeq,
                observedAt: turn.timestamp,
                modelName: modelName,
                messageId: nil,
                dedupeKey: "grok:\(session):delta:\(turn.index)",
                inputTokens: delta,
                outputTokens: 0,
                reasoningTokens: 0,
                cacheReadTokens: 0,
                cacheWrite5mTokens: 0,
                cacheWrite1hTokens: 0,
                reportedCostUSDMicros: nil,
                sourceOffset: turn.offset
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

        if !grokSawUsage {
            flushFallbackTurn()
        }

        applySummarySidecar(nextTo: sourceURL)

        let emitted = grokSawUsage ? events : fallbackEvents
        let requiresReplay = grokSawUsage && resumedWithoutUsage && resumedEventSeq > 0

        let state = ParserState(
            lastEventSeq: eventSeq,
            lastCumulative: lastTotal.map { CumulativeTokenTotals(inputTokens: $0) },
            sessionKey: sessionKey,
            projectPath: projectPath,
            modelName: modelName,
            startedAt: startedAt,
            updatedAt: updatedAt,
            rootSessionKey: rootSessionKey,
            subagentLabel: subagentLabel,
            requiresFullReplay: requiresReplay ? true : nil,
            grokSawUsage: grokSawUsage,
            resumeOffset: resumeOffset
        )

        guard !emitted.isEmpty, let sessionKey, !sessionKey.isEmpty else {
            return (nil, state)
        }

        let session = ParsedSession(
            sourceKind: .grokJSONL,
            sessionKey: sessionKey,
            projectPath: projectPath,
            cliVersion: nil,
            startedAt: startedAt ?? emitted.first?.observedAt,
            updatedAt: updatedAt ?? emitted.last?.observedAt,
            events: emitted,
            rawMeta: ["source": "grok"],
            rootSessionKey: rootSessionKey,
            subagentLabel: subagentLabel
        )
        return (session, state)
    }

    private func applySummarySidecar(nextTo sourceURL: URL) {
        let sidecar = sourceURL.deletingLastPathComponent().appendingPathComponent("summary.json")
        if let data = try? Data(contentsOf: sidecar),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if projectPath == nil {
                if let info = JSONDictionary.dictionary(object, "info"),
                   let cwd = JSONDictionary.string(info, "cwd"), !cwd.isEmpty {
                    projectPath = cwd
                } else if let cwd = JSONDictionary.string(object, "cwd"), !cwd.isEmpty {
                    projectPath = cwd
                }
            }
            if rootSessionKey == nil {
                rootSessionKey = JSONDictionary.string(object, "parent_session_id")
            }
            if subagentLabel == nil {
                subagentLabel = JSONDictionary.string(object, "agent_name")
            }
            if modelName == nil {
                modelName = JSONDictionary.string(object, "current_model_id")
            }
        }

        if projectPath == nil {
            let encoded = sourceURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            if let decoded = encoded.removingPercentEncoding, !decoded.isEmpty {
                projectPath = decoded
            }
        }

        if let modelName {
            events = events.map { event in
                guard event.modelName == nil else { return event }
                return UsageEvent(
                    eventSeq: event.eventSeq,
                    observedAt: event.observedAt,
                    modelName: modelName,
                    messageId: event.messageId,
                    dedupeKey: event.dedupeKey,
                    dedupeScopeKey: event.dedupeScopeKey,
                    inputTokens: event.inputTokens,
                    outputTokens: event.outputTokens,
                    reasoningTokens: event.reasoningTokens,
                    cacheReadTokens: event.cacheReadTokens,
                    cacheWrite5mTokens: event.cacheWrite5mTokens,
                    cacheWrite1hTokens: event.cacheWrite1hTokens,
                    reportedCostUSDMicros: event.reportedCostUSDMicros,
                    sourceOffset: event.sourceOffset,
                    isSidechain: event.isSidechain
                )
            }
        }
    }

    private func metaInt64(object: [String: Any], params: [String: Any]?, key: String) -> Int64? {
        if let params,
           let meta = JSONDictionary.dictionary(params, "_meta"),
           let value = JSONDictionary.int64(meta, key) {
            return value
        }
        if let meta = JSONDictionary.dictionary(object, "_meta"),
           let value = JSONDictionary.int64(meta, key) {
            return value
        }
        return nil
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
