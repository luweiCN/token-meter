import Foundation

public protocol UsageProvider {
    var id: String { get }
    var displayName: String { get }
    func fetchUsage() async -> UsageSnapshot
    func fetchProviderUsage() async -> ProviderUsageSnapshot
}

public extension UsageProvider {
    func fetchProviderUsage() async -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(legacy: await fetchUsage())
    }
}

public extension ProviderUsageSnapshot {
    init(legacy snapshot: UsageSnapshot) {
        let metric = UsageMetric(
            id: "\(snapshot.providerId)-\(snapshot.label)",
            label: snapshot.label,
            kind: snapshot.unit == "tokens" ? .tokens : .quota,
            usedPercent: snapshot.used,
            remainingPercent: snapshot.remaining,
            resetText: nil,
            status: snapshot.status,
            detail: snapshot.message
        )

        self.init(
            providerId: snapshot.providerId,
            displayName: snapshot.displayName,
            status: snapshot.status,
            fetchedAt: snapshot.fetchedAt,
            summary: snapshot.message,
            message: snapshot.message,
            groups: [
                UsageGroup(
                    id: snapshot.providerId,
                    title: snapshot.displayName,
                    subtitle: nil,
                    items: [metric]
                )
            ]
        )
    }

    var legacySnapshot: UsageSnapshot {
        let metric = UsageFormatter.primaryMetric(in: self)
        return UsageSnapshot(
            providerId: providerId,
            displayName: displayName,
            status: status,
            label: metric?.label ?? "额度",
            used: metric?.usedPercent,
            remaining: metric?.remainingPercent,
            total: metric?.remainingPercent == nil ? nil : 100,
            unit: metric?.kind == .tokens ? "tokens" : "%",
            fetchedAt: fetchedAt,
            message: summary ?? message
        )
    }

    func withResetCredits(_ resetCredits: ResetCreditSummary?) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            providerId: providerId,
            displayName: displayName,
            status: status,
            fetchedAt: fetchedAt,
            summary: summary,
            message: message,
            groups: groups,
            resetCredits: resetCredits
        )
    }
}

public struct ManualUsageProvider: UsageProvider {
    public let id: String
    public let displayName: String

    private let config: ProviderConfig

    public init(config: ProviderConfig) {
        self.config = config
        self.id = config.id
        self.displayName = config.displayName
    }

    public func fetchUsage() async -> UsageSnapshot {
        let manualUsage = config.manualUsage

        return UsageSnapshot(
            providerId: config.id,
            displayName: config.displayName,
            status: manualUsage?.status ?? .unknown,
            label: manualUsage?.label ?? "用量",
            used: manualUsage?.used,
            remaining: manualUsage?.remaining,
            total: manualUsage?.total,
            unit: manualUsage?.unit,
            fetchedAt: Date(),
            message: manualUsage?.message
        )
    }
}

public struct CodexUsageProvider: UsageProvider {
    public let id: String
    public let displayName: String

    public init(config: ProviderConfig) {
        self.id = config.id
        self.displayName = config.displayName
    }

    public func fetchUsage() async -> UsageSnapshot {
        await fetchProviderUsage().legacySnapshot
    }

    public func fetchProviderUsage() async -> ProviderUsageSnapshot {
        do {
            let data = try await Task.detached {
                try runProcess(
                    executable: "/usr/bin/env",
                    arguments: ["node", "-e", Self.nodeScript],
                    environmentOverrides: ["PATH": Self.executableSearchPath()],
                    timeout: 10
                )
            }.value
            let snapshot = try CodexUsageParser.parse(data: data, providerId: id, displayName: displayName)
            let resetCredits = try? await CodexResetCreditsClient.default.fetch()
            return snapshot.withResetCredits(resetCredits)
        } catch {
            if !Self.codexExecutableExists() {
                return providerErrorSnapshot(
                    providerId: id,
                    displayName: displayName,
                    message: "未检测到 Codex 命令行（桌面版 App 不含 CLI），额度读取需要安装 Codex CLI"
                )
            }
            return providerErrorSnapshot(
                providerId: id,
                displayName: displayName,
                message: ProviderErrorMessage.sanitized(providerName: displayName, errorMessage: error.localizedDescription)
            )
        }
    }

    // TokenMeter 由 LaunchAgent 拉起，继承的 PATH 只有系统四件套
    // （/usr/bin:/bin:/usr/sbin:/sbin），既没有 node（常见于 .volta/bin
    // 等版本管理器路径），也没有 codex 本体（常见于 .local/bin）。子进程
    // 靠 `env node` 按名字查找，PATH 里没有就直接失败——显式拼一条更完整
    // 的 PATH 传给子进程，不依赖父进程继承到的贫瘠环境。
    static func executableSearchPath(homeDirectory: String = NSHomeDirectory()) -> String {
        searchDirectories(homeDirectory: homeDirectory).joined(separator: ":")
    }

