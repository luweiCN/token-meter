import Foundation

@MainActor
public final class CodexAccountClient: CodexAccountServicing {
    private let home: URL
    private let searchPath: String

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"), searchPath: String? = nil) {
        self.home = home
        self.searchPath = searchPath ?? CodexUsageProvider.executableSearchPath()
    }

    public func read() async throws -> CodexAccountState {
        try await CodexAccountState.parse(request(["operation": "read"]))
    }

    public func consume(creditID: String, idempotencyKey: String, accountFingerprint: String) async throws -> CodexResetOutcome {
        let data = try await request([
            "operation": "consume", "creditID": creditID, "idempotencyKey": idempotencyKey,
            "accountFingerprint": accountFingerprint,
            "maxRemainingSeconds": String(Int(CodexRedeemableCredit.autoRedeemLeadTime))
        ])
        struct Response: Decodable { let outcome: CodexResetOutcome?; let error: String? }
        let response = try JSONDecoder().decode(Response.self, from: data)
        switch response.error {
        case "unsupportedResetAPI": throw CodexAccountError.unsupportedResetAPI
        case "accountChanged": throw CodexAccountError.accountChanged
        case "creditNotEligible": throw CodexAccountError.creditNotEligible
        default:
            guard let outcome = response.outcome else { throw CodexAccountError.invalidResponse }
            return outcome
        }
    }

    private func request(_ payload: [String: String]) async throws -> Data {
        try Task.checkCancellation()
        guard let script = Bundle.module.url(forResource: "codex-account", withExtension: "cjs") else {
            throw CodexAccountError.requestFailed
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let input = try JSONSerialization.data(withJSONObject: payload.merging(["clientVersion": version]) { _, value in value })
        let control = CodexAccountProcess()
        let environment = ["PATH": searchPath, "CODEX_HOME": home.path]
        let worker = Task.detached {
            try control.run(script: script, environment: environment, input: input)
        }
        return try await withTaskCancellationHandler {
            let data = try await worker.value
            try Task.checkCancellation()
            return data
        } onCancel: {
            control.cancel()
        }
    }
}

// Cancellation must reach the child process while it is awaiting a read, so a
// disabled setting cannot leave a queued consumption request behind.
private final class CodexAccountProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var output = Data()

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }

    func run(script: URL, environment: [String: String], input: Data) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", script.path]
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, value in value }
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        self.process = process
        do { try process.run() } catch { lock.unlock(); throw CodexAccountError.requestFailed }
        lock.unlock()
        let read = DispatchGroup()
        read.enter()
        DispatchQueue.global().async {
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            self.lock.lock()
            self.output = data
            self.lock.unlock()
            read.leave()
        }
        defer {
            if process.isRunning { process.terminate() }
            try? stdin.fileHandleForWriting.close()
        }
        try stdin.fileHandleForWriting.write(contentsOf: input)
        try stdin.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { cancel(); throw CodexAccountError.timedOut }
        guard read.wait(timeout: .now() + 2) == .success else { throw CodexAccountError.timedOut }
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        guard process.terminationStatus == 0 else { throw CodexAccountError.requestFailed }
        return output
    }
}
