import CryptoKit
import Foundation

/// 把 Qwen Code 的三份重叠本地投影合成唯一快照。
///
/// 会话内优先级固定为：聊天 transcript 的 `ui_telemetry` > 月度逐请求账本 >
/// `usage_record.jsonl` 的会话聚合。三者绝不相加；较低层只在较高层没有任何 Token 事件时兜底。
public final class QwenUsageSnapshotAdapter {
    public struct Snapshot {
        public let sessions: [ParsedSession]
        public let storageRevision: String
        public let sourceFiles: [URL]
        public let sourceBytes: Int64
    }

    struct StorageState {
        let files: [URL]
        let revision: String
        let sourceBytes: Int64
    }

    private struct SessionMetadata {
        var projectPath: String?
        var cliVersion: String?
        var startedAt: Date?
        var updatedAt: Date?
    }

    private struct CandidateEvent {
        let observedAt: Date
        let model: String?
        let identity: String
        let input: Int64
        let output: Int64
        let reasoning: Int64
        let cacheRead: Int64
        let sourceOffset: Int64
        let isSidechain: Bool
    }

    private let rootURL: URL
    private let usageHistoryRootURL: URL
    private let fileManager: FileManager
    private let dateFormatters = ClaudeCodeUsageEventParser.makeDateFormatters()

    public init(
        rootURL: URL,
        usageHistoryRootURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.usageHistoryRootURL = usageHistoryRootURL ?? rootURL
        self.fileManager = fileManager
    }

    public func snapshot() throws -> Snapshot {
        try snapshot(using: storageState())
    }

    func storageState() throws -> StorageState {
        let files = try relevantFiles()
        let revision = try storageRevision(files: files)
        let bytes = try files.reduce(Int64(0)) { partial, file in
            let attributes = try fileManager.attributesOfItem(atPath: file.path)
            return saturatingAdd(partial, (attributes[.size] as? NSNumber)?.int64Value ?? 0)
        }
        return StorageState(files: files, revision: revision, sourceBytes: bytes)
    }

