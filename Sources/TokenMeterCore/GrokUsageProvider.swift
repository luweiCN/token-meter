import Foundation

enum GrokAuth {
    static let loginHelp = "未登录 Grok Build。请在终端运行 grok login，完成后点重试或等待下次自动刷新。"

    static func isUsable(authURL: URL, now: Date) -> Bool {
        bearerToken(authURL: authURL, now: now) != nil
    }

    /// Grok CLI 能用 refresh_token 在无 UI、无既有 Grok 进程时续期 access token。
    /// TokenMeter 只判断是否值得启动 CLI，不读取或自行发送 refresh token。
    static func canAuthenticateWithCLI(authURL: URL, now: Date) -> Bool {
        let entries = preferredEntries(authURL: authURL)
        return usableEntry(in: entries, now: now) != nil
            || entries.contains { nonEmptyString($0["refresh_token"]) != nil }
    }

    static func bearerToken(authURL: URL, now: Date) -> String? {
        usableEntry(authURL: authURL, now: now).flatMap { entry in
            nonEmptyString(entry["key"])
        }
    }

    static func userId(authURL: URL, now: Date) -> String? {
        usableEntry(authURL: authURL, now: now).flatMap { entry in
            nonEmptyString(entry["user_id"])
        }
    }

    private static func usableEntry(authURL: URL, now: Date) -> [String: Any]? {
        usableEntry(in: preferredEntries(authURL: authURL), now: now)
    }

    private static func usableEntry(in entries: [[String: Any]], now: Date) -> [String: Any]? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        for entry in entries {
            guard let raw = entry["expires_at"] as? String else { return entry }
            let expiry = fractional.date(from: raw) ?? plain.date(from: raw)
            if expiry == nil { return entry }
            if let expiry, expiry > now { return entry }
        }
        return nil
    }

    private static func preferredEntries(authURL: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: authURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !object.isEmpty else { return [] }
        let preferred = object.keys.sorted { lhs, rhs in
            lhs.contains("auth.x.ai") && !rhs.contains("auth.x.ai")
        }
        return preferred.compactMap { object[$0] as? [String: Any] }
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}