    static func searchDirectories(homeDirectory: String = NSHomeDirectory()) -> [String] {
        [
            URL(fileURLWithPath: homeDirectory).appendingPathComponent(".local/bin").path,
            // standalone 安装器的固定装点（~/.local/bin/codex 只是指向它的链接）：
            // 用户 PATH 没配好、或只装了桌面版但装过 standalone 时，靠它兜底。
            URL(fileURLWithPath: homeDirectory).appendingPathComponent(".codex/packages/standalone/current/bin").path,
            URL(fileURLWithPath: homeDirectory).appendingPathComponent(".volta/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
    }

    /// codex 命令行在所有候选目录里都找不到时，额度取数必然失败——给用户一句
    /// 说得清原因的话（桌面版 App 不含 CLI，这是最常见的困惑来源）。
    static func codexExecutableExists(homeDirectory: String = NSHomeDirectory()) -> Bool {
        searchDirectories(homeDirectory: homeDirectory).contains { directory in
            FileManager.default.isExecutableFile(atPath: "\(directory)/codex")
        }
    }

    private static let nodeScript = """
    const { spawn } = require("child_process");
    const proc = spawn("codex", ["app-server", "--stdio"], { stdio: ["pipe", "pipe", "ignore"] });
    let buffer = "";
    let done = false;
    const timer = setTimeout(() => finish(1), 9000);
    function send(message) { proc.stdin.write(`${JSON.stringify(message)}\\n`); }
    function finish(code, output) {
      if (done) return;
      done = true;
      clearTimeout(timer);
      if (output) process.stdout.write(JSON.stringify(output));
      proc.kill("SIGTERM");
      process.exit(code);
    }
    function handle(message) {
      if (message.id !== 1) return;
      if (!message.result) return finish(1);
      finish(0, message.result);
    }
    proc.stdout.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      for (;;) {
        const index = buffer.indexOf("\\n");
        if (index < 0) break;
        const line = buffer.slice(0, index).trim();
        buffer = buffer.slice(index + 1);
        if (!line) continue;
        try { handle(JSON.parse(line)); } catch { finish(1); }
      }
    });
    proc.on("error", () => finish(1));
    proc.on("exit", () => finish(1));
    send({ method: "initialize", id: 0, params: { clientInfo: { name: "token_meter", title: "TokenMeter", version: "0.1.0" }, capabilities: { experimentalApi: true } } });
    send({ method: "initialized", params: {} });
    setTimeout(() => send({ method: "account/rateLimits/read", id: 1, params: null }), 300);
    """
}

public struct ClaudeCodeUsageProvider: UsageProvider {
    public let id: String
    public let displayName: String

    private let urlSession: URLSession

    public init(config: ProviderConfig, urlSession: URLSession = .shared) {
        self.id = config.id
        self.displayName = config.displayName
        self.urlSession = urlSession
    }

    /// 与本机 Claude Code 同版本的 UA：oauth/usage 会拒绝过旧的客户端版本号
    /// （硬编码 2.1.168 时实测持续 429，同一 token 换真实版本立刻 200）。
    /// ~/.local/bin/claude 是指向版本目录的符号链接，目标的末段就是版本号。
    static func clientVersion(homeDirectory: String = NSHomeDirectory()) -> String {
        let linkPath = "\(homeDirectory)/.local/bin/claude"
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath) {
            let version = (destination as NSString).lastPathComponent
            if !version.isEmpty, version.allSatisfy({ $0.isNumber || $0 == "." }) {
                return version
            }
        }
        return "2.1.207"
    }

    public func fetchUsage() async -> UsageSnapshot {
        await fetchProviderUsage().legacySnapshot
    }

    public func fetchProviderUsage() async -> ProviderUsageSnapshot {
        do {
            let credentialData = try await Task.detached {
                try runProcess(
                    executable: "/usr/bin/security",
                    arguments: ["find-generic-password", "-s", "Claude Code-credentials", "-w"],
                    timeout: 5
                )
            }.value
            let token = try ClaudeCredentialParser.accessToken(from: credentialData)
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("true", forHTTPHeaderField: "anthropic-dangerous-direct-browser-access")
            request.setValue("cli", forHTTPHeaderField: "x-app")
            request.setValue("claude-cli/\(Self.clientVersion()) (external, cli)", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await urlSession.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                return providerErrorSnapshot(
                    providerId: id,
                    displayName: displayName,
                    message: ProviderHTTPErrorFormatter.message(
                        providerName: "Claude",
                        statusCode: httpResponse.statusCode,
                        data: data,
                        retryAfter: httpResponse.value(forHTTPHeaderField: "retry-after")
                    )
                )
            }

            return try ClaudeUsageParser.parse(data: data, providerId: id, displayName: displayName)
        } catch {
            return providerErrorSnapshot(
                providerId: id,
                displayName: displayName,
                message: ProviderErrorMessage.sanitized(providerName: "Claude", errorMessage: error.localizedDescription)
            )
        }
    }
}

public struct ZhipuUsageProvider: UsageProvider {
    public let id: String
    public let displayName: String

    private let config: ProviderConfig
    private let urlSession: URLSession
    private let environment: [String: String]
    private let keychainToken: (String) -> String?

    public init(
        config: ProviderConfig,
        urlSession: URLSession = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keychainToken: @escaping (String) -> String? = { KeychainCredentialStore.token(for: $0) }
    ) {
        self.config = config
        self.id = config.id
        self.displayName = config.displayName
        self.urlSession = urlSession
        self.environment = environment
        self.keychainToken = keychainToken
    }

    public func fetchUsage() async -> UsageSnapshot {
        await fetchProviderUsage().legacySnapshot
    }

    public func fetchProviderUsage() async -> ProviderUsageSnapshot {
        guard let endpoint = config.endpoint, let url = URL(string: endpoint) else {
            return providerErrorSnapshot(providerId: id, displayName: displayName, message: "智谱 endpoint 缺失")
        }

        // 应用内填的 Key（钥匙串）优先——那是用户的显式意图；没填才回落环境变量。
        guard let token = keychainToken(id) ?? environmentCredentialToken(config.credential, environment: environment) else {
            return providerErrorSnapshot(providerId: id, displayName: displayName, message: "缺少智谱 API Key")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(token, forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await urlSession.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                return providerErrorSnapshot(providerId: id, displayName: displayName, message: "智谱接口返回 \(httpResponse.statusCode)")
            }

            return try ZhipuUsageParser.parseProviderUsage(data: data, providerId: id, displayName: displayName)
        } catch {
            return providerErrorSnapshot(
                providerId: id,
                displayName: displayName,
                message: ProviderErrorMessage.sanitized(providerName: displayName, errorMessage: error.localizedDescription)
            )
        }
    }

    private func errorSnapshot(_ message: String) -> UsageSnapshot {
        UsageSnapshot(
            providerId: id,
            displayName: displayName,
            status: .error,
            label: "余额",
            used: nil,
            remaining: nil,
            total: nil,
            unit: "CNY",
            fetchedAt: Date(),
            message: message
        )
    }
}

public struct ShellCommandUsageProvider: UsageProvider {
    public let id: String
    public let displayName: String

    private let config: ProviderConfig

    public init(config: ProviderConfig) {
        self.config = config
        self.id = config.id
        self.displayName = config.displayName
    }

    public func fetchUsage() async -> UsageSnapshot {
        guard let command = config.command else {
            return errorSnapshot("命令配置缺失")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: expandHome(command.executable))
        process.arguments = command.arguments.map(expandHome)
        process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, new in new }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: data, as: UTF8.self)

            guard process.terminationStatus == 0 else {
                return errorSnapshot("命令退出 \(process.terminationStatus)")
            }

            return try ShellQuotaParser.parse(output: output, providerId: id, displayName: displayName)
        } catch {
            return errorSnapshot(error.localizedDescription)
        }
    }

    private func errorSnapshot(_ message: String) -> UsageSnapshot {
        UsageSnapshot(
            providerId: id,
            displayName: displayName,
            status: .error,
            label: "额度",
            used: nil,
            remaining: nil,
            total: nil,
            unit: "%",
            fetchedAt: Date(),
            message: message
        )
    }
}

public struct OpenCodeGoUsageProvider: UsageProvider {
    public let id: String
    public let displayName: String

    private let environment: [String: String]

    public init(config: ProviderConfig, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.id = config.id
        self.displayName = config.displayName
        self.environment = environment
    }

