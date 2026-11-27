import Darwin
import Foundation

/// The CLI may write a model catalogue larger than a pipe buffer. An anonymous
/// file also lets the caller enforce its timeout if a grandchild inherits stdout.
func executableOutput(_ url: URL, arguments: [String], timeout: TimeInterval) throws -> Data {
    guard let buffer = tmpfile() else { throw POSIXError(.EIO) }
    defer { fclose(buffer) }
    let output = FileHandle(fileDescriptor: fileno(buffer), closeOnDealloc: false)
    let process = Process()
    process.executableURL = url
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }

    try Task.checkCancellation()
    try process.run()
    if exited.wait(timeout: .now() + timeout) == .timedOut {
        if process.isRunning { process.terminate() }
        if exited.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
        }
        throw POSIXError(.ETIMEDOUT)
    }
    guard process.terminationStatus == 0 else { throw POSIXError(.EIO) }
    let limit = 4 * 1024 * 1024
    try output.seek(toOffset: 0)
    let data = try output.read(upToCount: limit + 1) ?? Data()
    guard data.count <= limit else { throw CocoaError(.fileReadTooLarge) }
    return data
}
