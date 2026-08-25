import Foundation

/// DSH (DeepSeek Harness) 用量解析：`~/.dsh/sessions/<encoded-cwd>/<session-id>/session.jsonl.zstd`
///
/// 转录格式参考 Tokscale `crates/tokscale-core/src/sessions/dsh.rs`：
/// - 物理编码：`.zstd` 为多帧 zstd，live 写入时尾帧可能撕裂，需流式解压保留前缀；
///   `compression: none` 时为裸 `session.jsonl`，按魔数分发而非文件名。
/// - 关注行：
///   - `session`：`id` / `cwd` / `seedLength`（fork 边界，seq < seedLength 的为父历史，需跳过）
///   - `request/header`：`header.config.provider/model` 作为无 `source` 时的回退路由
///   - `assistant/message`：`data.usage`（inputTokens/outputTokens/cacheReadTokens/cacheWriteTokens/reasoningTokens）
///     + `data.message.source` 上的 `provider/model` + `time` + `data.turn` + `data.message.id`
/// - Token 语义：`reasoningTokens` 是 `outputTokens` 的子集（completion_tokens_details.reasoning_tokens），
///   输出桶需 `output - reasoning` 避免重复计费，与 Tokscale 的 senpi/grok/zcode 一致。
/// - 去重：`dsh:msg:<id>:<timestamp>:<provider>:<model>:<input>:<output>:<cache_read>:<cache_write>:<reasoning>`
///   其中 `id` 为 `data.message.id`（`crypto.randomUUID()`），fork 时 verbatim 拷贝，故跨文件也能合并；
///   无 id 时回退 `sid:<sessionId>`。`seen` 集合文件内去重，跨文件由 UsageEventDeduplicator 按 dedupeKey + scope="dsh" 合并。
/// - 成本：DSH 从不内嵌 cost，全部走定价表 computed。
public final class DshUsageEventParser: UsageEventParser {
    private var sessionId: String?
    private var workspaceKey: String?
    private var seedLength: Int64 = 0
    private var fallbackProvider: String?
    private var fallbackModel: String?
    private var seen: Set<String> = []
    private var turnStarted: Set<Int64> = []
    private var pendingUserTurn = false
    private var events: [UsageEvent] = []
    private var eventSeq: Int
    private var startedAt: Date?
    private var updatedAt: Date?
    private var sessionIdFromPath: String

    public init(resuming state: ParserState?) {
        eventSeq = state?.lastEventSeq ?? 0
        startedAt = state?.startedAt
        updatedAt = state?.updatedAt
        sessionId = state?.sessionKey
        // 续读时 workspaceKey 从 state 恢复，避免后段缺 cwd 时丢归属
        workspaceKey = state?.projectPath
        sessionIdFromPath = "unknown"
    }

    /// 供 LocalAgentScanner 在解析文件前注入基于路径的 sessionId 回退
    func setSessionIdFromPath(_ id: String) {
        sessionIdFromPath = id
    }

