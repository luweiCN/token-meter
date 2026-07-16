import Foundation
import Network
// scanner 是非 Sendable 的 LocalAgentScanner，但全量重扫里它只在唯一那条后台队列上被使用，
// 捕获它跨队列是安全的。@preconcurrency 抑制这一处跨模块的 Sendable 告警。
@preconcurrency import TokenMeterCore

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
    private let eventBroadcaster = IPCEventBroadcaster()

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

        // 全量重扫要跑几分钟并持续推进度，不能走「答完即关」的常规一问一答路径。
        if request.method == "scan.requestFull" {
            streamFullRescan(on: connection)
            return
        }

        // 订阅连接同样不走「答完即关」：回一行确认后长期保持，
        // 此后所有事件行（agent.sessionEvent / data.changed）都推给它。
        if request.method == "events.subscribe" {
            let ack = IPCResponse(id: request.id, ok: true, result: ["status": "subscribed"], error: nil)
            var payload = (try? JSONEncoder().encode(ack)) ?? Data()
            payload.append(UInt8(ascii: "\n"))
            eventBroadcaster.add(connection, ack: payload)
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

    private static func notificationStateText(_ state: UsageNotificationAuthorizationState) -> String {
        switch state {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .notDetermined: return "notDetermined"
        case .unknown: return "unknown"
        }
    }

    /// 流式全量重扫：逐条 progress 一行 JSON（不 cancel），末尾一条 scan.finished。
    /// 扫描在后台队列跑；若客户端中途断开，扫描仍跑到底（数据必须落库），只是不再发进度。
    private func streamFullRescan(on connection: NWConnection) {
        let writer = RescanStreamWriter(connection: connection)
        guard let scanner = store.localAgentScanner else {
            writer.finish(encodeFinishedLine(status: "failed", error: "local session index unavailable"))
            return
        }

        let scanQueue = DispatchQueue(label: "TokenMeterIPCServer.fullRescan", qos: .utility)
        scanQueue.async {
            do {
                try scanner.fullRescan { event in
                    if let payload = encodeProgressLine(event) {
                        writer.sendProgress(payload)
                    }
                }
                writer.finish(encodeFinishedLine(status: "ok", error: nil))
            } catch {
                writer.finish(encodeFinishedLine(status: "failed", error: "full rescan failed"))
            }
        }
    }

    private func response(for request: IPCRequest) async -> IPCResponse {
        switch request.method {
        case "ping":
            return IPCResponse(id: request.id, ok: true, result: ["status": "ok"], error: nil)
        case "settingsChanged":
            guard let versionText = request.params?["version"], let version = Int(versionText), version > 0 else {
                return IPCResponse(id: request.id, ok: false, result: nil, error: "invalid settings version")
            }
            do {
                try store.reloadSettings(expectedVersion: version)
                return IPCResponse(id: request.id, ok: true, result: ["status": "settingsApplied"], error: nil)
            } catch {
                return IPCResponse(id: request.id, ok: false, result: nil, error: "settings reload failed")
            }
        case "scanNow":
            let result = await store.refreshLocalAgentIndex()
            switch result.status {
            case .failed, .unavailable:
                return IPCResponse(id: request.id, ok: false, result: nil, error: "local session index update failed")
            case .partial, .ok:
                return IPCResponse(
                    id: request.id,
                    ok: true,
                    result: [
                        "status": result.status.rawValue,
                        "message": result.message,
                        "scanned": String(result.scanned),
                        "failures": String(result.failures)
                    ],
                    error: nil
                )
            }
        case "credentials.set":
            let params = request.params ?? [:]
            guard let providerId = params["providerId"], !providerId.isEmpty else {
                return IPCResponse(id: request.id, ok: false, result: nil, error: "invalid provider id")
            }
            do {
                // token 空串 = 清除。钥匙串归 Swift app 管，Electron 永远拿不到明文。
                try KeychainCredentialStore.setToken(params["token"], for: providerId)
                return IPCResponse(
                    id: request.id,
                    ok: true,
                    result: ["hasToken": KeychainCredentialStore.hasToken(for: providerId) ? "true" : "false"],
                    error: nil
                )
            } catch {
                return IPCResponse(id: request.id, ok: false, result: nil, error: "keychain write failed")
            }
        case "credentials.state":
            let params = request.params ?? [:]
            guard let providerId = params["providerId"], !providerId.isEmpty else {
                return IPCResponse(id: request.id, ok: false, result: nil, error: "invalid provider id")
            }
            return IPCResponse(
                id: request.id,
                ok: true,
                result: ["hasToken": KeychainCredentialStore.hasToken(for: providerId) ? "true" : "false"],
                error: nil
            )
        case "agents.detect":
            // 探测同步阻塞（--version 最多 5s × 4），detached 到后台，不冻结菜单栏。
            let statuses = await Task.detached { AgentBinaryDetector.detect() }.value
            let payload = (try? JSONEncoder().encode(statuses))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            return IPCResponse(id: request.id, ok: true, result: ["agents": payload], error: nil)
        case "notifications.state":
            await store.refreshNotificationAuthorizationState()
            return IPCResponse(
                id: request.id,
                ok: true,
                result: ["state": Self.notificationStateText(store.notificationAuthorizationState)],
                error: nil
            )
        case "notifications.requestAuthorization":
            await store.requestNotificationAuthorization()
            return IPCResponse(
                id: request.id,
                ok: true,
                result: ["state": Self.notificationStateText(store.notificationAuthorizationState)],
                error: nil
            )
        case "agent.sessionEvent":
            let params = request.params ?? [:]
            guard let event = AgentSessionEvent(
                agentKind: params["agent"] ?? "",
                sessionId: params["sessionId"] ?? "",
                kind: params["event"] ?? "",
                cwd: params["cwd"],
                ownerPid: params["ownerPid"]
            ) else {
                return IPCResponse(id: request.id, ok: false, result: nil, error: "invalid session event")
            }
            do {
                try store.applyAgentSessionEvent(event)
            } catch {
                return IPCResponse(id: request.id, ok: false, result: nil, error: "session event persist failed")
            }
            eventBroadcaster.broadcast(IPCEventBroadcaster.encodeLine(kind: "agent.sessionEvent", extra: [
                "agent": event.agentKind,
                "event": event.kind.rawValue,
                "sessionId": event.sessionId
            ]))
            return IPCResponse(id: request.id, ok: true, result: ["status": "ok"], error: nil)
        default:
            return IPCResponse(id: request.id, ok: false, result: nil, error: "unknown method")
        }
    }

    /// 定时扫描完成后由 AppDelegate 调用：广播 data.changed，订阅方
    /// （Electron 主进程）据此让页面重取。hooks 事件不再触发扫描——
    /// 心跳（PostToolUse，活跃对话约 2 秒一发）曾让全量扫描以冷却周期
    /// 背靠背循环（每轮几万次文件 stat），多会话时 CPU 常态跑高。
    /// 状态实时由 live_sessions + agent.sessionEvent 广播承担，
    /// 用量数字跟随定时器节奏（autoRefreshSeconds）。
    func broadcastDataChanged() {
        eventBroadcaster.broadcast(IPCEventBroadcaster.encodeLine(kind: "data.changed"))
    }
}