public struct GrokUsageProvider: UsageProvider {
    public let id: String
    public let displayName: String
    private let grokHome: URL
    private let grokExecutable: () -> String?
    private let now: () -> Date
    private let fetchBilling: () async throws -> Data
    private let fetchREST: (String) async throws -> Data
    private let fetchGRPC: (String) async throws -> Data

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
        fetchBilling: (() async throws -> Data)? = nil,
        fetchREST: ((String) async throws -> Data)? = nil,
        fetchGRPC: ((String) async throws -> Data)? = nil
    ) {
        self.id = config.id
        self.displayName = config.displayName
        self.grokHome = grokHome
        self.grokExecutable = grokExecutable
        self.now = now
        let executable = grokExecutable
        let home = grokHome
        self.fetchBilling = fetchBilling ?? {
            try await Task.detached {
                try GrokUsageProvider.spawnBilling(executable: executable(), grokHome: home)
            }.value
        }
        self.fetchREST = fetchREST ?? { token in
            try await Task.detached {
                try GrokUsageProvider.fetchCreditsREST(token: token, grokHome: home)
            }.value
        }
        self.fetchGRPC = fetchGRPC ?? { token in
            try await Task.detached {
                let raw = try GrokUsageProvider.fetchCreditsGRPC(token: token)
                return try GrokCreditsGrpcParser.parse(data: raw)
            }.value
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
        guard GrokAuth.canAuthenticateWithCLI(authURL: authURL, now: now()) else {
            return loginErrorSnapshot()
        }

        do {
            let data = try await fetchBilling()
            return try GrokBillingParser.parse(
                data: data,
                providerId: id,
                displayName: displayName
            )
        } catch {
            if Self.shouldFallback(error), let token = GrokAuth.bearerToken(authURL: authURL, now: now()) {
                if let snapshot = await httpSnapshot(token: token) {
                    return snapshot
                }
            }
            return errorSnapshot(error)
        }
    }

    private func loginErrorSnapshot() -> ProviderUsageSnapshot {
        providerErrorSnapshot(
            providerId: id,
            displayName: displayName,
            message: GrokAuth.loginHelp
        )
    }

    private func errorSnapshot(_ error: Error) -> ProviderUsageSnapshot {
        if Self.isUnauthorized(error) {
            return loginErrorSnapshot()
        }
        return providerErrorSnapshot(
            providerId: id,
            displayName: displayName,
            message: Self.userFacingMessage(
                ProviderErrorMessage.sanitized(providerName: "Grok Build", errorMessage: error.localizedDescription)
            )
        )
    }

    private func httpSnapshot(token: String) async -> ProviderUsageSnapshot? {
        do {
            let data = try await fetchREST(token)
            return try GrokBillingParser.parse(data: data, providerId: id, displayName: displayName)
        } catch {
            if Self.isUnauthorized(error) {
                return loginErrorSnapshot()
            }
        }
        do {
            let data = try await fetchGRPC(token)
            return try GrokBillingParser.parse(data: data, providerId: id, displayName: displayName)
        } catch {
            if Self.isUnauthorized(error) {
                return loginErrorSnapshot()
            }
            return nil
        }
    }

    private static func shouldFallback(_ error: Error) -> Bool {
        if let spawn = error as? GrokSpawnError {
            switch spawn {
            case .timedOut, .noResult: return true
            case .rpc(let message):
                return message.lowercased().contains("method not found")
            case .missingBinary, .unauthorized, .httpStatus:
                return false
            }
        }
        return error.localizedDescription.lowercased().contains("method not found")
    }

    private static func isUnauthorized(_ error: Error) -> Bool {
        if let spawn = error as? GrokSpawnError {
            switch spawn {
            case .unauthorized: return true
            case .httpStatus(let code): return code == 401 || code == 403
            default: return false
            }
        }
        let text = error.localizedDescription.lowercased()
        return text.contains("unauthorized") || text.contains("401") || text.contains("403")
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

    static func spawnBilling(executable: String?, grokHome: URL, timeout: TimeInterval = 10) throws -> Data {
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
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        let session = RPCSession(stdout: stdout, timeout: timeout)
        try send(stdin, id: 1, method: "initialize", params: #"{"protocolVersion":"1","clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false}}}"#)
        _ = try session.wait(id: 1)
        try send(stdin, id: 2, method: "authenticate", params: #"{"methodId":"cached_token"}"#)
        _ = try? session.wait(id: 2)

        let billingCalls: [(Int, String)] = [(3, "_x.ai/billing"), (4, "x.ai/billing")]
        for (id, method) in billingCalls {
            try send(stdin, id: id, method: method, params: "{}")
            do {
                let payload = try session.wait(id: id)
                try? stdin.fileHandleForWriting.close()
                return payload
            } catch GrokSpawnError.rpc(let message) where message.lowercased().contains("method not found") {
                continue
            }
        }
        try? stdin.fileHandleForWriting.close()
        throw GrokSpawnError.rpc("Method not found")
    }

    private static func send(_ stdin: Pipe, id: Int, method: String, params: String) throws {
        let line = "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"\(method)\",\"params\":\(params)}\n"
        stdin.fileHandleForWriting.write(Data(line.utf8))
    }

    static func fetchCreditsREST(token: String, grokHome: URL, urlSession: URLSession = .shared) throws -> Data {
        let authURL = grokHome.appendingPathComponent("auth.json")
        var request = URLRequest(url: URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!)
        request.httpMethod = "GET"
        applyGrokHeaders(&request, token: token, userId: GrokAuth.userId(authURL: authURL, now: Date()))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try sendHTTP(request, urlSession: urlSession)
    }

    static func fetchCreditsGRPC(token: String, urlSession: URLSession = .shared) throws -> Data {
        var request = URLRequest(url: URL(string: "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig")!)
        request.httpMethod = "POST"
        applyGrokHeaders(&request, token: token, userId: nil)
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Accept")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Grpc-Web")
        request.httpBody = Data([0, 0, 0, 0, 0])
        return try sendHTTP(request, urlSession: urlSession)
    }

    private static func applyGrokHeaders(_ request: inout URLRequest, token: String, userId: String?) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue("Grok Build", forHTTPHeaderField: "User-Agent")
        if let userId {
            request.setValue(userId, forHTTPHeaderField: "x-userid")
        }
    }

    private static func sendHTTP(_ request: URLRequest, urlSession: URLSession) throws -> Data {
        let box = HTTPBox()
        let semaphore = DispatchSemaphore(value: 0)
        urlSession.dataTask(with: request) { data, response, error in
            box.error = error
            box.data = data
            box.response = response
            semaphore.signal()
        }.resume()
        if semaphore.wait(timeout: .now() + 10) == .timedOut {
            throw GrokSpawnError.timedOut
        }
        if let error = box.error {
            throw error
        }
        if let http = box.response as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw GrokSpawnError.unauthorized
            }
            if !(200..<300).contains(http.statusCode) {
                throw GrokSpawnError.httpStatus(http.statusCode)
            }
        }
        guard let data = box.data, !data.isEmpty else {
            throw GrokSpawnError.noResult
        }
        return data
    }

    private static func userFacingMessage(_ message: String) -> String {
        let lowercased = message.lowercased()
        if lowercased.contains("weekly limit") || lowercased.contains("402") {
            return "额度用尽"
        }
        return message
    }
}