    func snapshot(using storage: StorageState) throws -> Snapshot {
        let files = storage.files
        var metadata: [String: SessionMetadata] = [:]
        var transcriptEvents: [String: [CandidateEvent]] = [:]
        var monthlyEvents: [String: [CandidateEvent]] = [:]
        var aggregateRecords: [String: ([String: Any], Int64)] = [:]

        for file in files {
            if isTranscript(file) {
                try readJSONL(file) { [self] object, offset in
                    guard let sessionID = nonempty(JSONDictionary.string(object, "sessionId")) else { return }
                    updateMetadata(&metadata[sessionID, default: SessionMetadata()], object: object)
                    if let event = transcriptEvent(object, offset: offset) {
                        transcriptEvents[sessionID, default: []].append(event)
                    }
                }
            } else if isMonthlyUsage(file) {
                try readJSONL(file) { [self] object, offset in
                    guard let sessionID = nonempty(JSONDictionary.string(object, "sessionId")),
                          let event = monthlyEvent(object, offset: offset) else { return }
                    monthlyEvents[sessionID, default: []].append(event)
                    var value = metadata[sessionID, default: SessionMetadata()]
                    value.startedAt = value.startedAt.map { min($0, event.observedAt) } ?? event.observedAt
                    value.updatedAt = value.updatedAt.map { max($0, event.observedAt) } ?? event.observedAt
                    metadata[sessionID] = value
                }
            } else if file.lastPathComponent == "usage_record.jsonl" {
                try readJSONL(file) { [self] object, offset in
                    guard let sessionID = nonempty(JSONDictionary.string(object, "sessionId")) else { return }
                    let candidateTimestamp = numericTimestamp(object["timestamp"]) ?? Date(timeIntervalSince1970: 0)
                    let existingTimestamp = aggregateRecords[sessionID]
                        .flatMap { numericTimestamp($0.0["timestamp"]) }
                        ?? Date(timeIntervalSince1970: 0)
                    if aggregateRecords[sessionID] == nil || candidateTimestamp >= existingTimestamp {
                        aggregateRecords[sessionID] = (object, offset)
                    }
                    var value = metadata[sessionID, default: SessionMetadata()]
                    // usage_record 是最低优先级投影：只补 transcript 没有的项目路径，
                    // 时间则用边界合并，不让低优先级行覆盖更精确的会话元数据。
                    if value.projectPath == nil {
                        value.projectPath = nonempty(JSONDictionary.string(object, "project"))
                    }
                    if let start = numericTimestamp(object["startTime"]) {
                        value.startedAt = value.startedAt.map { min($0, start) } ?? start
                    }
                    if let end = numericTimestamp(object["timestamp"]) {
                        value.updatedAt = value.updatedAt.map { max($0, end) } ?? end
                    }
                    metadata[sessionID] = value
                }
            }
        }

        let sessionIDs = Set(metadata.keys)
            .union(transcriptEvents.keys)
            .union(monthlyEvents.keys)
            .union(aggregateRecords.keys)
        var sessions: [ParsedSession] = []
        for sessionID in sessionIDs.sorted() {
            let selected: [CandidateEvent]
            let projection: String
            if let events = transcriptEvents[sessionID], !events.isEmpty {
                selected = events
                projection = "transcript"
            } else if let events = monthlyEvents[sessionID], !events.isEmpty {
                selected = events
                projection = "monthly-ledger"
            } else if let aggregate = aggregateRecords[sessionID] {
                selected = aggregateEvents(aggregate.0, baseOffset: aggregate.1)
                projection = "session-aggregate"
            } else {
                selected = []
                projection = "metadata-only"
            }

            let retained = deduplicate(selected).sorted {
                if $0.observedAt != $1.observedAt { return $0.observedAt < $1.observedAt }
                return $0.identity < $1.identity
            }
            let meta = metadata[sessionID] ?? SessionMetadata()
            let events = retained.enumerated().map { index, candidate in
                UsageEvent(
                    eventSeq: index + 1,
                    observedAt: candidate.observedAt,
                    modelName: candidate.model,
                    messageId: candidate.identity,
                    dedupeKey: candidate.identity,
                    dedupeScopeKey: "qwen",
                    inputTokens: candidate.input,
                    outputTokens: candidate.output,
                    reasoningTokens: candidate.reasoning,
                    cacheReadTokens: candidate.cacheRead,
                    cacheWrite5mTokens: 0,
                    cacheWrite1hTokens: 0,
                    tokensReported: true,
                    sourceOffset: candidate.sourceOffset,
                    isSidechain: candidate.isSidechain
                )
            }
            sessions.append(ParsedSession(
                sourceKind: .qwenJSONL,
                providerId: "qwen-code",
                sessionKey: sessionID,
                projectPath: meta.projectPath,
                cliVersion: meta.cliVersion,
                startedAt: meta.startedAt ?? events.first?.observedAt,
                updatedAt: meta.updatedAt ?? events.last?.observedAt,
                events: events,
                rawMeta: ["source": "qwen-code", "usageProjection": projection]
            ))
        }

        return Snapshot(
            sessions: sessions,
            storageRevision: storage.revision,
            sourceFiles: files,
            sourceBytes: storage.sourceBytes
        )
    }

    public func sourceFiles() throws -> [URL] {
        try relevantFiles()
    }

    private func relevantFiles() throws -> [URL] {
        var isDirectory: ObjCBool = false
        var files: [URL] = []
        if fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue,
           let enumerator = fileManager.enumerator(
               at: rootURL,
               includingPropertiesForKeys: [.isRegularFileKey],
               options: [.skipsHiddenFiles]
           ) {
            for case let file as URL in enumerator {
                guard file.pathExtension.lowercased() == "jsonl",
                      (isTranscript(file) || isMonthlyUsage(file)),
                      try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                files.append(file)
            }
        }

        let usageHistory = usageHistoryRootURL.appendingPathComponent("usage_record.jsonl")
        if fileManager.fileExists(atPath: usageHistory.path),
           try usageHistory.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
           !files.contains(where: { $0.standardizedFileURL == usageHistory.standardizedFileURL }) {
            files.append(usageHistory)
        }
        return files.sorted { $0.path < $1.path }
    }

    private func isTranscript(_ file: URL) -> Bool {
        let relative = relativePath(file)
        return relative.hasPrefix("runtime/projects/")
            && relative.contains("/chats/")
            && !file.lastPathComponent.hasSuffix(".ledger.jsonl")
    }

    private func isMonthlyUsage(_ file: URL) -> Bool {
        file.deletingLastPathComponent().lastPathComponent == "usage"
            && file.lastPathComponent.hasPrefix("token-usage-")
    }