    public func fetchUsage() async -> UsageSnapshot {
        let resolvedConfig = OpenCodeGoConfigParser.resolve(environment: environment)
        let workspaceId = resolvedConfig?.workspaceId
        let authCookie = resolvedConfig?.authCookie

        guard let workspaceId, !workspaceId.isEmpty else {
            return errorSnapshot("缺少 OPENCODE_GO_WORKSPACE_ID")
        }

        guard let authCookie, !authCookie.isEmpty else {
            return errorSnapshot("缺少 OPENCODE_GO_AUTH_COOKIE")
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "opencode.ai"
        components.path = "/workspace/\(workspaceId)/go"

        guard let url = components.url else {
            return errorSnapshot("OpenCode Go workspace URL 无效")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("auth=\(authCookie)", forHTTPHeaderField: "Cookie")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Gecko/20100101 Firefox/148.0",
            forHTTPHeaderField: "User-Agent"
        )

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                return errorSnapshot("OpenCode Go dashboard 返回 \(httpResponse.statusCode)")
            }

            let html = String(decoding: data, as: UTF8.self)
            return try OpenCodeGoParser.parse(html: html, providerId: id, displayName: displayName)
        } catch {
            return errorSnapshot(error.localizedDescription)
        }
    }

    private func errorSnapshot(_ message: String) -> UsageSnapshot {
        UsageSnapshot(
            providerId: id,
            displayName: displayName,
            status: .error,
            label: "额度",
            used: nil,
            remaining: nil,
            total: nil,
            unit: "%",
            fetchedAt: Date(),
            message: message
        )
    }
}

public struct OpenCodeGoConfig: Equatable {
    public let workspaceId: String
    public let authCookie: String
}

public enum OpenCodeGoConfigParser {
    public enum ParseError: LocalizedError {
        case invalidShape
        case missingWorkspaceId
        case missingAuthCookie

        public var errorDescription: String? {
            switch self {
            case .invalidShape:
                return "OpenCode Go 配置必须是 JSON object"
            case .missingWorkspaceId:
                return "OpenCode Go 配置缺少 workspaceId"
            case .missingAuthCookie:
                return "OpenCode Go 配置缺少 authCookie"
            }
        }
    }

    public static func parse(_ data: Data) throws -> OpenCodeGoConfig {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw ParseError.invalidShape
        }

