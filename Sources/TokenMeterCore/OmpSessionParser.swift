import Foundation

public struct OmpSessionParser: LocalAgentSessionParser {
    public init() {}

    public func parse(lines: [JSONLLine], sourceURL: URL) throws -> ParsedAgentSession {
        var sessionKey: String?
        var projectPath: String?
        var modelName: String?
        var startedAt: Date?
        var updatedAt: Date?
        var usages: [OmpParsedUsage] = []
        var usageOffset: Int64?
        let dateFormatters = makeDateFormatters()

        for line in lines {
            guard let object = JSONDictionary.object(from: line.text) else { continue }
            let type = firstString(in: object, keys: ["type"])

            if let timestamp = timestamp(in: object, dateFormatters: dateFormatters) {
                if startedAt == nil {
                    startedAt = timestamp
                }
                updatedAt = timestamp
            }

            switch type {
            case "session":
                sessionKey = firstString(in: object, keys: ["id", "sessionId", "session_id"]) ?? sessionKey
                projectPath = firstString(in: object, keys: ["cwd", "projectPath", "project_path"]) ?? projectPath
                modelName = firstString(in: object, keys: ["model", "modelName", "model_name"]) ?? modelName

            case "model_change", "modelChange":
                modelName = firstString(in: object, keys: ["model", "modelName", "model_name"]) ?? modelName

            case "message":
                guard let message = JSONDictionary.dictionary(object, "message"),
                      let usageObject = JSONDictionary.dictionary(message, "usage") else {
                    continue
                }
                modelName = firstString(in: message, keys: ["model", "modelName", "model_name"]) ?? modelName
                let usage = OmpParsedUsage(usageObject)
                guard usage.hasAnyValue else { continue }
                usages.append(usage)
                usageOffset = line.offset

            default:
                continue
            }
        }

        let resolvedSessionKey = sessionKey ?? fallbackSessionKey(from: sourceURL)
        return ParsedAgentSession(
            sourceKind: .ompJSONL,
            sessionKey: resolvedSessionKey,
            projectPath: projectPath,
            modelName: modelName,
            cliVersion: nil,
            startedAt: startedAt,
            updatedAt: updatedAt,
            usage: aggregate(usages),
            usageSequence: usages.count,
            sourceOffset: usageOffset,
            rawMeta: ["source": "omp"]
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

    private func aggregate(_ usages: [OmpParsedUsage]) -> ParsedSessionUsage? {
        guard !usages.isEmpty else { return nil }
        return ParsedSessionUsage(
            inputTokens: sum(usages.map(\.inputTokens)),
            outputTokens: sum(usages.map(\.outputTokens)),
            reasoningTokens: sum(usages.map(\.reasoningTokens)),
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

    private func fallbackSessionKey(from sourceURL: URL) -> String {
        let lastPathComponent = sourceURL.deletingPathExtension().lastPathComponent
        if !lastPathComponent.isEmpty { return lastPathComponent }
        return sourceURL.path
    }

    private func makeDateFormatters() -> [ISO8601DateFormatter] {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [fractional, ISO8601DateFormatter()]
    }
}

private struct OmpParsedUsage {
    let inputTokens: Int64?
    let outputTokens: Int64?
    let reasoningTokens: Int64?
    let cacheReadTokens: Int64?
    let cacheWriteTokens: Int64?
    let costUSDMicros: Int64?

    init(_ object: [String: Any]) {
        let parsedInput = OmpParsedUsage.firstInt64(in: object, keys: ["inputTokens", "input_tokens", "input"])
        outputTokens = OmpParsedUsage.firstInt64(in: object, keys: ["outputTokens", "output_tokens", "output"])
        reasoningTokens = OmpParsedUsage.firstInt64(in: object, keys: ["reasoningTokens", "reasoning_tokens", "reasoning"])
        cacheReadTokens = OmpParsedUsage.firstInt64(in: object, keys: ["cacheReadTokens", "cache_read_tokens", "cache_read_input_tokens"])
        cacheWriteTokens = OmpParsedUsage.firstInt64(in: object, keys: ["cacheWriteTokens", "cache_write_tokens", "cache_creation_input_tokens"])
        costUSDMicros = OmpParsedUsage.costUSDMicros(in: object)

        if parsedInput == nil,
           outputTokens == nil,
           reasoningTokens == nil,
           cacheReadTokens == nil,
           cacheWriteTokens == nil,
           let totalTokens = OmpParsedUsage.firstInt64(in: object, keys: ["totalTokens", "total_tokens", "total"]) {
            inputTokens = totalTokens
        } else {
            inputTokens = parsedInput
        }
    }

    var hasAnyValue: Bool {
        inputTokens != nil
            || outputTokens != nil
            || reasoningTokens != nil
            || cacheReadTokens != nil
            || cacheWriteTokens != nil
            || costUSDMicros != nil
    }

    private static func costUSDMicros(in object: [String: Any]) -> Int64? {
        let costValue: Double?
        if let cost = JSONDictionary.dictionary(object, "cost") {
            costValue = firstDouble(in: cost, keys: ["total", "totalUSD", "total_usd", "usd"])
        } else {
            costValue = firstDouble(in: object, keys: ["cost", "costUSD", "cost_usd"])
        }
        return costValue.map { max(0, Int64(($0 * 1_000_000).rounded())) }
    }

    private static func firstInt64(in object: [String: Any], keys: [String]) -> Int64? {
        for key in keys {
            if let value = JSONDictionary.int64(object, key) {
                return max(0, value)
            }
        }
        return nil
    }

    private static func firstDouble(in object: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = JSONDictionary.double(object, key) {
                return value
            }
        }
        return nil
    }
}