enum GrokSpawnError: LocalizedError {
    case missingBinary
    case timedOut
    case noResult
    case rpc(String)
    case unauthorized
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .missingBinary: return "未检测到 Grok 命令行"
        case .timedOut: return "命令超时"
        case .noResult: return "Grok 响应中没有可用的额度字段"
        case let .rpc(message): return message
        case .unauthorized: return GrokAuth.loginHelp
        case let .httpStatus(code): return "Grok 接口返回 \(code)"
        }
    }
}

private final class HTTPBox: @unchecked Sendable {
    var data: Data?
    var response: URLResponse?
    var error: Error?
}

private final class RPCSession {
    private let lock = NSLock()
    private var buffer = Data()
    private var objects: [[String: Any]] = []
    private let deadline: DispatchTime
    private let signal = DispatchSemaphore(value: 0)

    init(stdout: Pipe, timeout: TimeInterval) {
        deadline = .now() + timeout
        let handle = stdout.fileHandleForReading
        handle.readabilityHandler = { [weak self] fileHandle in
            guard let self else { return }
            let chunk = fileHandle.availableData
            self.lock.lock()
            if chunk.isEmpty {
                fileHandle.readabilityHandler = nil
                self.lock.unlock()
                self.signal.signal()
                return
            }
            self.buffer.append(chunk)
            self.drainLines()
            self.lock.unlock()
            self.signal.signal()
        }
    }

    func wait(id: Int) throws -> Data {
        while true {
            lock.lock()
            if let object = objects.first(where: { JSONDictionary.int64($0, "id") == Int64(id) }) {
                lock.unlock()
                if object["error"] != nil {
                    throw GrokSpawnError.rpc(Self.errorMessage(object))
                }
                guard let result = object["result"],
                      JSONSerialization.isValidJSONObject(result),
                      let data = try? JSONSerialization.data(withJSONObject: result) else {
                    throw GrokSpawnError.noResult
                }
                return data
            }
            lock.unlock()
            if signal.wait(timeout: deadline) == .timedOut {
                throw GrokSpawnError.timedOut
            }
        }
    }

    private func drainLines() {
        guard let text = String(data: buffer, encoding: .utf8) else { return }
        var consumed = 0
        var search = text.startIndex
        while let newline = text.range(of: "\n", range: search..<text.endIndex) {
            let line = text[search..<newline.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = line.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                objects.append(object)
            }
            search = newline.upperBound
            consumed = text.distance(from: text.startIndex, to: search)
        }
        if consumed > 0 {
            buffer = Data(text.utf8.dropFirst(consumed))
        }
    }

    private static func errorMessage(_ object: [String: Any]) -> String {
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty {
            return message
        }
        return "Grok RPC error"
    }
}