        guard let workspaceId = (dictionary["workspaceId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !workspaceId.isEmpty else {
            throw ParseError.missingWorkspaceId
        }

        guard let authCookie = (dictionary["authCookie"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !authCookie.isEmpty else {
            throw ParseError.missingAuthCookie
        }

        return OpenCodeGoConfig(workspaceId: workspaceId, authCookie: authCookie)
    }

    static func resolve(environment: [String: String]) -> OpenCodeGoConfig? {
        let workspaceId = environment["OPENCODE_GO_WORKSPACE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let authCookie = environment["OPENCODE_GO_AUTH_COOKIE"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let workspaceId, !workspaceId.isEmpty,
           let authCookie, !authCookie.isEmpty {
            return OpenCodeGoConfig(workspaceId: workspaceId, authCookie: authCookie)
        }

        let url = URL(fileURLWithPath: expandHome("~/.config/opencode/opencode-quota/opencode-go.json"))
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        return try? parse(data)
    }
}

public enum OpenCodeGoParser {
    public enum ParseError: LocalizedError {
        case missingUsageWindows

        public var errorDescription: String? {
            "没有从 OpenCode Go dashboard 解析到 rolling/weekly/monthly usage"
        }
    }

    public static func parse(html: String, providerId: String, displayName: String) throws -> UsageSnapshot {
        var windows = [
            window(html: html, key: "rollingUsage", label: "5h"),
            window(html: html, key: "weeklyUsage", label: "Weekly"),
            window(html: html, key: "monthlyUsage", label: "Monthly")
        ].compactMap { $0 }

        if windows.isEmpty {
            windows = dataSlotWindows(html: html)
        }

        guard let first = windows.first else {
            throw ParseError.missingUsageWindows
        }

        let message = windows
            .map { "\($0.label) \(UsageFormatter.numberText(100 - $0.usagePercent))%" }
            .joined(separator: " · ")

        return UsageSnapshot(
            providerId: providerId,
            displayName: displayName,
            status: .ok,
            label: first.label,
            used: first.usagePercent,
            remaining: 100 - first.usagePercent,
            total: 100,
            unit: "%",
            fetchedAt: Date(),
            message: message
        )
    }

    private struct Window {
        let label: String
        let usagePercent: Double
    }

    private static func window(html: String, key: String, label: String) -> Window? {
        let number = #"(-?\d+(?:\.\d+)?)"#
        let percentFirst = "\(key):\\$R\\[\\d+\\]=\\{[^}]*usagePercent:\(number)[^}]*resetInSec:\(number)[^}]*\\}"
        let resetFirst = "\(key):\\$R\\[\\d+\\]=\\{[^}]*resetInSec:\(number)[^}]*usagePercent:\(number)[^}]*\\}"

        if let match = firstMatch(in: html, pattern: percentFirst, group: 1) {
            return Window(label: label, usagePercent: match)
        }

        if let match = firstMatch(in: html, pattern: resetFirst, group: 2) {
            return Window(label: label, usagePercent: match)
        }

        return nil
    }

    private static func dataSlotWindows(html: String) -> [Window] {
        let parts = html.components(separatedBy: #"data-slot="usage-item""#)
        guard parts.count > 1 else {
            return []
        }

        var windows: [Window] = []
        for content in parts.dropFirst() {
            guard let label = firstStringMatch(
                in: content,
                pattern: #"data-slot="usage-label">([^<]+)<"#,
                group: 1
            )?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
                continue
            }

            guard let usagePercent = firstMatch(
                in: content,
                pattern: #"data-slot="usage-value">[^0-9]*(\d+(?:\.\d+)?)"#,
                group: 1
            ) else {
                continue
            }

            if label.contains("rolling") {
                windows.append(Window(label: "5h", usagePercent: usagePercent))
            } else if label.contains("weekly") {
                windows.append(Window(label: "Weekly", usagePercent: usagePercent))
            } else if label.contains("monthly") {
                windows.append(Window(label: "Monthly", usagePercent: usagePercent))
            }
        }

        return windows
    }

    private static func firstMatch(in text: String, pattern: String, group: Int) -> Double? {
        guard let value = firstStringMatch(in: text, pattern: pattern, group: group) else {
            return nil
        }

        return Double(value)
    }

    private static func firstStringMatch(in text: String, pattern: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > group,
              let valueRange = Range(match.range(at: group), in: text) else {
            return nil
        }

        return String(text[valueRange])
    }
}

public enum ShellQuotaParser {
    public enum ParseError: LocalizedError {
        case emptyOutput
        case missingPercent

        public var errorDescription: String? {
            switch self {
            case .emptyOutput:
                return "命令没有输出"
            case .missingPercent:
                return "命令输出中没有百分比"
            }
        }
    }

    public static func parse(output: String, providerId: String, displayName: String) throws -> UsageSnapshot {
        let plain = stripTmuxStyle(output)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !plain.isEmpty else {
            throw ParseError.emptyOutput
        }

        guard let percent = firstPercent(in: plain) else {
            throw ParseError.missingPercent
        }

        return UsageSnapshot(
            providerId: providerId,
            displayName: displayName,
            status: .ok,
            label: "额度",
            used: 100 - percent,
            remaining: percent,
            total: 100,
            unit: "%",
            fetchedAt: Date(),
            message: plain
        )
    }

    static func stripTmuxStyle(_ output: String) -> String {
        output.replacingOccurrences(
            of: #"#\[[^\]]*\]"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func firstPercent(in text: String) -> Double? {
        guard let range = text.range(of: #"\d+(?:\.\d+)?%"#, options: .regularExpression) else {
            return nil
        }

        return Double(text[range].dropLast())
    }
}

public struct QuotaCacheUsageProvider: UsageProvider {
    public let id: String
    public let displayName: String

    private let config: ProviderConfig

    public init(config: ProviderConfig) {
        self.config = config
        self.id = config.id
        self.displayName = config.displayName
    }

    public func fetchUsage() async -> UsageSnapshot {
        guard let quotaCache = config.quotaCache else {
            return errorSnapshot("缓存配置缺失")
        }

        let directory = URL(fileURLWithPath: expandHome(quotaCache.directory))
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            let candidates = urls.filter { $0.lastPathComponent.hasPrefix("\(quotaCache.providerId)-") }
            guard let newest = candidates.max(by: { lhs, rhs in
                modificationDate(lhs) < modificationDate(rhs)
            }) else {
                return errorSnapshot(missingCacheMessage(for: quotaCache.providerId))
            }

            return try QuotaCacheParser.parse(data: Data(contentsOf: newest), providerId: id, displayName: displayName)
        } catch {
            return errorSnapshot(error.localizedDescription)
        }
    }

    private func errorSnapshot(_ message: String) -> UsageSnapshot {
        UsageSnapshot(
            providerId: id,
            displayName: displayName,
            status: .error,
            label: "额度",
            used: nil,
            remaining: nil,
            total: nil,
            unit: "%",
            fetchedAt: Date(),
            message: message
        )
    }

    private func missingCacheMessage(for providerId: String) -> String {
        if providerId == "opencode-go" {
            return "需要 OpenCode Go workspace ID 和 auth cookie"
        }

        return "未找到 \(providerId) quota 缓存"
    }
}

public enum QuotaCacheParser {
    public enum ParseError: LocalizedError {
        case noEntry

        public var errorDescription: String? {
            "quota 缓存中没有可展示的额度"
        }
    }

    public static func parse(data: Data, providerId: String, displayName: String) throws -> UsageSnapshot {
        let object = try JSONSerialization.jsonObject(with: data)
        let entries = percentEntries(in: object)
        guard let entry = entries.first else {
            throw ParseError.noEntry
        }

        let remaining = entry.percentRemaining
        let label = entry.label.trimmingCharacters(in: CharacterSet(charactersIn: ":："))
        let message = entries
            .map { entry in
                let cleanLabel = entry.label.trimmingCharacters(in: CharacterSet(charactersIn: ":："))
                return "\(cleanLabel) \(UsageFormatter.numberText(entry.percentRemaining))%"
            }
            .joined(separator: " · ")

        return UsageSnapshot(
            providerId: providerId,
            displayName: displayName,
            status: .ok,
            label: label.isEmpty ? "额度" : label,
            used: 100 - remaining,
            remaining: remaining,
            total: 100,
            unit: "%",
            fetchedAt: Date(),
            message: message
        )
    }

    private struct PercentEntry {
        let label: String
        let percentRemaining: Double
    }

    private static func percentEntries(in object: Any) -> [PercentEntry] {
        if let dictionary = object as? [String: Any] {
            if let percent = TokenMeterCoreNumber.number(from: dictionary["percentRemaining"]) {
                let label = dictionary["label"] as? String ?? dictionary["name"] as? String ?? "额度"
                return [PercentEntry(label: label, percentRemaining: percent)]
            }

            for key in ["result", "data"] {
                if let value = dictionary[key] {
                    let entries = percentEntries(in: value)
                    if !entries.isEmpty {
                        return entries
                    }
                }
            }

            return dictionary.values.flatMap(percentEntries)
        }

        if let array = object as? [Any] {
            return array.flatMap(percentEntries)
        }

        return []
    }
}

public enum CodexUsageParser {
    public enum ParseError: LocalizedError {
        case missingRateLimits

        public var errorDescription: String? {
            "Codex 响应中没有 rate limit 数据"
        }
    }

    public static func parse(
        data: Data,
        providerId: String,
        displayName: String,
        fetchedAt: Date = Date()
    ) throws -> ProviderUsageSnapshot {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any],
              let buckets = dictionary["rateLimitsByLimitId"] as? [String: Any] else {
            throw ParseError.missingRateLimits
        }

        let groups = buckets
            .compactMap { key, value -> UsageGroup? in
                guard let bucket = value as? [String: Any] else {
                    return nil
                }

                let title = (bucket["limitName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (key == "codex" ? "Codex" : readableIdentifier(key))

                let items = [
                    codexMetric(bucket["primary"], id: "\(key)-primary"),
                    codexMetric(bucket["secondary"], id: "\(key)-secondary")
                ].compactMap { $0 }

                guard !items.isEmpty else {
                    return nil
                }

                return UsageGroup(id: key, title: title, subtitle: nil, items: items)
            }
            .sorted { lhs, rhs in
                if lhs.id == "codex" {
                    return true
                }
                if rhs.id == "codex" {
                    return false
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }

        guard !groups.isEmpty else {
            throw ParseError.missingRateLimits
        }

        let summary = groups
            .flatMap { group in group.items.map { "\(group.title) \($0.label) \(UsageFormatter.numberText($0.remainingPercent ?? 0))%" } }
            .joined(separator: " · ")

        return ProviderUsageSnapshot(
            providerId: providerId,
            displayName: displayName,
            status: .ok,
            fetchedAt: fetchedAt,
            summary: summary,
            message: nil,
            groups: groups
        )
    }

    /// 窗口标签由数据驱动（300 → 5h、10080 → 7d、1440 → 1d）：上游增删或改窗口
    /// 时长都不用改代码。以前硬编码 primary=5h、secondary=7d，Codex 取消 5h
    /// 窗口（primary 直接变成周窗口）后，周额度被错标成了「5h」。
    static func windowLabel(minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "额度" }
        if minutes % (24 * 60) == 0 { return "\(minutes / (24 * 60))d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    private static func codexMetric(_ value: Any?, id: String) -> UsageMetric? {
        guard let dictionary = value as? [String: Any],
              let used = TokenMeterCoreNumber.number(from: dictionary["usedPercent"]) else {
            return nil
        }

        let resetAt = date(fromEpochSeconds: TokenMeterCoreNumber.number(from: dictionary["resetsAt"]))
        let windowDurationMinutes = TokenMeterCoreNumber.number(from: dictionary["windowDurationMins"]).map(Int.init)

        return UsageMetric(
            id: id,
            label: windowLabel(minutes: windowDurationMinutes),
            kind: .quota,
            usedPercent: clampPercent(used),
            remainingPercent: clampPercent(100 - used),
            resetText: resetAt.map(countdownText),
            status: .ok,
            detail: nil,
            resetAt: resetAt,
            windowDurationMinutes: windowDurationMinutes
        )
    }
}

public enum CodexResetCreditsParser {
    public enum ParseError: LocalizedError {
        case missingCredits

        public var errorDescription: String? {
            "Codex 重置卡响应中没有 credits 数据"
        }
    }

    public static func parse(data: Data) throws -> ResetCreditSummary {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any],
              let credits = dictionary["credits"] as? [[String: Any]] else {
            throw ParseError.missingCredits
        }

        return ResetCreditSummary(
            availableCount: credits.count,
            credits: credits.map { credit in
                ResetCredit(
                    issuedAt: codexResetCreditDate(credit["granted_at"])
                        ?? codexResetCreditDate(credit["created_at"])
                        ?? codexResetCreditDate(credit["issued_at"]),
                    expiresAt: codexResetCreditDate(credit["expires_at"])
                )
            }
        )
    }
}

public struct CodexResetCreditsClient {
    public let authURL: URL
    public let endpoint: URL
    public let urlSession: URLSession

    public static let `default` = CodexResetCreditsClient(
        authURL: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json"),
        endpoint: URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
    )

    public init(authURL: URL, endpoint: URL, urlSession: URLSession = .shared) {
        self.authURL = authURL
        self.endpoint = endpoint
        self.urlSession = urlSession
    }

    public func fetch() async throws -> ResetCreditSummary {
        let token = try readAccessToken()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("TokenMeter/0.1", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await urlSession.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode == 401 {
            throw CodexResetCreditsError.unauthorized
        }
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw CodexResetCreditsError.httpStatus(httpResponse.statusCode)
        }

        return try CodexResetCreditsParser.parse(data: data)
    }

    private func readAccessToken() throws -> String {
        let data = try Data(contentsOf: authURL)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any],
              let tokens = dictionary["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              !accessToken.isEmpty else {
            throw CodexResetCreditsError.missingAccessToken
        }

        return accessToken
    }
}

public enum ClaudeUsageParser {
    public enum ParseError: LocalizedError {
        case missingUsage

        public var errorDescription: String? {
            "Claude 响应中没有 usage 数据"
        }
    }

    public static func parse(
        data: Data,
        providerId: String,
        displayName: String,
        fetchedAt: Date = Date()
    ) throws -> ProviderUsageSnapshot {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw ParseError.missingUsage
        }

        var groups: [UsageGroup] = []
        let baseItems = [
            claudeMetric(dictionary["five_hour"], id: "claude-5h", label: "5h", windowDurationMinutes: 300),
            claudeMetric(dictionary["seven_day"], id: "claude-7d", label: "7d", windowDurationMinutes: 10_080)
        ].compactMap { $0 }

        if !baseItems.isEmpty {
            groups.append(UsageGroup(id: "claude", title: displayName, subtitle: nil, items: baseItems))
        }

        let modelFields: [(key: String, title: String)] = [
            ("seven_day_sonnet", "Sonnet"),
            ("seven_day_fable", "Fable"),
            ("seven_day_opus", "Opus"),
            ("seven_day_oauth_apps", "OAuth Apps"),
            ("seven_day_cowork", "Cowork"),
            ("seven_day_omelette", "Omelette")
        ]

        for field in modelFields {
            guard let metric = claudeMetric(
                dictionary[field.key],
                id: "claude-\(field.key)",
                label: "7d",
                windowDurationMinutes: 10_080
            ) else {
                continue
            }

            groups.append(UsageGroup(id: field.key, title: field.title, subtitle: nil, items: [metric]))
        }

        groups.append(
            contentsOf: scopedWeeklyLimitGroups(
                dictionary["limits"],
                existingTitles: Set(groups.map { $0.title.lowercased() })
            )
        )

        guard !groups.isEmpty else {
            throw ParseError.missingUsage
        }

        let summary = groups
            .flatMap { group in group.items.map { "\(group.title) \($0.label) \(UsageFormatter.numberText($0.remainingPercent ?? 0))%" } }
            .joined(separator: " · ")

        return ProviderUsageSnapshot(
            providerId: providerId,
            displayName: displayName,
            status: .ok,
            fetchedAt: fetchedAt,
            summary: summary,
            message: nil,
            groups: groups
        )
    }

    private static func claudeMetric(_ value: Any?, id: String, label: String, windowDurationMinutes: Int) -> UsageMetric? {
        guard let dictionary = value as? [String: Any],
              let utilization = TokenMeterCoreNumber.number(from: dictionary["utilization"]) else {
            return nil
        }

        let resetAt = date(fromIsoString: dictionary["resets_at"] as? String)

        return UsageMetric(
            id: id,
            label: label,
            kind: .quota,
            usedPercent: clampPercent(utilization),
            remainingPercent: clampPercent(100 - utilization),
            resetText: resetAt.map(countdownText),
            status: .ok,
            detail: nil,
            resetAt: resetAt,
            windowDurationMinutes: windowDurationMinutes
        )
    }

    private static func scopedWeeklyLimitGroups(_ value: Any?, existingTitles: Set<String>) -> [UsageGroup] {
        guard let limits = value as? [[String: Any]] else {
            return []
        }

        var seenTitles = existingTitles
        var groups: [UsageGroup] = []
        for limit in limits {
            guard limit["kind"] as? String == "weekly_scoped",
                  let scope = limit["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  let title = nonEmptyString(model["display_name"]),
                  !seenTitles.contains(title.lowercased()),
                  let usedPercent = TokenMeterCoreNumber.number(from: limit["percent"]) else {
                continue
            }

            seenTitles.insert(title.lowercased())
            let resetAt = date(fromIsoString: limit["resets_at"] as? String)
            let metric = UsageMetric(
                id: "claude-weekly-\(stableMetricIdentifier(title))",
                label: "7d",
                kind: .quota,
                usedPercent: clampPercent(usedPercent),
                remainingPercent: clampPercent(100 - usedPercent),
                resetText: resetAt.map(countdownText),
                status: .ok,
                detail: nil,
                resetAt: resetAt,
                windowDurationMinutes: 10_080
            )
            groups.append(UsageGroup(id: "weekly-scoped-\(stableMetricIdentifier(title))", title: title, subtitle: nil, items: [metric]))
        }

        return groups
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let text = value as? String else {
            return nil
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stableMetricIdentifier(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
        var result = ""
        var lastWasSeparator = false

        for scalar in value.lowercased().unicodeScalars {
            if allowed.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                result.append("-")
                lastWasSeparator = true
            }
        }

        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

public enum ClaudeCredentialParser {
    public enum ParseError: LocalizedError {
        case missingAccessToken

        public var errorDescription: String? {
            "Claude Code 登录凭据中没有 access token"
        }
    }

    public static func accessToken(from data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw ParseError.missingAccessToken
        }

        let oauth = dictionary["claudeAiOauth"] as? [String: Any] ?? dictionary
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw ParseError.missingAccessToken
        }

        return token
    }
}

public enum ProviderHTTPErrorFormatter {
    public static func message(providerName: String, statusCode: Int, data: Data, retryAfter: String?) -> String {
        let bodyMessage = responseMessage(from: data)
        let prefix: String

        if statusCode == 429 {
            prefix = "\(providerName) 接口限流"
        } else {
            prefix = "\(providerName) 接口返回 \(statusCode)"
        }

        guard let bodyMessage, !bodyMessage.isEmpty else {
            return prefix
        }

        return "\(prefix)：\(bodyMessage)"
    }

    private static func responseMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let dictionary = object as? [String: Any] {
            if let message = dictionary["message"] as? String {
                return message
            }

            if let error = dictionary["error"] as? [String: Any] {
                if let message = error["message"] as? String {
                    return message
                }

                if let type = error["type"] as? String {
                    return type
                }
            }

            if let error = dictionary["error"] as? String {
                return error
            }
        }

        return nil
    }
}

public struct OpenCodeSQLiteUsageProvider: UsageProvider {
    public let id: String
    public let displayName: String

    private let config: ProviderConfig

    public init(config: ProviderConfig) {
        self.config = config
        self.id = config.id
        self.displayName = config.displayName
    }

    public func fetchUsage() async -> UsageSnapshot {
        guard let databasePath = config.databasePath else {
            return errorSnapshot("数据库路径缺失")
        }

        let database = expandHome(databasePath)
        let sql = "select count(*), coalesce(sum(tokens_input),0), coalesce(sum(tokens_output),0), coalesce(sum(tokens_cache_read),0), coalesce(sum(tokens_cache_write),0), coalesce(sum(tokens_reasoning),0) from session;"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database, sql]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

            guard process.terminationStatus == 0 else {
                return errorSnapshot("sqlite3 退出 \(process.terminationStatus)")
            }

            let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|")
            guard parts.count >= 6,
                  let sessions = Double(parts[0]),
                  let input = Double(parts[1]),
                  let outputTokens = Double(parts[2]),
                  let cacheRead = Double(parts[3]),
                  let cacheWrite = Double(parts[4]),
                  let reasoning = Double(parts[5]) else {
                return errorSnapshot("OpenCode SQLite 输出无法解析")
            }

            let total = input + outputTokens + cacheRead + cacheWrite + reasoning
            return UsageSnapshot(
                providerId: id,
                displayName: displayName,
                status: .ok,
                label: "累计",
                used: total,
                remaining: sessions,
                total: nil,
                unit: "tokens",
                fetchedAt: Date(),
                message: "\(Int(sessions)) sessions · \(compactTokenText(total)) tokens"
            )
        } catch {
            return errorSnapshot(error.localizedDescription)
        }
    }

    private func errorSnapshot(_ message: String) -> UsageSnapshot {
        UsageSnapshot(
            providerId: id,
            displayName: displayName,
            status: .error,
            label: "累计",
            used: nil,
            remaining: nil,
            total: nil,
            unit: "tokens",
            fetchedAt: Date(),
            message: message
        )
    }
}

public enum ProviderRegistry {
    public static func makeProviders(from config: TokenMeterConfig) -> [UsageProvider] {
        config.providers
            .filter(\.enabled)
            .map { providerConfig in
                switch providerConfig.type {
                case .claudeCode:
                    return ClaudeCodeUsageProvider(config: providerConfig)
                case .codex:
                    return CodexUsageProvider(config: providerConfig)
                case .manual:
                    return ManualUsageProvider(config: providerConfig)
                case .opencodeGo:
                    return OpenCodeGoUsageProvider(config: providerConfig)
                case .opencodeSQLite:
                    return OpenCodeSQLiteUsageProvider(config: providerConfig)
                case .quotaCache:
                    return QuotaCacheUsageProvider(config: providerConfig)
                case .shellCommand:
                    return ShellCommandUsageProvider(config: providerConfig)
                case .zhipu:
                    return ZhipuUsageProvider(config: providerConfig)
                }
            }
    }
}

public enum ZhipuUsageParser {
    public enum ParseError: LocalizedError {
        case businessFailure(String)
        case missingUsageFields

