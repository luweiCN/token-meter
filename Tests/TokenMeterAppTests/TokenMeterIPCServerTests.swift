import Darwin
import Foundation
import Network
import XCTest
@testable import TokenMeterApp
@testable import TokenMeterCore

@MainActor
final class TokenMeterIPCServerTests: XCTestCase {
    func testPingRespondsWithOkStatusOverOneJsonLine() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let server = try await startServer(store: fixture.store)
        defer { server.stop() }

        let response = try await sendJSONLine(
            #"{"id":"ping-1","method":"ping"}"#,
            to: try XCTUnwrap(server.boundPort)
        )

        XCTAssertEqual(response.id, "ping-1")
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?["status"], "ok")
        XCTAssertNil(response.error)
    }

    func testUnknownMethodReturnsStructuredErrorAndServerContinues() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let server = try await startServer(store: fixture.store)
        defer { server.stop() }

        let unknown = try await sendJSONLine(
            #"{"id":"bad-1","method":"doesNotExist"}"#,
            to: try XCTUnwrap(server.boundPort)
        )

        XCTAssertEqual(unknown.id, "bad-1")
        XCTAssertFalse(unknown.ok)
        XCTAssertNil(unknown.result)
        XCTAssertEqual(unknown.error, "unknown method")

        let ping = try await sendJSONLine(
            #"{"id":"ping-after-error","method":"ping"}"#,
            to: try XCTUnwrap(server.boundPort)
        )
        XCTAssertTrue(ping.ok, "unknown-method requests must not crash or poison the listener")
        XCTAssertEqual(ping.result?["status"], "ok")
    }

    func testSettingsChangedReloadsProviderStoreSettingsFromSQLite() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let server = try await startServer(store: fixture.store)
        defer { server.stop() }

        let current = try XCTUnwrap(fixture.store.settingsSnapshot)
        XCTAssertNotEqual(current.autoRefreshSeconds, 60)
        let settingsStore = SettingsStore(database: try SQLiteDatabase(path: fixture.databaseURL.path))
        _ = try settingsStore.apply(
            SettingsPatch(autoRefreshSeconds: 60),
            expectedVersion: current.version,
            updatedBy: .electron
        )

        let response = try await sendJSONLine(
            #"{"id":"settings-1","method":"settingsChanged","params":{"version":"2"}}"#,
            to: try XCTUnwrap(server.boundPort)
        )

        XCTAssertEqual(response.id, "settings-1")
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?["status"], "settingsApplied")
        XCTAssertNil(response.error)
        XCTAssertEqual(
            fixture.store.settingsSnapshot?.autoRefreshSeconds,
            60,
            "settingsChanged must reload the same ProviderStore instance from the shared SQLite database"
        )
    }

    private func startServer(store: ProviderStore) async throws -> TokenMeterIPCServer {
        let server = TokenMeterIPCServer(store: store)
        try server.start(port: 0)
        let deadline = Date().addingTimeInterval(2)
        while server.boundPort == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        _ = try XCTUnwrap(server.boundPort, "server should expose the dynamic TCP port it bound")
        return server
    }

    private func makeFixture() throws -> IPCServerFixture {
        let homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
        let databaseURL = homeDirectory
            .appendingPathComponent("database", isDirectory: true)
            .appendingPathComponent("tokenmeter.sqlite")
        let store = ProviderStore(
            config: TokenMeterConfig(menuBar: MenuBarConfig(primaryProviderId: nil), providers: []),
            notificationCenter: nil,
            databaseURL: databaseURL
        )
        return IPCServerFixture(homeDirectory: homeDirectory, databaseURL: databaseURL, store: store)
    }

    private func sendJSONLine(_ line: String, to port: UInt16) async throws -> IPCResponse {
        let data = try await TCPLineClient(port: port).send(line + "\n")
        XCTAssertEqual(data.last, UInt8(ascii: "\n"), "IPC responses must be newline-terminated JSON lines")
        return try JSONDecoder().decode(IPCResponse.self, from: data.dropLast())
    }
}

@MainActor
private struct IPCServerFixture {
    let homeDirectory: URL
    let databaseURL: URL
    let store: ProviderStore

    func cleanup() {
        try? FileManager.default.removeItem(at: homeDirectory)
    }
}

private struct TCPLineClient {
    let port: UInt16

    func send(_ text: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try sendSynchronously(text))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func sendSynchronously(_ text: String) throws -> Data {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TCPLineClientError.socketFailed(errno) }
        defer { close(fd) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else { throw TCPLineClientError.connectFailed(errno) }

        let request = Array(text.utf8)
        try request.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let result = Darwin.send(fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent, 0)
                guard result > 0 else { throw TCPLineClientError.sendFailed(errno) }
                sent += result
            }
        }

        var response = Data()
        var byte = UInt8(0)
        while true {
            let received = Darwin.recv(fd, &byte, 1, 0)
            guard received > 0 else { throw TCPLineClientError.closedBeforeNewline }
            response.append(byte)
            if byte == UInt8(ascii: "\n") {
                return response
            }
            guard response.count <= 64 * 1024 else { throw TCPLineClientError.responseTooLarge }
        }
    }
}

private enum TCPLineClientError: Error, CustomStringConvertible {
    case socketFailed(Int32)
    case connectFailed(Int32)
    case sendFailed(Int32)
    case closedBeforeNewline
    case responseTooLarge

    var description: String {
        switch self {
        case .socketFailed(let code):
            return "socket failed: \(String(cString: strerror(code)))"
        case .connectFailed(let code):
            return "connect failed: \(String(cString: strerror(code)))"
        case .sendFailed(let code):
            return "send failed: \(String(cString: strerror(code)))"
        case .closedBeforeNewline:
            return "connection closed before newline-terminated JSON response"
        case .responseTooLarge:
            return "response exceeded 64 KiB without a newline"
        }
    }
}