    private func transcriptEvent(_ object: [String: Any], offset: Int64) -> CandidateEvent? {
        guard JSONDictionary.string(object, "type") == "system",
              JSONDictionary.string(object, "subtype") == "ui_telemetry",
              let payload = JSONDictionary.dictionary(object, "systemPayload"),
              let event = JSONDictionary.dictionary(payload, "uiEvent"),
              JSONDictionary.string(event, "event.name") == "qwen-code.api_response",
              let timestamp = date(event["event.timestamp"] ?? object["timestamp"]) else { return nil }
        let normalized = normalizedTokens(
            input: nonnegative(event, "input_token_count"),
            output: nonnegative(event, "output_token_count"),
            cached: nonnegative(event, "cached_content_token_count"),
            thoughts: nonnegative(event, "thoughts_token_count"),
            total: nonnegative(event, "total_token_count"),
            thoughtsIncludedInOutput: {
                let authType = nonempty(JSONDictionary.string(event, "auth_type"))
                return authType == "openai" || authType == "qwen-oauth"
            }()
        )
        let responseID = nonempty(JSONDictionary.string(event, "response_id"))
        let promptID = nonempty(JSONDictionary.string(event, "prompt_id"))
        let identity = responseID.map { "response:\($0)" }
            ?? promptID.map { "prompt:\($0):\(Int64(timestamp.timeIntervalSince1970 * 1_000))" }
            ?? fingerprintIdentity(event: event, timestamp: timestamp)
        return CandidateEvent(
            observedAt: timestamp,
            model: nonempty(JSONDictionary.string(event, "model")),
            identity: identity,
            input: normalized.input,
            output: normalized.output,
            reasoning: normalized.reasoning,
            cacheRead: normalized.cacheRead,
            sourceOffset: offset,
            isSidechain: nonempty(JSONDictionary.string(event, "subagent_name")) != nil
                || nonempty(JSONDictionary.string(event, "subagent_id")) != nil
        )
    }

    private func monthlyEvent(_ object: [String: Any], offset: Int64) -> CandidateEvent? {
        guard let timestamp = date(object["timestamp"]),
              let id = nonempty(JSONDictionary.string(object, "id")) else { return nil }
        let normalized = normalizedTokens(
            input: nonnegative(object, "inputTokens"),
            output: nonnegative(object, "outputTokens"),
            cached: nonnegative(object, "cachedTokens"),
            thoughts: nonnegative(object, "thoughtsTokens"),
            total: nonnegative(object, "totalTokens")
        )
        let source = nonempty(JSONDictionary.string(object, "source"))
        return CandidateEvent(
            observedAt: timestamp,
            model: nonempty(JSONDictionary.string(object, "model")),
            identity: "ledger:\(id)",
            input: normalized.input,
            output: normalized.output,
            reasoning: normalized.reasoning,
            cacheRead: normalized.cacheRead,
            sourceOffset: offset,
            isSidechain: source != nil && source != "main"
        )
    }

    private func aggregateEvents(_ object: [String: Any], baseOffset: Int64) -> [CandidateEvent] {
        guard let models = JSONDictionary.dictionary(object, "models") else { return [] }
        let timestamp = numericTimestamp(object["timestamp"])
            ?? numericTimestamp(object["startTime"])
            ?? Date(timeIntervalSince1970: 0)
        return models.keys.sorted().enumerated().compactMap { index, model -> CandidateEvent? in
            guard let usage = JSONDictionary.dictionary(models[model]) else { return nil }
            let normalized = normalizedTokens(
                input: nonnegative(usage, "inputTokens"),
                output: nonnegative(usage, "outputTokens"),
                cached: nonnegative(usage, "cachedTokens"),
                thoughts: nonnegative(usage, "thoughtsTokens"),
                total: nonnegative(usage, "totalTokens")
            )
            return CandidateEvent(
                observedAt: timestamp,
                model: model,
                identity: "aggregate:\(model)",
                input: normalized.input,
                output: normalized.output,
                reasoning: normalized.reasoning,
                cacheRead: normalized.cacheRead,
                sourceOffset: baseOffset + Int64(index),
                isSidechain: false
            )
        }
    }

    /// 与 Qwen 自身的输入/总量兜底一致，再投影到 TokenMeter 的不重叠字段。
    private func normalizedTokens(
        input: Int64,
        output: Int64,
        cached: Int64,
        thoughts: Int64,
        total: Int64,
        thoughtsIncludedInOutput: Bool = false
    ) -> (input: Int64, output: Int64, reasoning: Int64, cacheRead: Int64) {
        let prompt = input > 0 ? input : cached
        let uncachedCompletion = thoughtsIncludedInOutput ? output : saturatingAdd(output, thoughts)
        let effectiveTotal = total > 0 ? total : saturatingAdd(prompt, uncachedCompletion)
        let cacheRead = min(cached, prompt)
        let completion = max(0, effectiveTotal - prompt)
        return (
            input: max(0, prompt - cacheRead),
            output: completion,
            reasoning: min(thoughts, completion),
            cacheRead: cacheRead
        )
    }