        public var errorDescription: String? {
            switch self {
            case let .businessFailure(message):
                return message
            case .missingUsageFields:
                return "智谱响应中没有可用的额度字段"
            }
        }
    }

    public static func parse(data: Data, providerId: String, displayName: String) throws -> UsageSnapshot {
        let object = try JSONSerialization.jsonObject(with: data)
        if let dictionary = object as? [String: Any],
           let success = dictionary["success"] as? Bool,
           !success {
            let message = dictionary["msg"] as? String ?? "智谱接口返回业务失败"
            throw ParseError.businessFailure(message)
        }

        if let snapshot = parseLimits(object: object, providerId: providerId, displayName: displayName) {
            return snapshot
        }

        let usedPercent = findNumber(in: object, keys: ["percentage"])
        let used = findNumber(in: object, keys: ["used", "used_quota", "usedQuota", "usage"]) ?? usedPercent
        let remaining = findNumber(in: object, keys: ["remaining", "remain", "remain_quota", "remaining_quota", "available"]) ?? usedPercent.map { 100 - $0 }
        let total = findNumber(in: object, keys: ["total", "total_quota", "totalQuota", "limit"])

        guard used != nil || remaining != nil || total != nil else {
            throw ParseError.missingUsageFields
        }

        return UsageSnapshot(
            providerId: providerId,
            displayName: displayName,
            status: .ok,
            label: "余额",
            used: used,
            remaining: remaining,
            total: total,
            unit: "CNY",
            fetchedAt: Date(),
            message: nil
        )
    }

