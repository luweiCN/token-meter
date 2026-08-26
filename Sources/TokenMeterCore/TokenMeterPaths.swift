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

    /// 用户自定义模型定价（覆盖随包 LiteLLM 快照）。手写 JSON，无 UI。
    public static func customPricingURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        baseDirectory(homeDirectory: homeDirectory).appendingPathComponent("custom-pricing.json")
    }

    public static func defaultScanRoots(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [DefaultScanRoot] {
        let codexDirectory: URL
        if let configured = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            codexDirectory = URL(
                fileURLWithPath: (configured as NSString).expandingTildeInPath,
                isDirectory: true
            ).standardizedFileURL
        } else {
            codexDirectory = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        }

        return [
            DefaultScanRoot(
                kind: .claudeJSONL,
                rootURL: homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true),
                displayName: "Claude Code"
            ),
            DefaultScanRoot(
                kind: .codexJSONL,
                rootURL: codexDirectory.appendingPathComponent("sessions", isDirectory: true),
                displayName: "Codex"
            ),
            // Codex 会把旧 session 从 .codex/sessions 移进 .codex/archived_sessions（同样是
            // rollout-*.jsonl）。不扫这里会漏掉约 5.2% 的 codex 用量。stableSourceKey 含 path，
            // 与 sessions 天然不撞；provider_id 同为 "codex"，两根汇总成同一个 Codex。
            // displayName 单独作 "Codex (Archived)"：它只用于扫描排序与 index-status 的分根列表，
            // 不是 provider 标签，用同名会让分根列表出现两个无法区分的 "Codex"。
            DefaultScanRoot(
                kind: .codexJSONL,
                rootURL: codexDirectory.appendingPathComponent("archived_sessions", isDirectory: true),
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
            ),
            DefaultScanRoot(
                kind: .reasonixStats,
                rootURL: homeDirectory.appendingPathComponent(".reasonix/stats", isDirectory: true),
                displayName: "Reasonix"
            ),
            DefaultScanRoot(
                kind: .dshJSONL,
                rootURL: DshPaths.sessionsRoot(homeDirectory: homeDirectory, environment: environment),
                displayName: "DeepSeek Harness"
            ),
            DefaultScanRoot(
                kind: .grokJSONL,
                rootURL: GrokPaths.sessionsRoot(homeDirectory: homeDirectory, environment: environment),
                displayName: "Grok Build"
            )
        ]
    }

    public static func socketURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        baseDirectory(homeDirectory: homeDirectory).appendingPathComponent("tokenmeter.sock")
    }
}

public enum DshPaths {
    public static func sessionsRoot(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let configured = environment["DSH_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
                .standardizedFileURL
        }
        return homeDirectory.appendingPathComponent(".dsh/sessions", isDirectory: true)
    }
}

public enum GrokPaths {
    public static func sessionsRoot(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let configured = environment["GROK_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
                .standardizedFileURL
        }
        return homeDirectory.appendingPathComponent(".grok/sessions", isDirectory: true)
    }

    public static func updatesFiles(under root: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return [] }
        var files: [URL] = []
        for case let file as URL in enumerator where file.lastPathComponent == "updates.jsonl" {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                files.append(file)
            }
        }
        return files.sorted { $0.path < $1.path }
    }
}
