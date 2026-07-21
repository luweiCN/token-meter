import Foundation

public final class CodexUsageEventParser: UsageEventParser {
    private var sessionKey: String?
    private var projectPath: String?
    private var modelName: String?
    private var startedAt: Date?
    private var updatedAt: Date?
    private var rootThreadId: String?
    private var subagentLabel: String?
    private var events: [UsageEvent] = []
    private var pendingModelEvents: [PendingCodexEvent] = []
    private var eventSeq: Int
    private var cumulative: CumulativeTokenTotals?
    private var unresolvedModelEvents = false

    // Fork/replay gate。Codex 的 child rollout 会先复制父历史，再进入自己的首个 turn。
    private var forkedFromId: String?
    private var childSessionId: String?
    private var replaySessionId: String?
    private var waitingForTurnContext: Bool
    private var inheritedBaseline: CumulativeTokenTotals?
    private var inheritedReportedTotal: Int64?
    private var taskStartedTurnIDs: Set<String>
    private var isUserFork: Bool

    private let dateFormatters = ClaudeCodeUsageEventParser.makeDateFormatters()

    public init(resuming state: ParserState?) {
        eventSeq = state?.lastEventSeq ?? 0
        cumulative = state?.lastCumulative
        sessionKey = state?.sessionKey
        projectPath = state?.projectPath
        modelName = state?.modelName
        startedAt = state?.startedAt
        updatedAt = state?.updatedAt
        rootThreadId = state?.rootSessionKey
        subagentLabel = state?.subagentLabel

        forkedFromId = state?.codexForkedFromId
        childSessionId = state?.codexChildSessionId
        replaySessionId = state?.codexReplaySessionId
        waitingForTurnContext = state?.codexWaitingForTurnContext ?? false
        inheritedBaseline = state?.codexInheritedBaseline
        inheritedReportedTotal = state?.codexInheritedReportedTotal
        taskStartedTurnIDs = state?.codexTaskStartedTurnIDs ?? []
        isUserFork = state?.codexIsUserFork ?? false
    }

    public func consume(_ line: JSONLLine) {
        guard let object = JSONDictionary.object(from: line.text) else { return }
        let entryType = JSONDictionary.string(object, "type")
        let payload = JSONDictionary.dictionary(object, "payload")

        if let timestamp = timestamp(in: object) {
            if startedAt == nil { startedAt = timestamp }
            updatedAt = timestamp
        }

        guard let payload else { return }
        let payloadModel = extractModel(from: payload)
        let payloadType = JSONDictionary.string(payload, "type")
        let isTokenCount = entryType == "event_msg" && payloadType == "token_count"
        let info = isTokenCount ? JSONDictionary.dictionary(payload, "info") : nil
        let infoModel = info.flatMap(extractModel(fromInfo:))
        let eventModel = payloadModel ?? infoModel

        if waitingForTurnContext {
            if entryType == "turn_context",
               forkedChildTurnStartsOwnSession(turnID: JSONDictionary.string(payload, "turn_id")) {
                waitingForTurnContext = false
                replaySessionId = nil
                taskStartedTurnIDs.removeAll()
                isUserFork = false
                if let childSessionId { sessionKey = childSessionId }
                if let payloadModel { modelName = payloadModel }
                projectPath = JSONDictionary.string(payload, "cwd") ?? projectPath
                if let modelName { flushPendingModelEvents(model: modelName) }
                return
            }

            if entryType == "event_msg", payloadType == "task_started" {
                let turnID = JSONDictionary.string(payload, "turn_id")
                let startedAt = JSONDictionary.int64(payload, "started_at")
                    ?? JSONDictionary.double(payload, "started_at").map(Int64.init)
                if forkedChildTaskStartsOwnSession(turnID: turnID, startedAt: startedAt),
                   let turnID {
                    taskStartedTurnIDs.insert(turnID)
                }
            } else if entryType == "session_meta",
                      let id = JSONDictionary.string(payload, "id"),
                      id != childSessionId {
                replaySessionId = id
            }

            if isTokenCount, let info {
                rememberInheritedBaseline(info: info)
            }
            return
        }

        // 模型迟到时先缓冲 token_count；一旦出现明确的非 token 边界且仍无模型，就按 unknown
        // 落地并要求下次追加后全量重放，避免永久把旧事件锁成 unknown。
        if !pendingModelEvents.isEmpty,
           eventModel == nil,
           !isTokenCount,
           entryType != "session_meta" {
            flushPendingModelEventsAsUnknown()
        }

        switch entryType {
        case "session_meta":
            consumeSessionMeta(payload)

        case "turn_context":
            if let payloadModel { modelName = payloadModel }
            projectPath = JSONDictionary.string(payload, "cwd") ?? projectPath
            if let modelName { flushPendingModelEvents(model: modelName) }

        case "event_msg":
            guard isTokenCount, let info, let observedAt = timestamp(in: object) else { return }
            consumeTokenCount(
                info: info,
                observedAt: observedAt,
                sourceOffset: line.offset,
                eventModel: eventModel
            )

        default:
            return
        }
    }