/// 订阅连接的推送器。增删与 send 都走同一串行队列；send 失败（对端断开）
/// 即移除该连接。仿 RescanStreamWriter 的 @unchecked Sendable 论证：可变的
/// connections 只在私有串行 queue 上读写，NWConnection.send 本身线程安全。
private final class IPCEventBroadcaster: @unchecked Sendable {
    private let queue = DispatchQueue(label: "TokenMeterIPCServer.events")
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    func add(_ connection: NWConnection, ack: Data) {
        queue.async { [self] in
            let key = ObjectIdentifier(connection)
            connections[key] = connection
            connection.send(content: ack, completion: .contentProcessed { [self] error in
                if error != nil {
                    queue.async { self.remove(key) }
                }
            })
        }
    }

    func broadcast(_ payload: Data) {
        queue.async { [self] in
            for (key, connection) in connections {
                connection.send(content: payload, completion: .contentProcessed { [self] error in
                    if error != nil {
                        queue.async { self.remove(key) }
                    }
                })
            }
        }
    }

    private func remove(_ key: ObjectIdentifier) {
        connections[key]?.cancel()
        connections.removeValue(forKey: key)
    }

    static func encodeLine(kind: String, extra: [String: String] = [:]) -> Data {
        var object: [String: String] = ["kind": kind]
        for (key, value) in extra {
            object[key] = value
        }
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        data.append(UInt8(ascii: "\n"))
        return data
    }
}

private enum TokenMeterIPCServerError: Error {
    case invalidPort(UInt16)
}

/// 把全量重扫的多行响应写回连接。所有 send 走同一个串行队列——这保证 finished 永远排在
/// 所有 progress 之后，不会因为并发调度越到前面。NWConnection.send 本身线程安全。
///
/// `@unchecked Sendable` 是名副其实的：唯一的可变状态 `stopped` 只在私有串行 `queue` 上读写，
/// `connection` 只用于线程安全的 send。
private final class RescanStreamWriter: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "TokenMeterIPCServer.rescanStream")
    private var stopped = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    /// 只在客户端还在听时发进度。send 失败（客户端中途断开）后置 stopped，停止再发进度——
    /// 但**绝不**因此中断扫描，那由扫描队列独立跑完。
    func sendProgress(_ payload: Data) {
        queue.async { [self] in
            guard !stopped else { return }
            connection.send(content: payload, completion: .contentProcessed { [self] error in
                if error != nil {
                    queue.async { self.stopped = true }
                }
            })
        }
    }

    /// 末尾一行：写完才在 completion 里 cancel。先 cancel 会把最后一行丢掉。
    /// 即便客户端已断开也照发，send 只会在 completion 里静默失败，无害。
    func finish(_ payload: Data) {
        queue.async { [self] in
            connection.send(content: payload, completion: .contentProcessed { [self] _ in
                connection.cancel()
            })
        }
    }
}

private struct ScanProgressLine: Encodable {
    let kind: String
    let filesTotal: Int
    let filesDone: Int
    let bytesTotal: Int64
    let bytesDone: Int64
    let currentRoot: String
}

private struct ScanFinishedLine: Encodable {
    let kind: String
    let status: String
    let error: String?
}

private func encodeProgressLine(_ event: ScanProgressEvent) -> Data? {
    let line = ScanProgressLine(
        kind: "scan.progress",
        filesTotal: event.filesTotal,
        filesDone: event.filesDone,
        bytesTotal: event.bytesTotal,
        bytesDone: event.bytesDone,
        currentRoot: event.currentRoot
    )
    guard var data = try? JSONEncoder().encode(line) else { return nil }
    data.append(UInt8(ascii: "\n"))
    return data
}

private func encodeFinishedLine(status: String, error: String?) -> Data {
    let line = ScanFinishedLine(kind: "scan.finished", status: status, error: error)
    var data = (try? JSONEncoder().encode(line)) ?? Data(#"{"kind":"scan.finished","status":"failed"}"#.utf8)
    data.append(UInt8(ascii: "\n"))
    return data
}
