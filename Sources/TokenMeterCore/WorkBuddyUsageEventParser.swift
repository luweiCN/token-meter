import Foundation

struct WorkBuddyCreditFallback: Equatable {
    let amount: Double
    let observedAt: Date?
}

/// WorkBuddy 的 JSONL 会话解析器。
///
/// WorkBuddy 把 `usage_update.used/size` 定义为会话上下文快照，不能跨 Request 相加。
/// 可加总的 Token 只取同一帧 `_meta.usage`（或持久化 `providerData.usage.details`）中的
/// 请求级明细；实际 Credits 只取 `cost.amount` / `providerData.rawUsage.credit`，明确忽略
/// `estimatedCost`。同一 Request 的最后一份 Token 快照胜出，Credit 阶段按记录 ID 去重后相加。
public final class WorkBuddyUsageEventParser: UsageEventParser {
    private final class RequestAccumulator {
        let requestID: String
        let firstOrder: Int
        var latestTimestamp: Date?
        var latestOffset: Int64
        var modelName: String?
        var tokenSnapshot: TokenSnapshot?
        var creditPicos: Int64 = 0
        var hasCredit = false
        var seenCreditStages: Set<String> = []

        init(requestID: String, firstOrder: Int, offset: Int64) {
            self.requestID = requestID
            self.firstOrder = firstOrder
            self.latestOffset = offset
        }
    }

    private struct TokenSnapshot {
        let input: Int64
        let output: Int64
        let reasoning: Int64
        let cacheRead: Int64
        let cacheWrite: Int64
    }

    private let dateFormatters = ClaudeCodeUsageEventParser.makeDateFormatters()
    private let fallbackCredits: [String: WorkBuddyCreditFallback]
    private var sessionKey: String?
    private var projectPath: String?
    private var cliVersion: String?
    private var startedAt: Date?
    private var updatedAt: Date?
    private var recordsSeen = 0
    private var requests: [String: RequestAccumulator] = [:]

    public required convenience init(resuming state: ParserState?) {
        self.init(resuming: state, fallbackCredits: [:])
    }

    init(resuming _: ParserState?, fallbackCredits: [String: WorkBuddyCreditFallback]) {
        self.fallbackCredits = fallbackCredits
    }

    public func consume(_ line: JSONLLine) {
        guard let object = JSONDictionary.object(from: line.text) else { return }
        recordsSeen += 1
        let update = JSONDictionary.dictionary(object, "update") ?? object

        sessionKey = firstNonempty([
            JSONDictionary.string(object, "sessionId"),
            JSONDictionary.string(object, "session_id"),
            JSONDictionary.string(update, "sessionId"),
            JSONDictionary.string(update, "session_id"),
        ]) ?? sessionKey
        projectPath = firstNonempty([
            JSONDictionary.string(object, "cwd"),
            JSONDictionary.string(update, "cwd"),
            JSONDictionary.string(JSONDictionary.dictionary(object, "providerData") ?? [:], "cwd"),
        ]) ?? projectPath
        cliVersion = firstNonempty([
            JSONDictionary.string(object, "version"),
            JSONDictionary.string(update, "version"),
        ]) ?? cliVersion

        let observedAt = timestamp(in: update) ?? timestamp(in: object)
        if let observedAt {
            startedAt = startedAt.map { min($0, observedAt) } ?? observedAt
            updatedAt = updatedAt.map { max($0, observedAt) } ?? observedAt
        }

        guard let requestID = requestID(update: update, envelope: object) else { return }
        let accumulator: RequestAccumulator
        if let existing = requests[requestID] {
            accumulator = existing
        } else {
            accumulator = RequestAccumulator(requestID: requestID, firstOrder: recordsSeen, offset: line.offset)
            requests[requestID] = accumulator
        }
        accumulator.latestOffset = line.offset
        if let observedAt { accumulator.latestTimestamp = observedAt }
        accumulator.modelName = modelName(update: update, envelope: object) ?? accumulator.modelName

        if let snapshot = tokenSnapshot(update: update, envelope: object) {
            accumulator.tokenSnapshot = snapshot
        }
        addCreditStages(update: update, envelope: object, line: line, to: accumulator)
    }

