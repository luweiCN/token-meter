import Darwin
import Foundation
import TokenMeterCore

struct DesktopAccountFeed {
    let home: URL
    var executable = TokenMeterPaths.cliExecutableURL
    private var directory: URL { TokenMeterPaths.baseDirectory(homeDirectory: home) }

    var snapshotURL: URL { TokenMeterPaths.accountSnapshotsURL(homeDirectory: home) }

    func resetStatusMessage() -> String {
        struct Status: Decodable { let message: String }
        let file = directory.appendingPathComponent("node/codex-reset-status.json")
        return (try? JSONDecoder().decode(Status.self, from: Data(contentsOf: file)))?.message ?? "自动使用暂不可用"
    }

    func refresh(_ providerID: String?) async throws {
        guard let executable else { throw AccountRefreshProcess.Failure.unavailable }
        let task = AccountRefreshProcess()
        let arguments = ["--home", home.path,
                         "--state", directory.appendingPathComponent("node").path, "quota-refresh"] + [providerID].compactMap { $0 }
        do {
            try await withTaskCancellationHandler {
                try await task.run(executable: executable, arguments: arguments)
            } onCancel: {
                task.cancel()
            }
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }
}

private final class AccountRefreshProcess: @unchecked Sendable {
    enum Failure: LocalizedError {
        case unavailable, refreshFailed
        var errorDescription: String? {
            switch self {
            case .unavailable: return "无法启动 TokenMeter 命令行程序，请检查应用安装。"
            case .refreshFailed: return "TokenMeter 命令行未能完成额度刷新。"
            }
        }
    }

    private let lock = NSLock()
    private let child = Process()
    private var cancelled = false

    func run(executable: URL, arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                self.lock.lock()
                defer { self.lock.unlock() }
                guard !self.cancelled else { result.resume(throwing: CancellationError()); return }
                let child = self.child
                child.executableURL = executable
                child.arguments = arguments
                child.standardInput = FileHandle.nullDevice
                child.standardOutput = FileHandle.nullDevice
                child.standardError = FileHandle.nullDevice
                child.terminationHandler = { process in
                    if process.terminationReason == .exit, process.terminationStatus == 0 {
                        result.resume()
                    } else {
                        result.resume(throwing: Failure.refreshFailed)
                    }
                }
                do { try child.run() } catch {
                    child.terminationHandler = nil
                    result.resume(throwing: Failure.unavailable)
                }
            }
        }
        try Task.checkCancellation()
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if child.isRunning { child.terminate() }
    }
}

/// The CLI atomically replaces the file. Watching its parent also follows replacements.
@MainActor
final class SnapshotWatcher {
    private let directory: URL
    private let onChange: @MainActor () -> Void
    private var watchedDirectory: URL?
    private var source: DispatchSourceFileSystemObject?
    private var pending: Task<Void, Never>?

    init(file: URL, onChange: @escaping @MainActor () -> Void) {
        directory = file.deletingLastPathComponent().standardizedFileURL
        self.onChange = onChange
        watchExistingDirectory()
    }

    deinit {
        pending?.cancel()
        source?.cancel()
    }

    private func watchExistingDirectory() {
        // On first run the daemon may still be creating its cache directory.
        var target = directory
        while !FileManager.default.fileExists(atPath: target.path) && target.path != "/" {
            target.deleteLastPathComponent()
        }
        guard watchedDirectory != target else { return }
        source?.cancel()
        source = nil
        watchedDirectory = nil
        let descriptor = open(target.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor != -1 else { return }
        let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .revoke], queue: .main)
        watch.setCancelHandler { close(descriptor) }
        watch.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let event = self.source?.data else { return }
                if !event.isDisjoint(with: [.delete, .rename, .revoke]) {
                    self.watchedDirectory = nil
                }
                self.watchExistingDirectory()
                self.pending?.cancel()
                self.pending = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                    self?.onChange()
                }
            }
        }
        source = watch
        watchedDirectory = target
        watch.resume()
    }
}
