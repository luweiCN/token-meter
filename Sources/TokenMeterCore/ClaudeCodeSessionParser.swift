import Foundation

public struct ClaudeCodeSessionParser: LocalAgentSessionParser {
    public init() {}

    public func parse(lines: [JSONLLine], sourceURL: URL) throws -> ParsedAgentSession {
        var sessionKey: String?
        var projectPath: String?
        var modelName: String?
        var cliVersion: String?
        var startedAt: Date?
        var updatedAt: Date?
        var usageByDedupeKey: [String: ClaudeUsageRecord] = [:]
        var anonymousUsageSequence = 0
        let dateFormatters = makeDateFormatters()

        for line in lines {
            guard let object = JSONDictionary.object(from: line.text) else { continue }

            sessionKey = firstString(in: object, keys: ["sessionId", "session_id", "leafUuid", "leaf_uuid"]) ?? sessionKey
            projectPath = firstString(in: object, keys: ["cwd", "project_path", "projectPath"]) ?? projectPath
            cliVersion = firstString(in: object, keys: ["version", "cliVersion", "cli_version"]) ?? cliVersion

            if let timestamp = timestamp(in: object, dateFormatters: dateFormatters) {
                if startedAt == nil {
                    startedAt = timestamp
                }
                updatedAt = timestamp
            }

            guard let message = JSONDictionary.dictionary(object, "message"),
                  let usageObject = JSONDictionary.dictionary(message, "usage") else {
                continue
            }

            let type = firstString(in: object, keys: ["type"])
            let role = firstString(in: message, keys: ["role"])
            guard type == nil || type == "assistant" || role == "assistant" else { continue }

            modelName = firstString(in: message, keys: ["model", "modelName", "model_name"]) ?? modelName

            let usage = ClaudeParsedUsage(
                usageObject,
                costUSDMicros: costUSDMicros(in: object)
            )
            guard usage.hasAnyValue else { continue }

            let dedupeKey: String
            if let messageID = firstString(in: message, keys: ["id"]),
               let requestID = firstString(in: object, keys: ["requestId", "request_id"]) {
                dedupeKey = "\(messageID)\u{1F}\(requestID)"
            } else {
                anonymousUsageSequence += 1
                dedupeKey = "anonymous:\(line.offset):\(anonymousUsageSequence)"
            }

            let record = ClaudeUsageRecord(
                usage: usage,
                isSidechain: bool(in: object, keys: ["isSidechain", "is_sidechain"]) ?? false,
                offset: line.offset
            )

            if let existing = usageByDedupeKey[dedupeKey] {
                if record.isPreferred(over: existing) {
                    usageByDedupeKey[dedupeKey] = record
                }
            } else {
                usageByDedupeKey[dedupeKey] = record
            }
        }

        guard let sessionKey else { throw LocalAgentParserError.missingSessionKey }
        let records = Array(usageByDedupeKey.values)

        return ParsedAgentSession(
            sourceKind: .claudeJSONL,
            sessionKey: sessionKey,
            projectPath: projectPath,
            modelName: modelName,
            cliVersion: cliVersion,
            startedAt: startedAt,
            updatedAt: updatedAt,
            usage: aggregate(records.map(\.usage)),
            usageSequence: records.count,
            sourceOffset: records.map(\.offset).max(),
            rawMeta: ["source": "claude-code"]
        )
    }

    private func timestamp(in object: [String: Any], dateFormatters: [ISO8601DateFormatter]) -> Date? {
        guard let value = firstString(in: object, keys: ["timestamp", "created_at", "createdAt"]) else { return nil }
        return dateFormatters.lazy.compactMap { $0.date(from: value) }.first
    }

