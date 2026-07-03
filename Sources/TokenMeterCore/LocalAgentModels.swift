import Foundation

public enum LocalAgentKind: String, Codable, Equatable, CaseIterable {
    case claudeCode
    case codex
    case opencode
    case omp
}

public enum SourceKind: String, Codable, Equatable {
    case claudeJSONL = "claude_jsonl"
    case codexJSONL = "codex_jsonl"
    case ompJSONL = "omp_jsonl"
    case opencodeSQLite = "opencode_sqlite"
}

public struct SourceFileFingerprint: Codable, Equatable {
    public let dev: UInt64?
    public let inode: UInt64?
    public let sizeBytes: Int64
    public let mtimeNanoseconds: Int64
    public let tailHash: String?

    public init(
        dev: UInt64?,
        inode: UInt64?,
        sizeBytes: Int64,
        mtimeNanoseconds: Int64,
        tailHash: String?
    ) {
        self.dev = dev
        self.inode = inode
        self.sizeBytes = sizeBytes
        self.mtimeNanoseconds = mtimeNanoseconds
        self.tailHash = tailHash
    }
}

public struct ParsedSessionUsage: Codable, Equatable {
    public let inputTokens: Int64?
    public let outputTokens: Int64?
    public let reasoningTokens: Int64?
    public let cacheReadTokens: Int64?
    public let cacheWriteTokens: Int64?
    public let costUSDMicros: Int64?

    public var totalTokens: Int64 {
        (inputTokens ?? 0)
            + (outputTokens ?? 0)
            + (reasoningTokens ?? 0)
            + (cacheReadTokens ?? 0)
            + (cacheWriteTokens ?? 0)
    }

    public init(
        inputTokens: Int64?,
        outputTokens: Int64?,
        reasoningTokens: Int64?,
        cacheReadTokens: Int64?,
        cacheWriteTokens: Int64?,
        costUSDMicros: Int64?
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.costUSDMicros = costUSDMicros
    }
}

public struct ParsedAgentSession: Codable, Equatable {
    public let sourceKind: SourceKind
    public let sessionKey: String
    public let projectPath: String?
    public let modelName: String?
    public let cliVersion: String?
    public let startedAt: Date?
    public let updatedAt: Date?
    public let usage: ParsedSessionUsage?
    public let usageSequence: Int
    public let sourceOffset: Int64?
    public let rawMeta: [String: String]

    public init(
        sourceKind: SourceKind,
        sessionKey: String,
        projectPath: String?,
        modelName: String?,
        cliVersion: String?,
        startedAt: Date?,
        updatedAt: Date?,
        usage: ParsedSessionUsage?,
        usageSequence: Int,
        sourceOffset: Int64?,
        rawMeta: [String: String]
    ) {
        self.sourceKind = sourceKind
        self.sessionKey = sessionKey
        self.projectPath = projectPath
        self.modelName = modelName
        self.cliVersion = cliVersion
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.usage = usage
        self.usageSequence = usageSequence
        self.sourceOffset = sourceOffset
        self.rawMeta = rawMeta
    }
}