    public func finish(sourceURL: URL) throws -> (session: ParsedSession?, state: ParserState) {
        let pathSessionKey = Self.sessionKey(from: sourceURL)
        guard let finalSessionKey = nonempty(sessionKey) ?? pathSessionKey else {
            throw LocalAgentParserError.missingSessionKey
        }
        let isSubagent = sourceURL.pathComponents.contains("subagents")
        let fileTimestamp = (try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.modificationDate]) as? Date
        let fallbackTimestamp = updatedAt ?? startedAt ?? fileTimestamp ?? Date(timeIntervalSince1970: 0)

        // `session_usage.credit_json` 是 Request → 已累计实际 Credit。它只补 JSONL 中没有
        // 实际 Credit 的 Request，绝不与 JSONL 相加；子代理文件不重复注入会话级兜底。
        if !isSubagent {
            for (requestID, fallback) in fallbackCredits {
                guard !Self.isOptimisticUIRequestID(requestID) else { continue }
                let accumulator: RequestAccumulator
                if let existing = requests[requestID] {
                    accumulator = existing
                } else {
                    recordsSeen += 1
                    accumulator = RequestAccumulator(requestID: requestID, firstOrder: recordsSeen, offset: Int64(recordsSeen))
                    requests[requestID] = accumulator
                }
                if accumulator.latestTimestamp == nil {
                    accumulator.latestTimestamp = fallback.observedAt
                }
                if !accumulator.hasCredit, let picos = ProviderCreditUsage.picos(from: fallback.amount) {
                    accumulator.creditPicos = picos
                    accumulator.hasCredit = true
                }
            }
        }

        let ordered = requests.values.sorted {
            if $0.firstOrder != $1.firstOrder { return $0.firstOrder < $1.firstOrder }
            return $0.requestID < $1.requestID
        }
        var events: [UsageEvent] = []
        events.reserveCapacity(ordered.count)
        for accumulator in ordered {
            guard accumulator.tokenSnapshot != nil || accumulator.hasCredit else { continue }
            let snapshot = accumulator.tokenSnapshot
            events.append(UsageEvent(
                eventSeq: events.count + 1,
                observedAt: accumulator.latestTimestamp ?? fallbackTimestamp,
                modelName: accumulator.modelName,
                messageId: accumulator.requestID,
                dedupeKey: "request:\(accumulator.requestID)",
                dedupeScopeKey: "workbuddy",
                inputTokens: snapshot?.input ?? 0,
                outputTokens: snapshot?.output ?? 0,
                reasoningTokens: snapshot?.reasoning ?? 0,
                cacheReadTokens: snapshot?.cacheRead ?? 0,
                cacheWrite5mTokens: snapshot?.cacheWrite ?? 0,
                cacheWrite1hTokens: 0,
                tokensReported: snapshot != nil,
                creditUsage: accumulator.hasCredit
                    ? ProviderCreditUsage(actualPicos: accumulator.creditPicos)
                    : nil,
                sourceOffset: accumulator.latestOffset,
                isSidechain: isSubagent
            ))
        }