    private func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = JSONDictionary.string(object, key), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func bool(in object: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = bool(object[key]) {
                return value
            }
        }
        return nil
    }

    private func bool(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber where !(value is Bool):
            return number.intValue != 0
        case let string as String:
            switch string.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        default:
            return nil
        }
    }

    private func costUSDMicros(in object: [String: Any]) -> Int64? {
        firstDouble(in: object, keys: ["costUSD", "cost_usd"]).map { cost in
            max(0, Int64((cost * 1_000_000).rounded()))
        }
    }

    private func aggregate(_ usages: [ClaudeParsedUsage]) -> ParsedSessionUsage? {
        guard !usages.isEmpty else { return nil }
        return ParsedSessionUsage(
            inputTokens: sum(usages.map(\.inputTokens)),
            outputTokens: sum(usages.map(\.outputTokens)),
            reasoningTokens: nil,
            cacheReadTokens: sum(usages.map(\.cacheReadTokens)),
            cacheWriteTokens: sum(usages.map(\.cacheWriteTokens)),
            costUSDMicros: sum(usages.map(\.costUSDMicros))
        )
    }

    private func sum(_ values: [Int64?]) -> Int64? {
        let numbers = values.compactMap { $0 }
        guard !numbers.isEmpty else { return nil }
        return numbers.reduce(0, +)
    }

    private func makeDateFormatters() -> [ISO8601DateFormatter] {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [fractional, ISO8601DateFormatter()]
    }
}

final class ClaudeCodeStreamingParser: LocalAgentSessionStreamingParser {
    private var sessionKey: String?
    private var projectPath: String?
    private var modelName: String?
    private var cliVersion: String?
    private var startedAt: Date?
    private var updatedAt: Date?
    private var usageByDedupeKey: [String: ClaudeUsageRecord] = [:]
    private var anonymousUsageSequence = 0
    private let dateFormatters: [ISO8601DateFormatter]

    var latestTokenUsageIsCumulative: Bool { true }

    init() {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        dateFormatters = [fractional, ISO8601DateFormatter()]
    }

    func consume(_ line: JSONLLine) {
        guard let object = JSONDictionary.object(from: line.text) else { return }

        sessionKey = firstString(in: object, keys: ["sessionId", "session_id", "leafUuid", "leaf_uuid"]) ?? sessionKey
        projectPath = firstString(in: object, keys: ["cwd", "project_path", "projectPath"]) ?? projectPath
        cliVersion = firstString(in: object, keys: ["version", "cliVersion", "cli_version"]) ?? cliVersion

        if let timestamp = timestamp(in: object) {
            if startedAt == nil {
                startedAt = timestamp
            }
            updatedAt = timestamp
        }

        guard let message = JSONDictionary.dictionary(object, "message"),
              let usageObject = JSONDictionary.dictionary(message, "usage") else {
            return
        }

        let type = firstString(in: object, keys: ["type"])
        let role = firstString(in: message, keys: ["role"])
        guard type == nil || type == "assistant" || role == "assistant" else { return }

        modelName = firstString(in: message, keys: ["model", "modelName", "model_name"]) ?? modelName

        let usage = ClaudeParsedUsage(
            usageObject,
            costUSDMicros: costUSDMicros(in: object)
        )
        guard usage.hasAnyValue else { return }

        let dedupeKey: String
        if let messageID = firstString(in: message, keys: ["id"]),
           let requestID = firstString(in: object, keys: ["requestId", "request_id"]) {
            dedupeKey = "\(messageID)\u{1F}\(requestID)"
        } else {
            anonymousUsageSequence += 1
            dedupeKey = "anonymous:\(line.offset):\(anonymousUsageSequence)"
        }

        let record = ClaudeUsageRecord(
            usage: usage,
            isSidechain: bool(in: object, keys: ["isSidechain", "is_sidechain"]) ?? false,
            offset: line.offset
        )

        if let existing = usageByDedupeKey[dedupeKey] {
            if record.isPreferred(over: existing) {
                usageByDedupeKey[dedupeKey] = record
            }
        } else {
            usageByDedupeKey[dedupeKey] = record
        }
    }

    func finish(sourceURL: URL) throws -> ParsedAgentSession {
        guard let sessionKey else { throw LocalAgentParserError.missingSessionKey }
        let records = Array(usageByDedupeKey.values)

        return ParsedAgentSession(
            sourceKind: .claudeJSONL,
            sessionKey: sessionKey,
            projectPath: projectPath,
            modelName: modelName,
            cliVersion: cliVersion,
            startedAt: startedAt,
            updatedAt: updatedAt,
            usage: aggregate(records.map(\.usage)),
            usageSequence: records.count,
            sourceOffset: records.map(\.offset).max(),
            rawMeta: ["source": "claude-code"]
        )
    }