    private func deduplicate(_ events: [CandidateEvent]) -> [CandidateEvent] {
        var result: [CandidateEvent] = []
        var indices: [String: Int] = [:]
        for event in events {
            if let index = indices[event.identity] {
                let existing = result[index]
                let existingTotal = saturatingAdd(existing.input, saturatingAdd(existing.output, existing.cacheRead))
                let candidateTotal = saturatingAdd(event.input, saturatingAdd(event.output, event.cacheRead))
                if candidateTotal > existingTotal || (candidateTotal == existingTotal && event.observedAt >= existing.observedAt) {
                    result[index] = event
                }
            } else {
                indices[event.identity] = result.count
                result.append(event)
            }
        }
        return result
    }

    private func updateMetadata(_ value: inout SessionMetadata, object: [String: Any]) {
        value.projectPath = nonempty(JSONDictionary.string(object, "cwd")) ?? value.projectPath
        value.cliVersion = nonempty(JSONDictionary.string(object, "version")) ?? value.cliVersion
        if let timestamp = date(object["timestamp"]) {
            value.startedAt = value.startedAt.map { min($0, timestamp) } ?? timestamp
            value.updatedAt = value.updatedAt.map { max($0, timestamp) } ?? timestamp
        }
    }

    private func readJSONL(_ file: URL, consume: @escaping ([String: Any], Int64) -> Void) throws {
        let result = try JSONLStreamReader.readLines(from: file, startingAt: 0) { line in
            guard let object = JSONDictionary.object(from: line.text) else { return }
            consume(object, line.offset)
        }
        if let residual = result.residual {
            guard let object = JSONDictionary.object(from: residual) else {
                throw LocalAgentParserError.incompleteLine
            }
            consume(object, result.nextOffset)
        }
    }

    private func storageRevision(files: [URL]) throws -> String {
        var payload = Data()
        for file in files {
            let attributes = try fileManager.attributesOfItem(atPath: file.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let digest = try contentDigest(file)
            payload.append(Data("\(relativePath(file))\u{0}\(size)\u{0}\(Int64(modified * 1_000_000_000))\u{0}\(digest)\n".utf8))
        }
        return SHA256.hash(data: payload).lowercaseHex
    }

    /// Qwen 的三个投影会被整体合成；只看 size/mtime 会漏掉保留时间戳的等长改写。
    /// 扫描本来就要完整读取这些 JSONL，因此额外用有界块流式哈希，不把大文件整块载入内存。
    private func contentDigest(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().lowercaseHex
    }

    private func fingerprintIdentity(event: [String: Any], timestamp: Date) -> String {
        let parts = [
            String(Int64(timestamp.timeIntervalSince1970 * 1_000)),
            JSONDictionary.string(event, "model") ?? "",
            String(nonnegative(event, "input_token_count")),
            String(nonnegative(event, "output_token_count")),
            String(nonnegative(event, "cached_content_token_count")),
            String(nonnegative(event, "thoughts_token_count")),
            String(nonnegative(event, "total_token_count")),
        ].joined(separator: ":")
        return "fingerprint:" + SHA256.hash(data: Data(parts.utf8)).lowercaseHex
    }

    private func date(_ value: Any?) -> Date? {
        if let numeric = numericTimestamp(value) { return numeric }
        guard let raw = JSONDictionary.string(value) else { return nil }
        for formatter in dateFormatters {
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }

    private func numericTimestamp(_ value: Any?) -> Date? {
        guard let number = JSONDictionary.double(value), number > 0 else { return nil }
        return Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1_000 : number)
    }

    private func nonnegative(_ object: [String: Any], _ key: String) -> Int64 {
        max(0, JSONDictionary.int64(object, key) ?? 0)
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private func relativePath(_ file: URL) -> String {
        let root = rootURL.standardizedFileURL.path + "/"
        let path = file.standardizedFileURL.path
        if path.hasPrefix(root) { return "runtime/" + String(path.dropFirst(root.count)) }
        if file.standardizedFileURL == usageHistoryRootURL
            .appendingPathComponent("usage_record.jsonl").standardizedFileURL {
            return "home/usage_record.jsonl"
        }
        return file.lastPathComponent
    }

    private func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : result
    }
}
