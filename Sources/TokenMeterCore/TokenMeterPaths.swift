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