    private func timestamp(in object: [String: Any]) -> Date? {
        guard let value = firstString(in: object, keys: ["timestamp", "created_at", "createdAt"]) else { return nil }
        return dateFormatters.lazy.compactMap { $0.date(from: value) }.first
    }

    private func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = JSONDictionary.string(object, key), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func bool(in object: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = bool(object[key]) {
                return value
            }
        }
        return nil
    }

    private func bool(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber where !(value is Bool):
            return number.intValue != 0
        case let string as String:
            switch string.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        default:
            return nil
        }
    }

    private func costUSDMicros(in object: [String: Any]) -> Int64? {
        firstDouble(in: object, keys: ["costUSD", "cost_usd"]).map { cost in
            max(0, Int64((cost * 1_000_000).rounded()))
        }
    }

    private func aggregate(_ usages: [ClaudeParsedUsage]) -> ParsedSessionUsage? {
        guard !usages.isEmpty else { return nil }
        return ParsedSessionUsage(
            inputTokens: sum(usages.map(\.inputTokens)),
            outputTokens: sum(usages.map(\.outputTokens)),
            reasoningTokens: nil,
            cacheReadTokens: sum(usages.map(\.cacheReadTokens)),
            cacheWriteTokens: sum(usages.map(\.cacheWriteTokens)),
            costUSDMicros: sum(usages.map(\.costUSDMicros))
        )
    }

    private func sum(_ values: [Int64?]) -> Int64? {
        let numbers = values.compactMap { $0 }
        guard !numbers.isEmpty else { return nil }
        return numbers.reduce(0, +)
    }
}

private struct ClaudeUsageRecord {
    let usage: ClaudeParsedUsage
    let isSidechain: Bool
    let offset: Int64

    func isPreferred(over existing: ClaudeUsageRecord) -> Bool {
        if existing.isSidechain, !isSidechain {
            return true
        }
        if !existing.isSidechain, isSidechain {
            return false
        }
        if usage.rank != existing.usage.rank {
            return usage.rank > existing.usage.rank
        }
        return offset > existing.offset
    }
}

private struct ClaudeParsedUsage {
    let inputTokens: Int64?
    let outputTokens: Int64?
    let cacheReadTokens: Int64?
    let cacheWriteTokens: Int64?
    let costUSDMicros: Int64?

    init(_ object: [String: Any], costUSDMicros: Int64?) {
        inputTokens = ClaudeParsedUsage.firstInt64(in: object, keys: ["input_tokens", "inputTokens", "input"])
        outputTokens = ClaudeParsedUsage.firstInt64(in: object, keys: ["output_tokens", "outputTokens", "output"])
        cacheReadTokens = ClaudeParsedUsage.firstInt64(in: object, keys: ["cache_read_input_tokens", "cacheReadTokens", "cache_read_tokens"])
        cacheWriteTokens = ClaudeParsedUsage.firstInt64(in: object, keys: ["cache_creation_input_tokens", "cacheWriteTokens", "cache_write_tokens"])
            ?? ClaudeParsedUsage.nestedCacheCreationTokens(in: object)
        self.costUSDMicros = costUSDMicros
    }

    var hasAnyValue: Bool {
        inputTokens != nil
            || outputTokens != nil
            || cacheReadTokens != nil
            || cacheWriteTokens != nil
            || costUSDMicros != nil
    }

    var rank: (Int64, Int64) {
        (
            (inputTokens ?? 0) + (outputTokens ?? 0) + (cacheReadTokens ?? 0) + (cacheWriteTokens ?? 0),
            costUSDMicros ?? 0
        )
    }

    private static func nestedCacheCreationTokens(in object: [String: Any]) -> Int64? {
        guard let cacheCreation = JSONDictionary.dictionary(object, "cache_creation") else { return nil }
        let values = cacheCreation.values.compactMap(JSONDictionary.int64).map { max(0, $0) }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }

    private static func firstInt64(in object: [String: Any], keys: [String]) -> Int64? {
        for key in keys {
            if let value = JSONDictionary.int64(object, key) {
                return max(0, value)
            }
        }
        return nil
    }
}

private func firstDouble(in object: [String: Any], keys: [String]) -> Double? {
    for key in keys {
        if let value = JSONDictionary.double(object, key) {
            return value
        }
    }
    return nil
}
