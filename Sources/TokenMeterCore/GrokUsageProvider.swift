import Foundation

enum GrokAuth {
    static func isUsable(authURL: URL, now: Date) -> Bool {
        guard let data = try? Data(contentsOf: authURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !object.isEmpty else { return false }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        for value in object.values {
            guard let entry = value as? [String: Any] else { continue }
            guard let raw = entry["expires_at"] as? String else { return true }
            let expiry = fractional.date(from: raw) ?? plain.date(from: raw)
            if expiry == nil { return true }
            if let expiry, expiry > now { return true }
        }
        return false
    }
}

public struct GrokUsageProvider: UsageProvider {
    public let id: String
    public let displayName: String
    private let grokHome: URL
    private let grokExecutable: () -> String?
    private let now: () -> Date
    private let fetchBilling: () async throws -> Data

    public init(config: ProviderConfig) {
        let home = GrokPaths.sessionsRoot().deletingLastPathComponent()
        self.init(
            config: config,
            grokHome: home,
            grokExecutable: { GrokUsageProvider.locateGrokExecutable(grokHome: home) }
        )
    }

    init(
        config: ProviderConfig,
        grokHome: URL,
        grokExecutable: @escaping () -> String?,
        now: @escaping () -> Date = Date.init,
        fetchBilling: (() async throws -> Data)? = nil
    ) {
        self.id = config.id
        self.displayName = config.displayName
        self.grokHome = grokHome
        self.grokExecutable = grokExecutable
        self.now = now
        let executable = grokExecutable
        let home = grokHome
        self.fetchBilling = fetchBilling ?? {
            try GrokUsageProvider.spawnBilling(executable: executable(), grokHome: home)
        }
    }

    public func fetchUsage() async -> UsageSnapshot {
        await fetchProviderUsage().legacySnapshot
    }

    public func fetchProviderUsage() async -> ProviderUsageSnapshot {
        guard grokExecutable() != nil else {
            return providerErrorSnapshot(
                providerId: id,
                displayName: displayName,
                message: "未检测到 Grok 命令行"
            )
        }

        let authURL = grokHome.appendingPathComponent("auth.json")
        guard GrokAuth.isUsable(authURL: authURL, now: now()) else {
            return providerErrorSnapshot(
                providerId: id,
                displayName: displayName,
                message: "未登录 Grok Build，请运行 grok login"
            )
        }

        do {
            let data = try await fetchBilling()
            return try GrokBillingParser.parse(
                data: data,
                providerId: id,
                displayName: displayName
            )
        } catch {
            return providerErrorSnapshot(
                providerId: id,
                displayName: displayName,
                message: Self.userFacingMessage(
                    ProviderErrorMessage.sanitized(providerName: "Grok Build", errorMessage: error.localizedDescription)
                )
            )
        }
    }

    static func locateGrokExecutable(
        grokHome: URL,
        homeDirectory: String = NSHomeDirectory()
    ) -> String? {
        var directories = [
            grokHome.appendingPathComponent("bin").path,
            "\(homeDirectory)/.grok/bin"
        ]
        directories += CodexUsageProvider.searchDirectories(homeDirectory: homeDirectory)
        var seen = Set<String>()
        for directory in directories where seen.insert(directory).inserted {
            let candidate = (directory as NSString).appendingPathComponent("grok")
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    static func spawnBilling(executable: String?, grokHome: URL) throws -> Data {
        guard let executable else {
            throw GrokSpawnError.missingBinary
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["agent", "--no-leader", "stdio"]
        process.environment = {
            var environment = ProcessInfo.processInfo.environment
            environment["GROK_HOME"] = grokHome.path
            return environment
        }()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1","clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false}}}}"#
        let billing = #"{"jsonrpc":"2.0","id":2,"method":"x.ai/billing","params":{}}"#
        stdin.fileHandleForWriting.write(Data((initialize + "\n" + billing + "\n").utf8))
        try? stdin.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(10)
        var buffer = Data()
        while process.isRunning && Date() < deadline {
            let available = stdout.fileHandleForReading.availableData
            if !available.isEmpty {
                buffer.append(available)
                if let payload = rpcResult(id: 2, in: buffer) {
                    process.terminate()
                    process.waitUntilExit()
                    return payload
                }
            } else {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        if process.isRunning {
            process.terminate()
            throw GrokSpawnError.timedOut
        }
        buffer.append(stdout.fileHandleForReading.readDataToEndOfFile())
        if let payload = rpcResult(id: 2, in: buffer) {
            return payload
        }
        throw GrokSpawnError.noResult
    }

    private static func rpcResult(id: Int, in buffer: Data) -> Data? {
        guard let text = String(data: buffer, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  JSONDictionary.int64(object, "id") == Int64(id) else { continue }
            if object["error"] != nil {
                return nil
            }
            if let result = object["result"] {
                return try? JSONSerialization.data(withJSONObject: result)
            }
        }
        return nil
    }

    private static func userFacingMessage(_ message: String) -> String {
        let lowercased = message.lowercased()
        if lowercased.contains("weekly limit")
            || lowercased.contains("credits")
            || lowercased.contains("402") {
            return "额度用尽"
        }
        return message
    }
}

private enum GrokSpawnError: LocalizedError {
    case missingBinary
    case timedOut
    case noResult

    var errorDescription: String? {
        switch self {
        case .missingBinary: return "未检测到 Grok 命令行"
        case .timedOut: return "命令超时"
        case .noResult: return "Grok 响应中没有可用的额度字段"
        }
    }
}