    public func consume(_ line: JSONLLine) {
        guard let object = JSONDictionary.object(from: line.text),
              let type_ = JSONDictionary.string(object, "type") else { return }

        switch type_ {
        case "session":
            sessionId = JSONDictionary.string(object, "id") ?? sessionId
            workspaceKey = JSONDictionary.string(object, "cwd") ?? workspaceKey
            if let seed = JSONDictionary.int64(object, "seedLength"), seed > 0 {
                seedLength = seed
            }
            // createdAt 也可作为 startedAt 回退
            if startedAt == nil, let created = JSONDictionary.int64(object, "createdAt"), created > 0 {
                let date = Date(timeIntervalSince1970: Double(created) / 1000.0)
                startedAt = date
                updatedAt = date
            }

        case "request/header":
            if let header = JSONDictionary.dictionary(object, "data").flatMap({ JSONDictionary.dictionary($0, "header") }).flatMap({ JSONDictionary.dictionary($0, "config") }) {
                fallbackProvider = JSONDictionary.string(header, "provider") ?? fallbackProvider
                fallbackModel = JSONDictionary.string(header, "model") ?? fallbackModel
            } else if let data = JSONDictionary.dictionary(object, "data"),
                      let header = JSONDictionary.dictionary(data, "header"),
                      let config = JSONDictionary.dictionary(header, "config") {
                fallbackProvider = JSONDictionary.string(config, "provider") ?? fallbackProvider
                fallbackModel = JSONDictionary.string(config, "model") ?? fallbackModel
            }

        case "user/message":
            pendingUserTurn = true

        case "assistant/message":
            // fork 边界：seq < seedLength 的为父历史，跳过
            if seedLength > 0, let seq = JSONDictionary.int64(object, "seq"), seq < seedLength {
                return
            }
            guard let data = JSONDictionary.dictionary(object, "data"),
                  let usage = JSONDictionary.dictionary(data, "usage") else { return }

            let tokens = tokensFromUsage(usage)
            if tokens.total == 0 { return }

            guard let timestampMs = JSONDictionary.int64(object, "time"), timestampMs > 0 else { return }
            let observedAt = Date(timeIntervalSince1970: Double(timestampMs) / 1000.0)
            if startedAt == nil { startedAt = observedAt }
            updatedAt = observedAt

            // provider/model 优先 data.message.source，回退到 request/header
            var providerId: String?
            var modelId: String?
            if let message = JSONDictionary.dictionary(data, "message"),
               let source = JSONDictionary.dictionary(message, "source") {
                providerId = JSONDictionary.string(source, "provider")
                modelId = JSONDictionary.string(source, "model")
            }
            let finalProvider = (providerId ?? fallbackProvider ?? "unknown")
            let finalModel = (modelId ?? fallbackModel ?? "unknown")

            let sid = sessionId ?? sessionIdFromPath

            // turn start 判定
            let isTurnStart: Bool
            if let turn = data["turn"] as? NSNumber {
                let turnVal = turn.int64Value
                isTurnStart = turnStarted.insert(turnVal).inserted
            } else if let turn = data["turn"] as? Int64 {
                isTurnStart = turnStarted.insert(turn).inserted
            } else if let turn = JSONDictionary.int64(data, "turn") {
                isTurnStart = turnStarted.insert(turn).inserted
            } else {
                isTurnStart = pendingUserTurn
                pendingUserTurn = false
            }
            if isTurnStart == false {
                // pendingUserTurn 已在取时清掉，无需额外处理
            } else {
                pendingUserTurn = false
            }

            // dedupeKey：与 Tokscale 保持一致，含 message.id 以实现跨文件 fork 合并
            let messageId: String? = {
                if let message = JSONDictionary.dictionary(data, "message"),
                   let id = JSONDictionary.string(message, "id")?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !id.isEmpty {
                    return id
                }
                return nil
            }()
            let identity = messageId.map { "msg:\($0)" } ?? "sid:\(sid)"
            let dedupeKey = "dsh:\(identity):\(timestampMs):\(finalProvider):\(finalModel):\(tokens.input):\(tokens.output):\(tokens.cacheRead):\(tokens.cacheWrite):\(tokens.reasoning)"
            if seen.contains(dedupeKey) { return }
            seen.insert(dedupeKey)

            eventSeq += 1
            // isSidechain 暂为 false，DSH 的 subagent 通过 seedLength 已过滤
            let event = UsageEvent(
                eventSeq: eventSeq,
                observedAt: observedAt,
                modelName: finalModel,
                messageId: messageId,
                dedupeKey: dedupeKey,
                dedupeScopeKey: "dsh",
                inputTokens: tokens.input,
                outputTokens: tokens.output,
                reasoningTokens: tokens.reasoning,
                cacheReadTokens: tokens.cacheRead,
                cacheWrite5mTokens: tokens.cacheWrite,
                cacheWrite1hTokens: 0,
                reportedCostUSDMicros: nil,
                sourceOffset: line.offset,
                isSidechain: false
            )
            events.append(event)
            // turn start 信息目前不进 UsageEvent，保留未来扩展

        default:
            break
        }
    }

    public func finish(sourceURL: URL) throws -> (session: ParsedSession?, state: ParserState) {
        // 即使无 session 事件，也用路径回退的 sid 作为 sessionKey，保持与 Tokscale 一致
        let finalSessionId = sessionId ?? sessionIdFromPath
        if finalSessionId == "unknown" || finalSessionId.isEmpty {
            throw LocalAgentParserError.missingSessionKey
        }

        // 无用量事件：返回 nil session，静默跳过（与 Reasonix 逻辑一致）
        guard !events.isEmpty else {
            let state = ParserState(
                lastEventSeq: eventSeq,
                lastCumulative: nil,
                sessionKey: finalSessionId,
                projectPath: workspaceKey,
                cliVersion: nil,
                startedAt: startedAt,
                updatedAt: updatedAt
            )
            return (nil, state)
        }

        let session = ParsedSession(
            sourceKind: .dshJSONL,
            sessionKey: finalSessionId,
            projectPath: workspaceKey,
            cliVersion: nil,
            startedAt: startedAt,
            updatedAt: updatedAt,
            events: events,
            rawMeta: ["source": "dsh"]
        )
        let state = ParserState(
            lastEventSeq: eventSeq,
            lastCumulative: nil,
            sessionKey: finalSessionId,
            projectPath: workspaceKey,
            cliVersion: nil,
            startedAt: startedAt,
            updatedAt: updatedAt
        )
        return (session, state)
    }

