import Foundation

public struct DefaultScanRoot: Equatable {
    public let kind: SourceKind
    public let rootURL: URL
    /// 与主扫描根共同决定解析结果、但不适合作为独立根扫描的第二来源。
    /// Qwen Code 用它保存 QWEN_HOME（主根是 QWEN_RUNTIME_DIR），从而把
    /// runtime 下的请求账本与 home 下的 usage_record.jsonl 合成一次快照。
    public let auxiliaryURL: URL?
    public let displayName: String

    public init(kind: SourceKind, rootURL: URL, auxiliaryURL: URL? = nil, displayName: String) {
        self.kind = kind
        self.rootURL = rootURL
        self.auxiliaryURL = auxiliaryURL
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

    /// The menu app and the headless indexer ship beside the device CLI.
    package static var cliExecutableURL: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("token-meter")
    }

    package static func accountSnapshotsURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        baseDirectory(homeDirectory: homeDirectory).appendingPathComponent("cache/provider-snapshots.json")
    }

    /// 用户自定义模型定价（覆盖随包 LiteLLM 快照）。手写 JSON，无 UI。
    public static func customPricingURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        baseDirectory(homeDirectory: homeDirectory).appendingPathComponent("custom-pricing.json")
    }

    /// 缓存按格式隔离，防止旧客户端覆盖新版价格，或旧缓存压过新版随包快照。
    public static func pricingSnapshotURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        baseDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent("litellm-pricing-v\(PricingSnapshot.currentSchemaVersion).json")
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

        let qwenHome = configuredDirectory(
            environment["QWEN_HOME"],
            defaultURL: homeDirectory.appendingPathComponent(".qwen", isDirectory: true)
        )
        let qwenRuntime = configuredDirectory(
            environment["QWEN_RUNTIME_DIR"],
            defaultURL: qwenHome
        )

        let geminiDirectory = configuredDirectory(
            environment["GEMINI_CLI_HOME"], defaultURL: homeDirectory
        ).appendingPathComponent(".gemini", isDirectory: true)

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
            ),
            DefaultScanRoot(
                kind: .qwenJSONL,
                rootURL: qwenRuntime,
                auxiliaryURL: qwenHome,
                displayName: "千问 Code"
            ),
            DefaultScanRoot(
                kind: .qoderJSONL,
                rootURL: homeDirectory.appendingPathComponent(".qoder-cn/projects", isDirectory: true),
                displayName: "Qoder"
            ),
            DefaultScanRoot(
                kind: .workbuddyJSONL,
                rootURL: homeDirectory.appendingPathComponent(".workbuddy/projects", isDirectory: true),
                displayName: "WorkBuddy"
            ),
            DefaultScanRoot(
                kind: .antigravitySQLite,
                rootURL: geminiDirectory.appendingPathComponent("antigravity-cli/conversations", isDirectory: true),
                displayName: AntigravityCLIUsage.displayName
            ),
            DefaultScanRoot(
                kind: .geminiChat,
                rootURL: geminiDirectory.appendingPathComponent("tmp", isDirectory: true),
                displayName: "Gemini CLI"
            )
        ]
    }

    /// Qwen 官方允许绝对路径、相对当前工作目录的路径与 `~`。统一在播种根时
    /// 解析为绝对标准路径，避免同一目录因不同字符串产生两个 scan root。
    private static func configuredDirectory(_ rawValue: String?, defaultURL: URL) -> URL {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else { return defaultURL.standardizedFileURL }
        let expanded = (rawValue as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }

    public static func socketURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        baseDirectory(homeDirectory: homeDirectory).appendingPathComponent("tokenmeter.sock")
    }

    public static func qoderDesktopDatabaseURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/com.qodercn.app.stable", isDirectory: true)
            .appendingPathComponent("main.sqlite")
    }

    public static func workBuddyDatabaseURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory.appendingPathComponent(".workbuddy/workbuddy.db")
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