    public static func parseProviderUsage(
        data: Data,
        providerId: String,
        displayName: String,
        fetchedAt: Date = Date()
    ) throws -> ProviderUsageSnapshot {
        let object = try JSONSerialization.jsonObject(with: data)
        if let dictionary = object as? [String: Any],
           let success = dictionary["success"] as? Bool,
           !success {
            let message = dictionary["msg"] as? String ?? "智谱接口返回业务失败"
            throw ParseError.businessFailure(message)
        }

        guard let dictionary = object as? [String: Any],
              let payload = dictionary["data"] as? [String: Any],
              let limits = payload["limits"] as? [[String: Any]] else {
            let legacy = try parse(data: data, providerId: providerId, displayName: displayName)
            return ProviderUsageSnapshot(legacy: legacy)
        }

        let metrics = zhipuMetrics(from: limits)
        guard !metrics.isEmpty else {
            throw ParseError.missingUsageFields
        }

        let summary = metrics
            .map { "\($0.label) \(UsageFormatter.numberText($0.remainingPercent ?? 0))%" }
            .joined(separator: " · ")

        return ProviderUsageSnapshot(
            providerId: providerId,
            displayName: displayName,
            status: .ok,
            fetchedAt: fetchedAt,
            summary: summary,
            message: nil,
            groups: [
                UsageGroup(
                    id: "zhipu-coding-plan",
                    // 与 displayName 同名 → 弹窗按「主组」处理，标签只留 5h/7d/MCP。
                    // 曾写作「智谱 Coding Plan」，拼上窗口后（智谱 Coding Plan 5h）超宽。
                    title: displayName,
                    subtitle: nil,
                    items: metrics
                )
            ]
        )
    }