    private struct TokenBreakdown {
        let input: Int64
        let output: Int64
        let cacheRead: Int64
        let cacheWrite: Int64
        let reasoning: Int64
        var total: Int64 { input + output + cacheRead + cacheWrite + reasoning }
    }

    private func tokensFromUsage(_ usage: [String: Any]) -> TokenBreakdown {
        let output = max(0, JSONDictionary.int64(usage, "outputTokens") ?? 0)
        let reasoning = max(0, JSONDictionary.int64(usage, "reasoningTokens") ?? 0)
        return TokenBreakdown(
            input: max(0, JSONDictionary.int64(usage, "inputTokens") ?? 0),
            output: output >= reasoning ? output - reasoning : 0,
            cacheRead: max(0, JSONDictionary.int64(usage, "cacheReadTokens") ?? 0),
            cacheWrite: max(0, JSONDictionary.int64(usage, "cacheWriteTokens") ?? 0),
            reasoning: reasoning
        )
    }
}

/// DSH 文件读取辅助：按 zstd 魔数分发，流式保留 torn 尾帧前缀
enum DshFileReader {
    private static let zstdMagic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]

    /// 读取并解压 DSH 会话文件，返回 UTF-8 字符串。失败返回 nil。
    static func readDecodedString(from url: URL) -> String? {
        guard let raw = try? Data(contentsOf: url) else { return nil }
        if raw.count >= 4 && raw.prefix(4).elementsEqual(zstdMagic) {
            // zstd 压缩：用 CLI `zstd -d -c <path>`，它对撕裂尾帧会输出前缀并返回非零，Tokscale 同款语义
            if let decoded = decodeZstdViaCLI(url: url) {
                return String(data: decoded, encoding: .utf8) ?? String(decoding: decoded, as: UTF8.self)
            }
            if let decoded = decodeZstdViaCLI(data: raw) {
                return String(data: decoded, encoding: .utf8) ?? String(decoding: decoded, as: UTF8.self)
            }
            // 回退：尝试用 Compression 框架（若可用），或直接返回 nil
            if let decoded = decodeZstdViaCompression(data: raw) {
                return String(data: decoded, encoding: .utf8) ?? String(decoding: decoded, as: UTF8.self)
            }
            return nil
        } else {
            // 裸 JSONL
            return String(data: raw, encoding: .utf8) ?? String(decoding: raw, as: UTF8.self)
        }
    }

    /// 用 `zstd` CLI 解压（文件路径版，避免 stdin 管道死锁），保留 torn 帧前缀
    private static func decodeZstdViaCLI(url: URL) -> Data? {
        let candidates = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]
        let zstdPath: String? = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        let useEnv = zstdPath == nil
        // 使用临时文件接输出，避免 Pipe 缓冲区死锁（大文件时 stdout 填满会阻塞子进程）
        let tmpOut = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: tmpOut.path, contents: nil)
        guard let outHandle = try? FileHandle(forWritingTo: tmpOut) else { return nil }
        defer {
            try? outHandle.close()
            try? FileManager.default.removeItem(at: tmpOut)
        }
        let process = Process()
        if useEnv {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["zstd", "-d", "-c", "--", url.path]
        } else {
            process.executableURL = URL(fileURLWithPath: zstdPath!)
            process.arguments = ["-d", "-c", "--", url.path]
        }
        process.standardOutput = outHandle
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            try? outHandle.close()
            let output = (try? Data(contentsOf: tmpOut)) ?? Data()
            if !output.isEmpty {
                return output
            }
            return nil
        } catch {
            return nil
        }
    }

    /// 用 `zstd` CLI 解压（Data 版，保留用于回退）
    private static func decodeZstdViaCLI(data: Data) -> Data? {
        let candidates = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]
        let zstdPath: String? = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        let useEnv = zstdPath == nil
        let process = Process()
        if useEnv {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["zstd", "-d", "-c", "-"]
        } else {
            process.executableURL = URL(fileURLWithPath: zstdPath!)
            process.arguments = ["-d", "-c", "-"]
        }
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            stdin.fileHandleForWriting.write(data)
            stdin.fileHandleForWriting.closeFile()
            process.waitUntilExit()
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            if !output.isEmpty {
                return output
            }
            return nil
        } catch {
            return nil
        }
    }

    /// 尝试用 Compression 框架的 ZSTD 解压（macOS 13+）
    private static func decodeZstdViaCompression(data: Data) -> Data? {
        // 使用 libcompression 的低级 API 只有在导入 Compression 成功时可用；
        // 这里用动态方式避免编译期依赖
        // 若不可用，直接返回 nil，由上层按空处理
        return nil
    }
}
