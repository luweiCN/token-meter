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

    func testServerRejectsNonLoopbackConnections() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let server = try await startServer(store: fixture.store)
        defer { server.stop() }

        let port = try XCTUnwrap(server.boundPort)
        let addresses = try activeNonLoopbackAddresses()
        guard !addresses.isEmpty else {
            throw XCTSkip("No active non-loopback IPv4 or IPv6 address is available on this machine")
        }

        let address = addresses[0]
        do {
            let response = try await sendJSONLine(
                #"{"id":"non-loopback-ping","method":"ping"}"#,
                to: port,
                host: address
            )
            if response.ok, response.result?["status"] == "ok" {
                XCTFail("non-loopback ping unexpectedly succeeded via \(address):\(port); IPC server must only accept loopback control-plane connections")
            }
        } catch {
            return
        }
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

    private func sendJSONLine(_ line: String, to port: UInt16, host: TCPHost = .loopback) async throws -> IPCResponse {
        let data = try await TCPLineClient(host: host, port: port).send(line + "\n")
        XCTAssertEqual(data.last, UInt8(ascii: "\n"), "IPC responses must be newline-terminated JSON lines")
        return try JSONDecoder().decode(IPCResponse.self, from: data.dropLast())
    }

    private func activeNonLoopbackAddresses() throws -> [TCPHost] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { freeifaddrs(interfaces) }

        var addresses: [TCPHost] = []
        var seen = Set<TCPHost>()
        var cursor = interfaces
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }

            let flags = Int32(interface.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_RUNNING) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  let socketAddress = interface.pointee.ifa_addr
            else { continue }

            let host: TCPHost?
            switch Int32(socketAddress.pointee.sa_family) {
            case AF_INET:
                var address = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                    pointer.pointee.sin_addr
                }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
                    continue
                }
                host = .ipv4(String(cString: buffer))
            case AF_INET6:
                let socket = socketAddress.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                    pointer.pointee
                }
                var address = socket.sin6_addr
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
                    continue
                }
                host = .ipv6(String(cString: buffer), scopeID: socket.sin6_scope_id)
            default:
                host = nil
            }

            if let host, seen.insert(host).inserted {
                addresses.append(host)
            }
        }
        return addresses
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
    let host: TCPHost
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
        let fd = socket(host.addressFamily, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TCPLineClientError.socketFailed(errno) }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) { pointer in
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
        }
        _ = withUnsafePointer(to: &timeout) { pointer in
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
        }

        try host.connect(fd: fd, port: port)

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

private enum TCPHost: Hashable, CustomStringConvertible {
    case ipv4(String)
    case ipv6(String, scopeID: UInt32)

    static let loopback = TCPHost.ipv4("127.0.0.1")

    var addressFamily: Int32 {
        switch self {
        case .ipv4:
            return AF_INET
        case .ipv6:
            return AF_INET6
        }
    }

    var description: String {
        switch self {
        case .ipv4(let host):
            return host
        case .ipv6(let host, let scopeID) where scopeID != 0:
            return "[\(host)%\(scopeID)]"
        case .ipv6(let host, _):
            return "[\(host)]"
        }
    }

    func connect(fd: Int32, port: UInt16) throws {
        switch self {
        case .ipv4(let host):
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
                throw TCPLineClientError.invalidAddress(host)
            }

            try withUnsafePointer(to: &address) { pointer in
                try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    try connectWithTimeout(
                        fd: fd,
                        address: sockaddrPointer,
                        length: socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        case .ipv6(let host, let scopeID):
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            address.sin6_scope_id = scopeID
            guard inet_pton(AF_INET6, host, &address.sin6_addr) == 1 else {
                throw TCPLineClientError.invalidAddress(host)
            }

            try withUnsafePointer(to: &address) { pointer in
                try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    try connectWithTimeout(
                        fd: fd,
                        address: sockaddrPointer,
                        length: socklen_t(MemoryLayout<sockaddr_in6>.size)
                    )
                }
            }
        }
    }
}

private func connectWithTimeout(fd: Int32, address: UnsafePointer<sockaddr>, length: socklen_t) throws {
    let originalFlags = fcntl(fd, F_GETFL, 0)
    guard originalFlags >= 0 else { throw TCPLineClientError.connectFailed(errno) }
    guard fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) >= 0 else {
        throw TCPLineClientError.connectFailed(errno)
    }
    defer { _ = fcntl(fd, F_SETFL, originalFlags) }

    let result = Darwin.connect(fd, address, length)
    if result == 0 { return }

    let connectError = errno
    guard connectError == EINPROGRESS else {
        throw TCPLineClientError.connectFailed(connectError)
    }

    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    let pollResult = poll(&descriptor, 1, 1_000)
    guard pollResult != 0 else { throw TCPLineClientError.connectTimedOut }
    guard pollResult > 0 else { throw TCPLineClientError.connectFailed(errno) }

    var socketError: Int32 = 0
    var optionLength = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &optionLength) == 0 else {
        throw TCPLineClientError.connectFailed(errno)
    }
    guard socketError == 0 else { throw TCPLineClientError.connectFailed(socketError) }
}

private enum TCPLineClientError: Error, CustomStringConvertible {
    case socketFailed(Int32)
    case invalidAddress(String)
    case connectFailed(Int32)
    case connectTimedOut
    case sendFailed(Int32)
    case closedBeforeNewline
    case responseTooLarge

    var description: String {
        switch self {
        case .socketFailed(let code):
            return "socket failed: \(String(cString: strerror(code)))"
        case .invalidAddress(let address):
            return "invalid numeric address: \(address)"
        case .connectFailed(let code):
            return "connect failed: \(String(cString: strerror(code)))"
        case .connectTimedOut:
            return "connect timed out"
        case .sendFailed(let code):
            return "send failed: \(String(cString: strerror(code)))"
        case .closedBeforeNewline:
            return "connection closed before newline-terminated JSON response"
        case .responseTooLarge:
            return "response exceeded 64 KiB without a newline"
        }
    }
}
