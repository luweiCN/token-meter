import Foundation

public enum LocalAgentKind: String, Codable, Equatable, CaseIterable {
    case claudeCode
    case codex
    case opencode
    case omp
    case reasonix
    case dsh
    case grok
    case qwenCode
    case qoder
    case workbuddy
    case antigravityCLI
    case geminiCLI
}

public enum SourceKind: String, Codable, Equatable, CaseIterable {
    case claudeJSONL = "claude_jsonl"
    case codexJSONL = "codex_jsonl"
    case ompJSONL = "omp_jsonl"
    case opencodeSQLite = "opencode_sqlite"
    case reasonixStats = "reasonix_stats"
    case dshJSONL = "dsh_jsonl"
    case grokJSONL = "grok_jsonl"
    case qwenJSONL = "qwen_jsonl"
    case qoderJSONL = "qoder_jsonl"
    case workbuddyJSONL = "workbuddy_jsonl"
    case antigravitySQLite = "antigravity_sqlite"
    case geminiChat = "gemini_chat"

    public var defaultProviderId: String {
        switch self {
        case .claudeJSONL: "claude-code"
        case .codexJSONL: "codex"
        case .ompJSONL: "omp"
        case .opencodeSQLite: "opencode"
        case .reasonixStats: "reasonix"
        case .dshJSONL: "dsh"
        case .grokJSONL: "grok"
        case .qwenJSONL: "qwen-code"
        case .qoderJSONL: "qoder-cli"
        case .workbuddyJSONL: "workbuddy"
        case .antigravitySQLite: "antigravity-cli"
        case .geminiChat: "gemini-cli"
        }
    }
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