    private static func findNumber(in object: Any, keys: Set<String>) -> Double? {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                if keys.contains(key), let number = number(from: value) {
                    return number
                }
            }

            for value in dictionary.values {
                if let number = findNumber(in: value, keys: keys) {
                    return number
                }
            }
        }

        if let array = object as? [Any] {
            for value in array {
                if let number = findNumber(in: value, keys: keys) {
                    return number
                }
            }
        }

        return nil
    }

    private static func number(from value: Any) -> Double? {
        TokenMeterCoreNumber.number(from: value)
    }

    private static func parseLimits(object: Any, providerId: String, displayName: String) -> UsageSnapshot? {
        guard let dictionary = object as? [String: Any],
              let data = dictionary["data"] as? [String: Any],
              let limits = data["limits"] as? [[String: Any]] else {
            return nil
        }

        var fiveHour: Double?
        var weekly: Double?
        var mcp: Double?

        for limit in limits {
            guard let percentage = number(from: limit["percentage"] as Any),
                  let type = limit["type"] as? String,
                  let unit = number(from: limit["unit"] as Any) else {
                continue
            }

            let remaining = max(0, min(100, 100 - percentage))

            if type == "TOKENS_LIMIT", Int(unit) == 3 {
                fiveHour = remaining
            } else if type == "TOKENS_LIMIT", Int(unit) == 6 {
                weekly = remaining
            } else if type == "TIME_LIMIT", Int(unit) == 5 {
                mcp = remaining
            }
        }

        let entries: [(label: String, remaining: Double)] = [
            fiveHour.map { ("5h", $0) },
            weekly.map { ("Weekly", $0) },
            mcp.map { ("MCP", $0) }
        ].compactMap { $0 }

        guard let first = entries.first else {
            return nil
        }

        let message = entries
            .map { "\($0.label) \(UsageFormatter.numberText($0.remaining))%" }
            .joined(separator: " · ")

        return UsageSnapshot(
            providerId: providerId,
            displayName: displayName,
            status: .ok,
            label: first.label,
            used: 100 - first.remaining,
            remaining: first.remaining,
            total: 100,
            unit: "%",
            fetchedAt: Date(),
            message: message
        )
    }

    private static func zhipuMetrics(from limits: [[String: Any]]) -> [UsageMetric] {
        var fiveHour: UsageMetric?
        var weekly: UsageMetric?
        var mcp: UsageMetric?

        for limit in limits {
            guard let percentage = number(from: limit["percentage"] as Any),
                  let type = limit["type"] as? String,
                  let unit = number(from: limit["unit"] as Any) else {
                continue
            }

            let used = clampPercent(percentage)
            let remaining = clampPercent(100 - percentage)
            let resetAt = date(fromEpochMilliseconds: number(from: limit["nextResetTime"] as Any))
            let reset = resetAt.map(countdownText)

            if type == "TOKENS_LIMIT", Int(unit) == 3 {
                fiveHour = UsageMetric(
                    id: "zhipu-5h",
                    label: "5h",
                    kind: .quota,
                    usedPercent: used,
                    remainingPercent: remaining,
                    resetText: reset,
                    status: .ok,
                    detail: nil,
                    resetAt: resetAt,
                    windowDurationMinutes: 300
                )
            } else if type == "TOKENS_LIMIT", Int(unit) == 6 {
                weekly = UsageMetric(
                    id: "zhipu-7d",
                    label: "7d",
                    kind: .quota,
                    usedPercent: used,
                    remainingPercent: remaining,
                    resetText: reset,
                    status: .ok,
                    detail: nil,
                    resetAt: resetAt,
                    windowDurationMinutes: 10_080
                )
            } else if type == "TIME_LIMIT", Int(unit) == 5 {
                mcp = UsageMetric(
                    id: "zhipu-mcp",
                    label: "MCP",
                    kind: .quota,
                    usedPercent: used,
                    remainingPercent: remaining,
                    resetText: reset,
                    status: .ok,
                    detail: usageDetail(from: limit),
                    resetAt: resetAt,
                    windowDurationMinutes: nil
                )
            }
        }

        return [fiveHour, weekly, mcp].compactMap { $0 }
    }
}

private func credentialToken(_ credential: CredentialConfig?, environment: [String: String]) -> String? {
    credentialTokens(credential, environment: environment).first
}

private func environmentCredentialToken(_ credential: CredentialConfig?, environment: [String: String]) -> String? {
    guard let name = credential?.environmentVariable else {
        return nil
    }

    if let value = normalizedCredentialToken(environment[name]) {
        return value
    }

    // LaunchAgent 拉起的进程看不到用户在 shell 配置里 export 的变量——
    // 起一次用户登录 shell 查询作回退（智谱额度因此断了十天）。
    return normalizedCredentialToken(LoginShellEnvironment.value(for: name))
}

/// 从用户登录 shell 读环境变量。每个变量只查一次（成败都缓存）：失败的查询带
/// 5s 超时，不缓存的话每轮刷新都会白等一次；代价是用户新配了 key 需重启 app。
enum LoginShellEnvironment {
    nonisolated(unsafe) private static var cache: [String: String?] = [:]
    private static let lock = NSLock()

