import Darwin
import Foundation

package enum AntigravityQueryError: LocalizedError, Equatable {
    case missingCLI, signIn, authNetwork, location, ineligible, timeout, unavailable

    package var errorDescription: String? {
        switch self {
        case .missingCLI: return "找不到 Antigravity CLI（agy）。"
        case .signIn: return "请在终端打开 agy，完成 Google 账号登录。"
        case .authNetwork: return "暂时无法连接 Google 续期登录，稍后会自动重试。"
        case .location: return "Google 提示当前地区不支持 Antigravity。"
        case .ineligible: return "Google 提示当前账号暂不具备 Antigravity 使用资格。"
        case .timeout: return "Google 额度查询超时，稍后会自动重试。"
        case .unavailable: return "暂时无法读取 AGY 额度，稍后会自动重试。"
        }
    }

    static func failure(_ message: String, diagnostic: String = "", timedOut: Bool = false) -> Self {
        let text = message.lowercased()
        let log = diagnostic.lowercased()
        if text.contains("invalid_grant") || log.contains("invalid_grant") { return .signIn }
        let networkFailure = "token refresh failed due to network error"
        if text.contains(networkFailure) || log.contains(networkFailure) { return .authNetwork }
        if text.contains("not currently available in your location") || log.contains("not currently available in your location") { return .location }
        if text.contains("not eligible") || log.contains("account ineligible:") { return .ineligible }
        if ["not authenticated", "sign in", "log in", "not logged in", "authentication required"].contains(where: text.contains)
            || log.contains("print mode: triggering interactive oauth") { return .signIn }
        return timedOut ? .timeout : .unavailable
    }
}

