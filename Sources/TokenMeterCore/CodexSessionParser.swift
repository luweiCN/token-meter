import Foundation

public struct CodexSessionParser: LocalAgentSessionParser {
    public init() {}

    public func parse(lines: [JSONLLine], sourceURL: URL) throws -> ParsedAgentSession {
        var sessionKey: String?
        var projectPath: String?
        var modelName: String?
        var startedAt: Date?
        var updatedAt: Date?
        var usage: ParsedSessionUsage?
        var usageSequence = 0
        var usageOffset: Int64?
        var previousTotalUsage: CodexTokenUsage?
        let dateFormatter = ISO8601DateFormatter()

        for line in lines {
            guard let object = JSONDictionary.object(from: line.text) else { continue }
            let type = JSONDictionary.string(object, "type")

            if let timestamp = timestamp(in: object, dateFormatter: dateFormatter) {
                updatedAt = timestamp
                if startedAt == nil {
                    startedAt = timestamp
                }
            }

            switch type {
            case "session_meta":
                guard let payload = JSONDictionary.dictionary(object, "payload") else { continue }
                sessionKey = firstString(in: payload, keys: ["id", "session_id", "sessionId"]) ?? sessionKey
                projectPath = firstString(in: payload, keys: ["cwd", "project_path", "projectPath"]) ?? projectPath
                modelName = firstString(in: payload, keys: ["model", "model_name", "modelName"]) ?? modelName
                if let timestamp = timestamp(in: payload, dateFormatter: dateFormatter) {
                    startedAt = timestamp
                    updatedAt = timestamp
                }

            case "turn_context":
                guard let payload = JSONDictionary.dictionary(object, "payload") else { continue }
                modelName = firstString(in: payload, keys: ["model", "model_name", "modelName"]) ?? modelName
                projectPath = firstString(in: payload, keys: ["cwd", "project_path", "projectPath"]) ?? projectPath

            case "event_msg":
                guard let payload = JSONDictionary.dictionary(object, "payload"),
                      JSONDictionary.string(payload, "type") == "token_count",
                      let info = JSONDictionary.dictionary(payload, "info") else {
                    continue
                }

                let totalUsage = JSONDictionary.dictionary(info, "total_token_usage").map(CodexTokenUsage.init)
                let usageForLine: CodexTokenUsage?
                if let lastUsageObject = JSONDictionary.dictionary(info, "last_token_usage") {
                    usageForLine = CodexTokenUsage(lastUsageObject)
                } else if let totalUsage {
                    usageForLine = totalUsage.delta(from: previousTotalUsage)
                } else {
                    usageForLine = nil
                }

                if let totalUsage {
                    previousTotalUsage = totalUsage
                }

                guard let usageForLine else { continue }
                usage = usageForLine.parsedUsage
                usageSequence += 1
                usageOffset = line.offset

            default:
                continue
            }
        }

        guard let sessionKey else { throw LocalAgentParserError.missingSessionKey }
        return ParsedAgentSession(
            sourceKind: .codexJSONL,
            sessionKey: sessionKey,
            projectPath: projectPath,
            modelName: modelName,
            cliVersion: nil,
            startedAt: startedAt,
            updatedAt: updatedAt,
            usage: usage,
            usageSequence: usageSequence,
            sourceOffset: usageOffset,
            rawMeta: ["source": "codex"]
        )
    }

    private func timestamp(in object: [String: Any], dateFormatter: ISO8601DateFormatter) -> Date? {
        firstString(in: object, keys: ["timestamp", "created_at", "createdAt"])
            .flatMap(dateFormatter.date(from:))
    }

    private func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = JSONDictionary.string(object, key), !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

private struct CodexTokenUsage {
    let inputTokens: Int64?
    let outputTokens: Int64?
    let reasoningTokens: Int64?
    let cacheReadTokens: Int64?
    let cacheWriteTokens: Int64?
    let totalTokens: Int64?