    public func finish(sourceURL: URL) throws -> (session: ParsedSession?, state: ParserState) {
        flushPendingModelEventsAsUnknown()
        guard let sessionKey else { throw LocalAgentParserError.missingSessionKey }

        let session = ParsedSession(
            sourceKind: .codexJSONL,
            sessionKey: sessionKey,
            projectPath: projectPath,
            cliVersion: nil,
            startedAt: startedAt,
            updatedAt: updatedAt,
            events: events,
            rawMeta: ["source": "codex"],
            rootSessionKey: rootThreadId,
            subagentLabel: subagentLabel
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
                updatedAt: updatedAt,
                rootSessionKey: rootThreadId,
                subagentLabel: subagentLabel,
                requiresFullReplay: unresolvedModelEvents ? true : nil,
                codexForkedFromId: forkedFromId,
                codexChildSessionId: childSessionId,
                codexReplaySessionId: replaySessionId,
                codexWaitingForTurnContext: waitingForTurnContext,
                codexInheritedBaseline: inheritedBaseline,
                codexInheritedReportedTotal: inheritedReportedTotal,
                codexTaskStartedTurnIDs: taskStartedTurnIDs,
                codexIsUserFork: isUserFork
            )
        )
    }

    private func consumeSessionMeta(_ payload: [String: Any]) {
        let id = JSONDictionary.string(payload, "id")
        sessionKey = id ?? sessionKey
        projectPath = JSONDictionary.string(payload, "cwd") ?? projectPath

        let spawn = JSONDictionary.dictionary(payload, "source")
            .flatMap { JSONDictionary.dictionary($0, "subagent") }
            .flatMap { JSONDictionary.dictionary($0, "thread_spawn") }
        let parent = firstString(in: payload, keys: ["forked_from_id", "parent_thread_id"])
            ?? spawn.flatMap { JSONDictionary.string($0, "parent_thread_id") }
        if let parent {
            let repeatedActiveChildMeta = !waitingForTurnContext
                && id != nil
                && childSessionId == id
            forkedFromId = parent
            rootThreadId = parent
            childSessionId = id
            if !repeatedActiveChildMeta {
                waitingForTurnContext = true
                replaySessionId = nil
                inheritedBaseline = nil
                inheritedReportedTotal = nil
                taskStartedTurnIDs.removeAll()
                let sourceString = payload["source"] as? String
                isUserFork = JSONDictionary.string(payload, "thread_source") == "user"
                    || sourceString == "user"
            }
        }

        let role = JSONDictionary.string(payload, "agent_role")
            ?? spawn.flatMap { JSONDictionary.string($0, "agent_role") }
        let nickname = JSONDictionary.string(payload, "agent_nickname")
            ?? spawn.flatMap { JSONDictionary.string($0, "agent_nickname") }
        subagentLabel = [role, nickname].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
            ?? subagentLabel
    }

    private func consumeTokenCount(
        info: [String: Any],
        observedAt: Date,
        sourceOffset: Int64,
        eventModel: String?
    ) {
        let totalObject = JSONDictionary.dictionary(info, "total_token_usage")
        let lastObject = JSONDictionary.dictionary(info, "last_token_usage")
        let total = totalObject.map(RawTokenTotals.init)
        let last = lastObject.map(RawTokenTotals.init)

        if shouldSkipInheritedSnapshot(totalObject: totalObject, total: total) {
            return
        }
        if total != nil {
            inheritedBaseline = nil
            inheritedReportedTotal = nil
        }

        let previous = cumulative.map(RawTokenTotals.init)
        let delta: RawTokenTotals
        let nextCumulative: RawTokenTotals?

        switch (total, last, previous) {
        case let (.some(total), .some(last), .some(previous)):
            if total == previous { return }
            if total.delta(from: previous) == nil,
               total.looksLikeStaleRegression(previous: previous, last: last) {
                return
            }
            delta = last
            nextCumulative = total

        case let (.some(total), .some(last), .none):
            delta = last
            nextCumulative = total

        case let (.some(total), .none, .some(previous)):
            if total == previous { return }
            guard let difference = total.delta(from: previous) else {
                // 无 last 的回退快照无法证明是新消耗；只移动基线，避免把整份上下文再计一次。
                cumulative = total.asCumulative
                return
            }
            delta = difference
            nextCumulative = total

        case let (.some(total), .none, .none):
            delta = total
            nextCumulative = total

        case let (.none, .some(last), .some(previous)):
            delta = last
            nextCumulative = previous.saturatingAdding(last)

        case let (.none, .some(last), .none):
            delta = last
            nextCumulative = nil

        case (.none, .none, _):
            return
        }

        guard delta.hasAnyTokens else { return }
        cumulative = nextCumulative?.asCumulative ?? cumulative

        let resolvedModel = eventModel ?? modelName
        if let resolvedModel { modelName = resolvedModel }
        let scopeID = forkedFromId ?? sessionKey ?? childSessionId ?? "unknown"

        eventSeq += 1
        let pending = PendingCodexEvent(
            event: UsageEvent(
                eventSeq: eventSeq,
                observedAt: observedAt,
                modelName: nil,
                messageId: nil,
                dedupeKey: nil,
                inputTokens: delta.billableInputTokens,
                outputTokens: delta.outputTokens,
                reasoningTokens: delta.reasoningTokens,
                cacheReadTokens: delta.billableCacheReadTokens,
                cacheWrite5mTokens: 0,
                cacheWrite1hTokens: 0,
                reportedCostUSDMicros: nil,
                sourceOffset: sourceOffset,
                isSidechain: rootThreadId != nil
            ),
            rawDelta: delta,
            total: total,
            dedupeScopeKey: "codex:\(scopeID)"
        )

        if let resolvedModel {
            if !pendingModelEvents.isEmpty { flushPendingModelEvents(model: resolvedModel) }
            events.append(resolvedEvent(pending, model: resolvedModel))
        } else {
            pendingModelEvents.append(pending)
        }
    }

    private func resolvedEvent(_ pending: PendingCodexEvent, model: String?) -> UsageEvent {
        let event = pending.event
        let modelKey = model ?? "unknown"
        let dedupeKey: String
        if let total = pending.total {
            dedupeKey = [
                "total", modelKey,
                String(total.inputTokens), String(total.cachedInputTokens),
                String(total.outputTokens), String(total.reasoningTokens)
            ].joined(separator: "\u{1F}")
        } else {
            dedupeKey = [
                "last", modelKey, String(event.observedEpochMilliseconds),
                String(pending.rawDelta.inputTokens), String(pending.rawDelta.cachedInputTokens),
                String(pending.rawDelta.outputTokens), String(pending.rawDelta.reasoningTokens)
            ].joined(separator: "\u{1F}")
        }

        return UsageEvent(
            eventSeq: event.eventSeq,
            observedAt: event.observedAt,
            modelName: model,
            messageId: event.messageId,
            dedupeKey: dedupeKey,
            dedupeScopeKey: pending.dedupeScopeKey,
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

    private func flushPendingModelEvents(model: String) {
        events.append(contentsOf: pendingModelEvents.map { resolvedEvent($0, model: model) })
        pendingModelEvents.removeAll(keepingCapacity: true)
    }

    private func flushPendingModelEventsAsUnknown() {
        guard !pendingModelEvents.isEmpty else { return }
        unresolvedModelEvents = true
        events.append(contentsOf: pendingModelEvents.map { resolvedEvent($0, model: nil) })
        pendingModelEvents.removeAll(keepingCapacity: true)
    }

    private func rememberInheritedBaseline(info: [String: Any]) {
        guard let totalObject = JSONDictionary.dictionary(info, "total_token_usage") else { return }
        let total = RawTokenTotals(totalObject)
        cumulative = total.asCumulative
        inheritedBaseline = total.asCumulative
        if let reported = JSONDictionary.int64(totalObject, "total_tokens"), reported >= 0 {
            inheritedReportedTotal = reported
        }
    }

    private func shouldSkipInheritedSnapshot(
        totalObject: [String: Any]?,
        total: RawTokenTotals?
    ) -> Bool {
        if let totalObject,
           let baseline = inheritedReportedTotal,
           let reported = JSONDictionary.int64(totalObject, "total_tokens"),
           reported >= 0,
           reported <= baseline {
            return true
        }
        if let total, let inheritedBaseline {
            return total.isWithin(RawTokenTotals(inheritedBaseline))
        }
        return false
    }

    private func forkedChildTurnStartsOwnSession(turnID: String?) -> Bool {
        guard replaySessionId != nil else { return true }
        guard let childSessionId else { return true }
        guard let childKey = uuidV7OrderKey(childSessionId), let turnID else { return true }
        guard let turnKey = uuidV7OrderKey(turnID) else {
            return isUserFork || taskStartedTurnIDs.contains(turnID)
        }

        let turnMilliseconds = String(turnKey.prefix(12))
        let childMilliseconds = String(childKey.prefix(12))
        if turnMilliseconds > childMilliseconds { return true }
        if turnMilliseconds < childMilliseconds { return false }
        return isUserFork || taskStartedTurnIDs.contains(turnID)
    }

    private func forkedChildTaskStartsOwnSession(turnID: String?, startedAt: Int64?) -> Bool {
        guard let turnID, let childSessionId else { return false }
        guard let childKey = uuidV7OrderKey(childSessionId) else { return true }
        if let turnKey = uuidV7OrderKey(turnID) {
            return String(turnKey.prefix(12)) >= String(childKey.prefix(12))
        }
        guard let startedAt,
              let childMilliseconds = Int64(String(childKey.prefix(12)), radix: 16) else {
            return false
        }
        return startedAt >= childMilliseconds / 1_000
    }

    private func uuidV7OrderKey(_ id: String) -> String? {
        let parts = id.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5,
              parts[0].count == 8, parts[1].count == 4, parts[2].count == 4,
              parts[3].count == 4, parts[4].count == 12,
              parts[2].first == "7" else { return nil }
        let key = parts.joined().lowercased()
        guard key.allSatisfy(\.isHexDigit) else { return nil }
        return key
    }

    private func extractModel(from payload: [String: Any]) -> String? {
        if let modelInfo = JSONDictionary.dictionary(payload, "model_info"),
           let slug = JSONDictionary.string(modelInfo, "slug"),
           !slug.isEmpty {
            return slug
        }
        return firstString(in: payload, keys: ["model", "model_name"])
    }

    private func extractModel(fromInfo info: [String: Any]) -> String? {
        firstString(in: info, keys: ["model", "model_name"])
    }

    private func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = JSONDictionary.string(object, key), !value.isEmpty { return value }
        }
        return nil
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

    private func dateFromEpoch(_ value: Double) -> Date {
        value > 100_000_000_000
            ? Date(timeIntervalSince1970: value / 1_000)
            : Date(timeIntervalSince1970: value)
    }
}