extension AntigravityUsageProvider {
    package static func cliURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        let directories = AgentBinaryDetector.searchDirectories(homeDirectory: home.path)
        guard let path = AgentBinaryDetector.firstExecutable(named: "agy", in: directories) else {
            throw AntigravityQueryError.missingCLI
        }
        return URL(fileURLWithPath: path)
    }

    package func refreshQuota() async throws {
        let worker = Task.detached(priority: .utility) {
            let home = FileManager.default.homeDirectoryForCurrentUser
            guard FileManager.default.fileExists(atPath: AntigravityQuota.connectionURL(for: cache).path) else {
                throw CancellationError()
            }
            // The installer itself creates settings.json. Only a quota observation or completed
            // CLI onboarding is evidence that a background process can use an existing login.
            let previous = try? AntigravityQuota.read(cache)
            guard previous?.buckets.isEmpty == false || Self.hasCompletedOnboarding(home: home) else {
                throw AntigravityQueryError.signIn
            }
            let cli = try Self.cliURL(home: home)
            let started = Date()
            let report = try Self.backgroundQuota(cli: cli, home: home)
            try Task.checkCancellation()
            try report.save(at: cache, supersededAfter: started, coalesce: false)
        }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    static func backgroundQuota(cli: URL, home: URL, timeout: TimeInterval = 18) throws -> AntigravityQuota {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: directory) }
        let log = directory.appendingPathComponent("agy.log")
        let output = directory.appendingPathComponent("quota.json")
        let quoted = "'" + output.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        // The official status line reports account quota independently of model eligibility.
        // Extract only that field before writing. A new directory excludes previous observations.
        let command = "/usr/bin/plutil -extract quota json -o \(quoted).tmp -- - && /bin/mv -f \(quoted).tmp \(quoted)"
        let settings = try JSONSerialization.data(withJSONObject: ["statusLine": [
            "type": "command", "command": command, "stack_with_default": false
        ]])
        let profile = #"(version 1)(allow default)(deny lsopen)(deny process-exec (literal "/usr/bin/open"))"#
        let arguments = ["/usr/bin/sandbox-exec", "-p", profile, "/usr/bin/env", "TERM=xterm-256color", cli.path,
                         "--log-file", log.path, "--settings", String(decoding: settings, as: UTF8.self)]
        let (pid, terminal) = try startQuotaProcess(arguments: arguments, home: home)
        var exited = false
        defer {
            close(terminal)
            if !exited {
                // The CLI and its brief status-line commands are in our own session.
                kill(-pid, SIGTERM)
                for _ in 0..<10 {
                    let status = waitpid(pid, nil, WNOHANG)
                    if status == pid || (status < 0 && errno == ECHILD) { exited = true; break }
                    usleep(20_000)
                }
                if !exited {
                    kill(-pid, SIGKILL)
                    while waitpid(pid, nil, 0) < 0 && errno == EINTR {}
                }
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var discard = [UInt8](repeating: 0, count: 8192)
        var readiness = pollfd(fd: terminal, events: Int16(POLLIN), revents: 0)
        while true {
            try Task.checkCancellation()
            let status = waitpid(pid, nil, WNOHANG)
            exited = status == pid || (status < 0 && errno == ECHILD)
            if let data = try? Data(contentsOf: output), data.count <= 512 * 1024,
               let observation = try? AntigravityQuota.parseStatusBuckets(data, now: Date()), !observation.buckets.isEmpty {
                return observation
            }
            if exited || ProcessInfo.processInfo.systemUptime >= deadline { break }
            if poll(&readiness, 1, 80) > 0 {
                if readiness.revents & Int16(POLLIN) != 0 { _ = read(terminal, &discard, discard.count) }
                else { usleep(80_000) }
            }
        }
        let logFile = try? FileHandle(forReadingFrom: log)
        defer { try? logFile?.close() }
        let diagnostic = (try? logFile?.read(upToCount: 128 * 1024)) ?? Data()
        throw AntigravityQueryError.failure("", diagnostic: String(decoding: diagnostic, as: UTF8.self), timedOut: !exited)
    }

    // agy requires a controlling TTY to publish its status line. No window, prompt or screen parsing is involved.
    private static func startQuotaProcess(arguments: [String], home: URL) throws -> (pid_t, Int32) {
        func check(_ result: Int32) throws {
            if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        }
        var master: Int32 = -1, slave: Int32 = -1
        var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw POSIXError(.EIO) }
        defer { close(slave) }
        do {
            var tty = [CChar](repeating: 0, count: Int(PATH_MAX))
            try check(ttyname_r(slave, &tty, tty.count))
            var attributes: posix_spawnattr_t?, actions: posix_spawn_file_actions_t?
            try check(posix_spawnattr_init(&attributes))
            defer { posix_spawnattr_destroy(&attributes) }
            try check(posix_spawn_file_actions_init(&actions))
            defer { posix_spawn_file_actions_destroy(&actions) }
            try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)))
            try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, tty, O_RDWR, 0))
            try check(posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDOUT_FILENO))
            try check(posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDERR_FILENO))
            if #available(macOS 26.0, *) {
                try check(posix_spawn_file_actions_addchdir(&actions, home.path))
            } else {
                try check(posix_spawn_file_actions_addchdir_np(&actions, home.path))
            }
            var argv = arguments.map { strdup($0) } + [nil]
            defer { argv.forEach { free($0) } }
            guard argv.dropLast().allSatisfy({ $0 != nil }) else { throw POSIXError(.ENOMEM) }
            var pid: pid_t = 0
            try check(posix_spawn(&pid, arguments[0], &actions, &attributes, &argv, environ))
            return (pid, master)
        } catch {
            close(master)
            throw error
        }
    }

    private static func hasCompletedOnboarding(home: URL) -> Bool {
        struct Onboarding: Decodable { let onboardingComplete: Bool }
        let url = home.appendingPathComponent(".gemini/antigravity-cli/cache/onboarding.json")
        guard let data = try? Data(contentsOf: url) else { return false }
        return (try? JSONDecoder().decode(Onboarding.self, from: data).onboardingComplete) == true
    }
}
