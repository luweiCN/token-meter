import Foundation

/// 一条 assistant API 响应的用量。
///
/// 字段语义已跨源归一：
/// - `inputTokens` 不含缓存
/// - `cacheReadTokens` 与 `inputTokens` 不重叠
/// - `outputTokens` 已包含 `reasoningTokens`
/// - `reasoningTokens` 仅供展示，不计入 `totalTokens`
/// - `cacheWrite5mTokens` / `cacheWrite1hTokens` — 提示词缓存写入的两个 TTL 档位
///   （5 分钟 / 1 小时），单价不同，必须分开记录
public struct UsageEvent: Equatable {
    public let eventSeq: Int
    public let observedAt: Date
    public let modelName: String?
    public let messageId: String?
    public let requestId: String?
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let reasoningTokens: Int64
    public let cacheReadTokens: Int64
    public let cacheWrite5mTokens: Int64
    public let cacheWrite1hTokens: Int64
    public let reportedCostUSDMicros: Int64?
    public let sourceOffset: Int64
    public let isSidechain: Bool

    public init(
        eventSeq: Int,
        observedAt: Date,
        modelName: String? = nil,
        messageId: String? = nil,
        requestId: String? = nil,
        inputTokens: Int64 = 0,
        outputTokens: Int64 = 0,
        reasoningTokens: Int64 = 0,
        cacheReadTokens: Int64 = 0,
        cacheWrite5mTokens: Int64 = 0,
        cacheWrite1hTokens: Int64 = 0,
        reportedCostUSDMicros: Int64? = nil,
        sourceOffset: Int64,
        isSidechain: Bool = false
    ) {
        self.eventSeq = eventSeq
        self.observedAt = observedAt
        self.modelName = modelName
        self.messageId = messageId
        self.requestId = requestId
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWrite5mTokens = cacheWrite5mTokens
        self.cacheWrite1hTokens = cacheWrite1hTokens
        self.reportedCostUSDMicros = reportedCostUSDMicros
        self.sourceOffset = sourceOffset
        self.isSidechain = isSidechain
    }

    /// `reasoningTokens` 不计入：它已包含在 `outputTokens` 里。
    public var totalTokens: Int64 {
        inputTokens + outputTokens + cacheReadTokens + cacheWrite5mTokens + cacheWrite1hTokens
    }

    /// 仅当 messageId 与 requestId 都存在时才构成去重键。
    public var dedupeKey: String? {
        guard let messageId, let requestId else { return nil }
        return "\(messageId)\u{1F}\(requestId)"
    }

    public var observedEpochMilliseconds: Int64 {
        Int64((observedAt.timeIntervalSince1970 * 1000).rounded())
    }
}

/// 一个会话源文件解析后的产物：会话元信息，加上该文件内的全部用量事件。
public struct ParsedSession: Equatable {
    public let sourceKind: SourceKind
    public let sessionKey: String
    public let projectPath: String?
    public let cliVersion: String?
    public let startedAt: Date?
    public let updatedAt: Date?
    public let events: [UsageEvent]
    public let rawMeta: [String: String]

    public init(
        sourceKind: SourceKind,
        sessionKey: String,
        projectPath: String?,
        cliVersion: String?,
        startedAt: Date?,
        updatedAt: Date?,
        events: [UsageEvent],
        rawMeta: [String: String]
    ) {
        self.sourceKind = sourceKind
        self.sessionKey = sessionKey
        self.projectPath = projectPath
        self.cliVersion = cliVersion
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.events = events
        self.rawMeta = rawMeta
    }
}

/// Codex 的 `token_count` 事件存累计值，增量续读时需要上一次的基线。
public struct CumulativeTokenTotals: Equatable, Codable {
    public var inputTokens: Int64
    public var cachedInputTokens: Int64
    public var outputTokens: Int64
    public var reasoningTokens: Int64

    public init(inputTokens: Int64 = 0, cachedInputTokens: Int64 = 0, outputTokens: Int64 = 0, reasoningTokens: Int64 = 0) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
    }
}

/// 持久化到 `source_files.parser_state`，用于单文件断点续读。
public struct ParserState: Equatable, Codable {
    public var lastEventSeq: Int
    public var lastCumulative: CumulativeTokenTotals?

    public init(lastEventSeq: Int = 0, lastCumulative: CumulativeTokenTotals? = nil) {
        self.lastEventSeq = lastEventSeq
        self.lastCumulative = lastCumulative
    }
}
