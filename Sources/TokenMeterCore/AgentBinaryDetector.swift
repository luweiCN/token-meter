import Foundation

/// 设置页 A 区的 agent CLI 检测结果：可执行文件在不在、在哪、什么版本。
public struct AgentBinaryStatus: Codable, Equatable, Sendable {
    public let kind: String
    public let found: Bool
    public let path: String?
    public let version: String?

    public init(kind: String, found: Bool, path: String?, version: String?) {
        self.kind = kind
        self.found = found
        self.path = path
        self.version = version
    }
}

/// 各 coding agent 的 CLI 探测：搜目录找可执行文件 + `--version` 取版本。
/// 同步阻塞（每个 --version 最多 5s），调用方负责放到后台跑，绝不能占 MainActor。
public enum AgentBinaryDetector {
    /// agent kind → 可执行文件名（kind 与 settings 的 enabledAgentKinds 同一命名空间）。
    static let binaries: [(kind: String, binary: String)] = [
        ("claudeCode", "claude"),
        ("codex", "codex"),
        ("omp", "omp"),
        ("opencode", "opencode")
    ]

    public static func detect(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [AgentBinaryStatus] {
        detect(in: searchDirectories(homeDirectory: homeDirectory))
    }

    /// 目录可注入，测试不受本机真实 PATH 里装了什么 agent 的影响。
    static func detect(in directories: [String]) -> [AgentBinaryStatus] {
        return binaries.map { entry in
            guard let path = firstExecutable(named: entry.binary, in: directories) else {
                return AgentBinaryStatus(kind: entry.kind, found: false, path: nil, version: nil)
            }
            return AgentBinaryStatus(kind: entry.kind, found: true, path: path, version: version(of: path))
        }
    }

    /// 登录 shell 的 PATH + 常见安装点兜底（GUI app 的 PATH 不含用户 shell 配置；
    /// Codex standalone 装点与 CodexUsageProvider.searchDirectories 同一结论）。
    static func searchDirectories(homeDirectory: String) -> [String] {
        var directories: [String] = []
        if let path = LoginShellEnvironment.value(for: "PATH") {
            directories += path.split(separator: ":").map(String.init)
        }
        directories += [
            "\(homeDirectory)/.local/bin",
            "\(homeDirectory)/.codex/packages/standalone/current/bin",
            "\(homeDirectory)/.bun/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin"
        ]
        var seen = Set<String>()
        return directories.filter { seen.insert($0).inserted }
    }

    static func firstExecutable(named name: String, in directories: [String]) -> String? {
        let fileManager = FileManager.default
        for directory in directories {
            let candidate = (directory as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory),
               !isDirectory.boolValue,
               fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// `<binary> --version` 输出的第一行（如 "omp/16.4.8"、"1.17.18"）。
    /// 版本拿不到不算致命——found 仍为真，版本留空。
    static func version(of executablePath: String) -> String? {
        guard let data = try? runProcess(executable: executablePath, arguments: ["--version"], timeout: 5),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let firstLine = text.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (firstLine?.isEmpty == false) ? firstLine : nil
    }
}