    init(_ object: [String: Any]) {
        inputTokens = CodexTokenUsage.firstInt64(
            in: object,
            keys: ["input_tokens", "prompt_tokens", "input"]
        )
        outputTokens = CodexTokenUsage.firstInt64(
            in: object,
            keys: ["output_tokens", "completion_tokens", "output"]
        )
        reasoningTokens = CodexTokenUsage.firstInt64(
            in: object,
            keys: ["reasoning_output_tokens", "reasoning_tokens"]
        )
        let unclampedCacheReadTokens = CodexTokenUsage.firstInt64(
            in: object,
            keys: ["cached_input_tokens", "cache_read_input_tokens", "cached_tokens"]
        )
        cacheReadTokens = CodexTokenUsage.clampCacheRead(unclampedCacheReadTokens, inputTokens: inputTokens)
        cacheWriteTokens = CodexTokenUsage.firstInt64(
            in: object,
            keys: ["cache_creation_input_tokens", "cache_write_input_tokens"]
        )
        totalTokens = CodexTokenUsage.firstInt64(in: object, keys: ["total_tokens", "total"])
    }

    private init(
        inputTokens: Int64?,
        outputTokens: Int64?,
        reasoningTokens: Int64?,
        cacheReadTokens: Int64?,
        cacheWriteTokens: Int64?,
        totalTokens: Int64?
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cacheReadTokens = CodexTokenUsage.clampCacheRead(cacheReadTokens, inputTokens: inputTokens)
        self.cacheWriteTokens = cacheWriteTokens
        self.totalTokens = totalTokens
    }

    var parsedUsage: ParsedSessionUsage {
        let tokens = tokensWithTotalFallback
        return ParsedSessionUsage(
            inputTokens: tokens.inputTokens,
            outputTokens: tokens.outputTokens,
            reasoningTokens: tokens.reasoningTokens,
            cacheReadTokens: tokens.cacheReadTokens,
            cacheWriteTokens: tokens.cacheWriteTokens,
            costUSDMicros: nil
        )
    }

    func delta(from previous: CodexTokenUsage?) -> CodexTokenUsage {
        guard let previous else {
            return self
        }

        return CodexTokenUsage(
            inputTokens: delta(current: inputTokens, previous: previous.inputTokens),
            outputTokens: delta(current: outputTokens, previous: previous.outputTokens),
            reasoningTokens: delta(current: reasoningTokens, previous: previous.reasoningTokens),
            cacheReadTokens: delta(current: cacheReadTokens, previous: previous.cacheReadTokens),
            cacheWriteTokens: delta(current: cacheWriteTokens, previous: previous.cacheWriteTokens),
            totalTokens: delta(current: totalTokens, previous: previous.totalTokens)
        )
    }

    private var tokensWithTotalFallback: CodexTokenUsage {
        guard let totalTokens else {
            return self
        }

        if inputTokens == nil, outputTokens == nil, reasoningTokens == nil, cacheReadTokens == nil, cacheWriteTokens == nil {
            return CodexTokenUsage(
                inputTokens: totalTokens,
                outputTokens: nil,
                reasoningTokens: nil,
                cacheReadTokens: nil,
                cacheWriteTokens: nil,
                totalTokens: totalTokens
            )
        }

        guard outputTokens == nil, let inputTokens else {
            return self
        }

        let usedNonOutputTokens = inputTokens
            + (reasoningTokens ?? 0)
            + (cacheReadTokens ?? 0)
            + (cacheWriteTokens ?? 0)
        let inferredOutput = max(0, totalTokens - usedNonOutputTokens)
        return CodexTokenUsage(
            inputTokens: inputTokens,
            outputTokens: inferredOutput,
            reasoningTokens: reasoningTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            totalTokens: totalTokens
        )
    }

    private static func firstInt64(in object: [String: Any], keys: [String]) -> Int64? {
        for key in keys {
            if let value = JSONDictionary.int64(object, key) {
                return max(0, value)
            }
        }
        return nil
    }

    private static func clampCacheRead(_ cacheReadTokens: Int64?, inputTokens: Int64?) -> Int64? {
        guard let cacheReadTokens, let inputTokens else {
            return cacheReadTokens
        }
        return min(cacheReadTokens, inputTokens)
    }

    private func delta(current: Int64?, previous: Int64?) -> Int64? {
        guard let current else {
            return nil
        }
        guard let previous else {
            return current
        }
        return max(0, current - previous)
    }
}
