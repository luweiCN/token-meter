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

