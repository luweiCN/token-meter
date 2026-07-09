import Foundation

public struct DefaultScanRoot: Equatable {
    public let kind: SourceKind
    public let rootURL: URL
    public let displayName: String

    public init(kind: SourceKind, rootURL: URL, displayName: String) {
        self.kind = kind
        self.rootURL = rootURL
        self.displayName = displayName
    }

    public var stableSourceKey: String {
        "\(kind.rawValue):\(rootURL.path)"
    }
}

public enum TokenMeterPaths {
    public static func baseDirectory(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent(".token-meter", isDirectory: true)
    }

    public static func databaseURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        baseDirectory(homeDirectory: homeDirectory).appendingPathComponent("tokenmeter.sqlite")
    }

    public static func legacyConfigURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        baseDirectory(homeDirectory: homeDirectory).appendingPathComponent("config.json")
    }

    public static func legacySnapshotCacheURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        baseDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent("provider-snapshots.json")
    }

    public static func defaultScanRoots(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [DefaultScanRoot] {
        [
            DefaultScanRoot(
                kind: .claudeJSONL,
                rootURL: homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true),
                displayName: "Claude Code"
            ),
            DefaultScanRoot(
                kind: .codexJSONL,
                rootURL: homeDirectory.appendingPathComponent(".codex/sessions", isDirectory: true),
                displayName: "Codex"
            ),
            // Codex 会把旧 session 从 .codex/sessions 移进 .codex/archived_sessions（同样是
            // rollout-*.jsonl）。不扫这里会漏掉约 5.2% 的 codex 用量。stableSourceKey 含 path，
            // 与 sessions 天然不撞；provider_id 同为 "codex"，两根汇总成同一个 Codex。
            // displayName 单独作 "Codex (Archived)"：它只用于扫描排序与 index-status 的分根列表，
            // 不是 provider 标签，用同名会让分根列表出现两个无法区分的 "Codex"。
            DefaultScanRoot(
                kind: .codexJSONL,
                rootURL: homeDirectory.appendingPathComponent(".codex/archived_sessions", isDirectory: true),
                displayName: "Codex (Archived)"
            ),
            DefaultScanRoot(
                kind: .opencodeSQLite,
                rootURL: homeDirectory
                    .appendingPathComponent(".local/share/opencode", isDirectory: true)
                    .appendingPathComponent("opencode.db"),
                displayName: "OpenCode"
            ),
            DefaultScanRoot(
                kind: .ompJSONL,
                rootURL: homeDirectory.appendingPathComponent(".omp/agent/sessions", isDirectory: true),
                displayName: "OMP"
            )
        ]
    }

    public static func socketURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        baseDirectory(homeDirectory: homeDirectory).appendingPathComponent("tokenmeter.sock")
    }
}