private struct PendingCodexEvent {
    let event: UsageEvent
    let rawDelta: RawTokenTotals
    let total: RawTokenTotals?
    let dedupeScopeKey: String
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Codex `token_count` 的原始累计四元组。`input` 含 cache，`output` 含 reasoning。
private struct RawTokenTotals: Equatable {
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let outputTokens: Int64
    let reasoningTokens: Int64

    init(_ object: [String: Any]) {
        inputTokens = max(0, JSONDictionary.int64(object, "input_tokens") ?? 0)
        cachedInputTokens = max(
            0,
            JSONDictionary.int64(object, "cached_input_tokens") ?? 0,
            JSONDictionary.int64(object, "cache_read_input_tokens") ?? 0
        )
        outputTokens = max(0, JSONDictionary.int64(object, "output_tokens") ?? 0)
        reasoningTokens = max(0, JSONDictionary.int64(object, "reasoning_output_tokens") ?? 0)
    }

    init(_ cumulative: CumulativeTokenTotals) {
        inputTokens = max(0, cumulative.inputTokens)
        cachedInputTokens = max(0, cumulative.cachedInputTokens)
        outputTokens = max(0, cumulative.outputTokens)
        reasoningTokens = max(0, cumulative.reasoningTokens)
    }

    private init(input: Int64, cached: Int64, output: Int64, reasoning: Int64) {
        inputTokens = input
        cachedInputTokens = cached
        outputTokens = output
        reasoningTokens = reasoning
    }