    static func value(for name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[name] {
            return cached
        }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // fish 与 POSIX shell 的取值语法不同，各给一条最朴素的输出命令。
        let printCommand = shell.hasSuffix("fish") ? "echo -n $\(name)" : "printf %s \"$\(name)\""
        let value = (try? runProcess(
            executable: shell,
            arguments: ["-l", "-c", printCommand],
            timeout: 5
        )).flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let result = (value?.isEmpty == false) ? value : nil
        cache[name] = result
        return result
    }
}

private func credentialTokens(_ credential: CredentialConfig?, environment: [String: String]) -> [String] {
    var tokens: [String] = []

    if let name = credential?.environmentVariable,
       let value = normalizedCredentialToken(environment[name]),
       !value.isEmpty {
        tokens.append(value)
    }

    if let filePath = credential?.filePath {
        let url = URL(fileURLWithPath: expandHome(filePath))
        if let rawValue = try? String(contentsOf: url, encoding: .utf8),
           let value = normalizedCredentialToken(rawValue),
           !value.isEmpty,
           !tokens.contains(value) {
            tokens.append(value)
        }
    }

    return tokens
}

private func normalizedCredentialToken(_ value: String?) -> String? {
    guard var token = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !token.isEmpty else {
        return nil
    }

    if token.count >= 2 {
        let first = token.first
        let last = token.last
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            token = String(token.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    return token
}

private func expandHome(_ path: String) -> String {
    guard path == "~" || path.hasPrefix("~/") else {
        return path
    }

    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path == "~" {
        return home
    }

    return home + String(path.dropFirst())
}

private func modificationDate(_ url: URL) -> Date {
    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
    return values?.contentModificationDate ?? .distantPast
}

private func compactTokenText(_ value: Double) -> String {
    if value >= 1_000_000 {
        return String(format: "%.1fM", value / 1_000_000)
    }

    if value >= 1_000 {
        return String(format: "%.1fK", value / 1_000)
    }

    return UsageFormatter.numberText(value)
}

private func providerErrorSnapshot(providerId: String, displayName: String, message: String) -> ProviderUsageSnapshot {
    ProviderUsageSnapshot(
        providerId: providerId,
        displayName: displayName,
        status: .error,
        fetchedAt: Date(),
        summary: nil,
        message: message,
        groups: [
            UsageGroup(
                id: providerId,
                title: displayName,
                subtitle: nil,
                items: [
                    UsageMetric(
                        id: "\(providerId)-error",
                        label: "状态",
                        kind: .quota,
                        usedPercent: nil,
                        remainingPercent: nil,
                        resetText: nil,
                        status: .error,
                        detail: message
                    )
                ]
            )
        ]
    )
}

func runProcess(
    executable: String,
    arguments: [String],
    environmentOverrides: [String: String] = [:],
    timeout: TimeInterval
) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if !environmentOverrides.isEmpty {
        var environment = ProcessInfo.processInfo.environment
        environmentOverrides.forEach { environment[$0] = $1 }
        process.environment = environment
    }

    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error

    try process.run()

    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
    }

    if process.isRunning {
        process.terminate()
        throw ProcessError.timedOut
    }

    let data = output.fileHandleForReading.readDataToEndOfFile()
    if process.terminationStatus != 0 {
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw ProcessError.failed(status: process.terminationStatus, message: errorText)
    }

    return data
}

private enum ProcessError: LocalizedError {
    case timedOut
    case failed(status: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .timedOut:
            return "命令超时"
        case let .failed(status, message):
            if message.isEmpty {
                return "命令退出 \(status)"
            }
            return "命令退出 \(status)：\(message)"
        }
    }
}

private enum CodexResetCreditsError: LocalizedError {
    case missingAccessToken
    case unauthorized
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .missingAccessToken:
            return "Codex auth.json 中没有 access_token"
        case .unauthorized:
            return "Codex 凭证失效或 Authorization header 无效"
        case let .httpStatus(status):
            return "Codex 重置卡接口返回 \(status)"
        }
    }
}

private func clampPercent(_ value: Double) -> Double {
    max(0, min(100, value))
}

private func readableIdentifier(_ value: String) -> String {
    value
        .split(separator: "_")
        .map { part in
            part.prefix(1).uppercased() + part.dropFirst()
        }
        .joined(separator: " ")
}

private func resetText(fromEpochSeconds value: Double?) -> String? {
    date(fromEpochSeconds: value).map(countdownText)
}

private func resetText(fromEpochMilliseconds value: Double?) -> String? {
    date(fromEpochMilliseconds: value).map(countdownText)
}

private func resetText(fromIsoString value: String?) -> String? {
    date(fromIsoString: value).map(countdownText)
}

private func date(fromEpochSeconds value: Double?) -> Date? {
    guard let value else {
        return nil
    }

    return Date(timeIntervalSince1970: value)
}

private func date(fromEpochMilliseconds value: Double?) -> Date? {
    guard let value else {
        return nil
    }

    return Date(timeIntervalSince1970: value / 1000)
}

private func date(fromIsoString value: String?) -> Date? {
    guard let value else {
        return nil
    }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}

private func codexResetCreditDate(_ value: Any?) -> Date? {
    if let string = value as? String {
        if let number = Double(string) {
            return number > 10_000_000_000 ? date(fromEpochMilliseconds: number) : date(fromEpochSeconds: number)
        }
        return date(fromIsoString: string)
    }

    if let number = TokenMeterCoreNumber.number(from: value) {
        return number > 10_000_000_000 ? date(fromEpochMilliseconds: number) : date(fromEpochSeconds: number)
    }

    return nil
}

private func countdownText(until date: Date) -> String {
    let seconds = max(0, Int(date.timeIntervalSinceNow))
    if seconds >= 86_400 {
        return "\(seconds / 86_400)d\((seconds % 86_400) / 3600)h"
    }
    if seconds >= 3_600 {
        return "\(seconds / 3600)h\((seconds % 3600) / 60)m"
    }
    return "\(seconds / 60)m"
}

private func usageDetail(from dictionary: [String: Any]) -> String? {
    let used = TokenMeterCoreNumber.number(from: dictionary["currentValue"])
    let total = TokenMeterCoreNumber.number(from: dictionary["usage"])
    let remaining = TokenMeterCoreNumber.number(from: dictionary["remaining"])

    if let used, let total {
        return "\(UsageFormatter.numberText(used))/\(UsageFormatter.numberText(total)) 次"
    }

    if let remaining {
        return "剩余 \(UsageFormatter.numberText(remaining)) 次"
    }

    return nil
}

private enum TokenMeterCoreNumber {
    static func number(from value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }

        if let string = value as? String {
            return Double(string)
        }

        return nil
    }
}