        let finalStartedAt = startedAt ?? events.map(\.observedAt).min()
        let finalUpdatedAt = updatedAt ?? events.map(\.observedAt).max()
        let state = ParserState(
            lastEventSeq: events.count,
            sessionKey: finalSessionKey,
            projectPath: projectPath,
            cliVersion: cliVersion,
            startedAt: finalStartedAt,
            updatedAt: finalUpdatedAt
        )
        return (
            ParsedSession(
                sourceKind: .workbuddyJSONL,
                providerId: "workbuddy",
                sessionKey: finalSessionKey,
                projectPath: projectPath,
                cliVersion: cliVersion,
                startedAt: finalStartedAt,
                updatedAt: finalUpdatedAt,
                events: events,
                rawMeta: ["source": "workbuddy"]
            ),
            state
        )
    }

    private func tokenSnapshot(update: [String: Any], envelope: [String: Any]) -> TokenSnapshot? {
        let providerData = JSONDictionary.dictionary(update, "providerData")
            ?? JSONDictionary.dictionary(envelope, "providerData")

        // 持久化投影保留请求级明细于 usage.details；直接 inputTokens/totalTokens 可能只是
        // `used/size` 的上下文快照，故没有 details 时不把它当作历史消耗。
        if let usage = providerData.flatMap({ JSONDictionary.dictionary($0, "usage") }),
           let details = JSONDictionary.dictionary(usage, "details"),
           let snapshot = parseRawTokenUsage(details) {
            return snapshot
        }
        if let usage = JSONDictionary.dictionary(update, "usage"),
           let details = JSONDictionary.dictionary(usage, "details"),
           let snapshot = parseRawTokenUsage(details) {
            return snapshot
        }

        let meta = JSONDictionary.dictionary(update, "_meta")
            ?? JSONDictionary.dictionary(envelope, "_meta")
        if let raw = meta.flatMap({ JSONDictionary.dictionary($0, "usage") }),
           let snapshot = parseRawTokenUsage(raw) {
            return snapshot
        }
        if let raw = providerData.flatMap({ JSONDictionary.dictionary($0, "rawUsage") }),
           let snapshot = parseRawTokenUsage(raw) {
            return snapshot
        }
        return nil
    }

    private func parseRawTokenUsage(_ usage: [String: Any]) -> TokenSnapshot? {
        let prompt = firstNonnegative(usage, keys: [
            "promptTokens", "prompt_tokens", "input_tokens", "inputTokens",
        ])
        let completion = firstNonnegative(usage, keys: [
            "completionTokens", "completion_tokens", "output_tokens", "outputTokens",
        ])
        let cacheRead = firstNonnegative(usage, keys: [
            "promptCacheHitTokens", "prompt_cache_hit_tokens", "cache_read_input_tokens", "cacheReadInputTokens",
        ]) ?? cachedTokenDetails(in: usage)
        let cacheWrite = firstNonnegative(usage, keys: [
            "promptCacheWriteTokens", "prompt_cache_write_tokens", "cache_creation_input_tokens", "cacheCreationInputTokens",
        ])
        let reasoning = firstNonnegative(usage, keys: [
            "reasoning_tokens", "reasoningTokens", "thoughts_tokens", "thoughtsTokens",
        ])
        guard prompt != nil || completion != nil || cacheRead != nil || cacheWrite != nil || reasoning != nil else {
            return nil
        }

        let cacheReadValue = cacheRead ?? 0
        let cacheWriteValue = cacheWrite ?? 0
        let promptValue = prompt ?? 0
        let cached = saturatingAdd(cacheReadValue, cacheWriteValue)
        let input = max(0, promptValue - min(promptValue, cached))
        let output = max(completion ?? 0, reasoning ?? 0)
        return TokenSnapshot(
            input: input,
            output: output,
            reasoning: min(reasoning ?? 0, output),
            cacheRead: cacheReadValue,
            cacheWrite: cacheWriteValue
        )
    }

    private func addCreditStages(
        update: [String: Any],
        envelope: [String: Any],
        line: JSONLLine,
        to accumulator: RequestAccumulator
    ) {
        let providerData = JSONDictionary.dictionary(update, "providerData")
            ?? JSONDictionary.dictionary(envelope, "providerData")
        let rawUsage = providerData.flatMap { JSONDictionary.dictionary($0, "rawUsage") }
        let rawCredit = rawUsage.flatMap {
            firstNonnegativeDouble($0, keys: ["credit", "credits"])
        }
        let updateCost = JSONDictionary.dictionary(update, "cost")
            .flatMap { firstNonnegativeDouble($0, keys: ["amount"]) }

        // 官方投影用同一个 record.id/messageId 去重 rawUsage.credit 与 usage_update.cost；
        // 没有 ID 的阶段在 JSONL 内仍是一条独立事实，以稳定字节偏移作阶段键。
        let stageID = firstNonempty([
            JSONDictionary.string(update, "id"),
            JSONDictionary.string(update, "messageId"),
            JSONDictionary.string(envelope, "id"),
            JSONDictionary.string(envelope, "messageId"),
        ]) ?? "offset:\(line.offset)"
        guard !accumulator.seenCreditStages.contains(stageID),
              let amount = rawCredit ?? updateCost,
              let picos = ProviderCreditUsage.picos(from: amount) else { return }
        accumulator.seenCreditStages.insert(stageID)
        accumulator.creditPicos = saturatingAdd(accumulator.creditPicos, picos)
        accumulator.hasCredit = true
    }

    private func requestID(update: [String: Any], envelope: [String: Any]) -> String? {
        let values = [metaRequestID(in: update), metaRequestID(in: envelope)] + [
            persistedRequestID(in: update),
            persistedRequestID(in: envelope),
        ]
        guard let value = firstNonempty(values), !Self.isOptimisticUIRequestID(value) else { return nil }
        return value
    }

    private func metaRequestID(in object: [String: Any]) -> String? {
        guard let meta = JSONDictionary.dictionary(object, "_meta") else { return nil }
        let nested = JSONDictionary.dictionary(meta, "codebuddy.ai")
        return firstNonempty([
            JSONDictionary.string(meta, "codebuddy.ai/requestId"),
            nested.flatMap { JSONDictionary.string($0, "requestId") },
            JSONDictionary.string(meta, "requestId"),
        ])
    }

    private func persistedRequestID(in object: [String: Any]) -> String? {
        let providerData = JSONDictionary.dictionary(object, "providerData")
        return firstNonempty([
            providerData.flatMap { JSONDictionary.string($0, "conversationRequestId") },
            providerData.flatMap { JSONDictionary.string($0, "requestId") },
            JSONDictionary.string(object, "conversationRequestId"),
            JSONDictionary.string(object, "requestId"),
        ])
    }

    private func modelName(update: [String: Any], envelope: [String: Any]) -> String? {
        let providerData = JSONDictionary.dictionary(update, "providerData")
            ?? JSONDictionary.dictionary(envelope, "providerData")
        let meta = JSONDictionary.dictionary(update, "_meta")
            ?? JSONDictionary.dictionary(envelope, "_meta")
        let nested = meta.flatMap { JSONDictionary.dictionary($0, "codebuddy.ai") }
        return firstNonempty([
            JSONDictionary.string(update, "model"),
            providerData.flatMap { JSONDictionary.string($0, "responseModelId") },
            providerData.flatMap { JSONDictionary.string($0, "model") },
            meta.flatMap { JSONDictionary.string($0, "codebuddy.ai/responseModelId") },
            nested.flatMap { JSONDictionary.string($0, "responseModelId") },
        ])
    }

    private func timestamp(in object: [String: Any]) -> Date? {
        guard let value = object["timestamp"] ?? object["createdAt"] ?? object["updatedAt"] else { return nil }
        if let number = JSONDictionary.double(value), number > 0 {
            return Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1_000 : number)
        }
        guard let raw = JSONDictionary.string(value) else { return nil }
        for formatter in dateFormatters {
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }

    private func cachedTokenDetails(in usage: [String: Any]) -> Int64? {
        let details = JSONDictionary.dictionary(usage, "prompt_tokens_details")
            ?? JSONDictionary.dictionary(usage, "inputTokensDetails")
        return details.flatMap { firstNonnegative($0, keys: ["cached_tokens", "cachedTokens"]) }
    }

    private func firstNonnegative(_ object: [String: Any], keys: [String]) -> Int64? {
        for key in keys where object[key] != nil && !(object[key] is NSNull) {
            if let value = JSONDictionary.int64(object, key), value >= 0 { return value }
        }
        return nil
    }

    private func firstNonnegativeDouble(_ object: [String: Any], keys: [String]) -> Double? {
        for key in keys where object[key] != nil && !(object[key] is NSNull) {
            if let value = JSONDictionary.double(object, key), value >= 0 { return value }
        }
        return nil
    }

    private func firstNonempty(_ values: [String?]) -> String? {
        values.lazy.compactMap(nonempty).first
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : result
    }

    private static func isOptimisticUIRequestID(_ value: String) -> Bool {
        guard value.hasPrefix("req-"), value.count > 4 else { return false }
        return value.dropFirst(4).allSatisfy(\.isNumber)
    }

    private static func sessionKey(from sourceURL: URL) -> String? {
        if sourceURL.pathComponents.contains("subagents") {
            return sourceURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        }
        return sourceURL.deletingPathExtension().lastPathComponent
    }
}