    var asCumulative: CumulativeTokenTotals {
        CumulativeTokenTotals(
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens
        )
    }

    var hasAnyTokens: Bool {
        inputTokens > 0 || cachedInputTokens > 0 || outputTokens > 0 || reasoningTokens > 0
    }

    var billableCacheReadTokens: Int64 { min(cachedInputTokens, inputTokens) }
    var billableInputTokens: Int64 { max(0, inputTokens - billableCacheReadTokens) }

    func delta(from previous: RawTokenTotals) -> RawTokenTotals? {
        guard inputTokens >= previous.inputTokens,
              cachedInputTokens >= previous.cachedInputTokens,
              outputTokens >= previous.outputTokens,
              reasoningTokens >= previous.reasoningTokens else { return nil }
        return RawTokenTotals(
            input: inputTokens - previous.inputTokens,
            cached: cachedInputTokens - previous.cachedInputTokens,
            output: outputTokens - previous.outputTokens,
            reasoning: reasoningTokens - previous.reasoningTokens
        )
    }

    func isWithin(_ baseline: RawTokenTotals) -> Bool {
        inputTokens <= baseline.inputTokens
            && cachedInputTokens <= baseline.cachedInputTokens
            && outputTokens <= baseline.outputTokens
            && reasoningTokens <= baseline.reasoningTokens
    }

    func saturatingAdding(_ other: RawTokenTotals) -> RawTokenTotals {
        RawTokenTotals(
            input: saturatingAdd(inputTokens, other.inputTokens),
            cached: saturatingAdd(cachedInputTokens, other.cachedInputTokens),
            output: saturatingAdd(outputTokens, other.outputTokens),
            reasoning: saturatingAdd(reasoningTokens, other.reasoningTokens)
        )
    }

    func looksLikeStaleRegression(previous: RawTokenTotals, last: RawTokenTotals) -> Bool {
        let previousTotal = previous.magnitude
        let currentTotal = magnitude
        let lastTotal = last.magnitude
        guard previousTotal > 0, currentTotal > 0, lastTotal > 0 else { return false }
        return Double(currentTotal) >= Double(previousTotal) * 0.98
            || Double(currentTotal) + Double(lastTotal) * 2 >= Double(previousTotal)
    }

    private var magnitude: Int64 {
        [inputTokens, cachedInputTokens, outputTokens, reasoningTokens]
            .reduce(0, saturatingAdd)
    }

    private func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int64.max : result.partialValue
    }
}
