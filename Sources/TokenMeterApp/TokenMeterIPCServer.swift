import Foundation
import Network

struct IPCRequest: Codable {
    let id: String
    let method: String
    let params: [String: String]?

    init(id: String, method: String, params: [String: String]? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

struct IPCResponse: Codable {
    let id: String
    let ok: Bool
    let result: [String: String]?
    let error: String?
}

@MainActor
final class TokenMeterIPCServer {
    private let store: ProviderStore
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "TokenMeterIPCServer", qos: .utility)
    private let maximumRequestBytes = 64 * 1024
    private(set) var boundPort: UInt16?

    init(store: ProviderStore) {
        self.store = store
    }

    func start(port: UInt16 = 47731) throws {
        stop()

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let listenerPort = NWEndpoint.Port(rawValue: port),
              let loopbackAddress = IPv4Address("127.0.0.1")
        else {
            throw TokenMeterIPCServerError.invalidPort(port)
        }
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(loopbackAddress), port: listenerPort)

        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handle(connection)
            }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard case .ready = state, let port = listener?.port?.rawValue, port != 0 else { return }
            Task { @MainActor in
                self?.boundPort = port
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        boundPort = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveLine(from: connection, buffer: Data())
    }

    private func receiveLine(from connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self else {
                    connection.cancel()
                    return
                }
                if error != nil {
                    connection.cancel()
                    return
                }
                guard let data, !data.isEmpty else {
                    connection.cancel()
                    return
                }

                var nextBuffer = buffer
                nextBuffer.append(data)
                guard nextBuffer.count <= self.maximumRequestBytes else {
                    connection.cancel()
                    return
                }

                if let newlineIndex = nextBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = nextBuffer[..<newlineIndex]
                    self.respond(to: Data(line), on: connection)
                } else {
                    self.receiveLine(from: connection, buffer: nextBuffer)
                }
            }
        }
    }

    private func respond(to line: Data, on connection: NWConnection) {
        let request: IPCRequest
        do {
            request = try JSONDecoder().decode(IPCRequest.self, from: line)
        } catch {
            connection.cancel()
            return
        }

        Task { @MainActor in
            let response = await self.response(for: request)
            var payload = (try? JSONEncoder().encode(response)) ?? Data()
            payload.append(UInt8(ascii: "\n"))
            connection.send(content: payload, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func response(for request: IPCRequest) async -> IPCResponse {
        switch request.method {
        case "ping":
            return IPCResponse(id: request.id, ok: true, result: ["status": "ok"], error: nil)
        case "settingsChanged":
            store.reloadSettings()
            return IPCResponse(id: request.id, ok: true, result: ["status": "settingsApplied"], error: nil)
        case "scanNow":
            await store.refreshLocalAgentIndex()
            return IPCResponse(id: request.id, ok: true, result: ["status": store.localIndexStatusText], error: nil)
        default:
            return IPCResponse(id: request.id, ok: false, result: nil, error: "unknown method")
        }
    }
}

private enum TokenMeterIPCServerError: Error {
    case invalidPort(UInt16)
}
