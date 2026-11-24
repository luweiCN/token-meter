import Foundation

enum GeminiCLIUsage {
    static func files(under root: URL) throws -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        var files: [URL] = []
        for project in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            let chats = project.appendingPathComponent("chats", isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: chats.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let entries = try fm.contentsOfDirectory(at: chats, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            for entry in entries {
                if try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                    // 子代理日志保存在 chats/<完整父会话 ID>/ 中。
                    files += try fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                        .filter { $0.pathExtension == "jsonl" }
                } else if ["json", "jsonl"].contains(entry.pathExtension),
                          entry.lastPathComponent.hasPrefix("session-") || UUID(uuidString: entry.deletingPathExtension().lastPathComponent) != nil {
                    files.append(entry)
                }
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    static func session(at file: URL) throws -> ParsedSession? {
        let decoder = JSONDecoder()
        let dates = ClaudeCodeUsageEventParser.makeDateFormatters()
        func date(_ string: String?) -> Date? { string.flatMap { value in dates.lazy.compactMap { $0.date(from: value) }.first } }
        var header: Record?
        var events: [String: UsageEvent] = [:]
        var sequence = 0

        func consume(_ record: Record, offset: Int64) {
            if record.sessionId != nil { header = record }
            guard record.type == "gemini", let id = record.id, !id.isEmpty, let tokens = record.tokens,
                  let observed = date(record.timestamp), let counts = tokens.breakdown else { return }
            sequence += 1
            events[id] = UsageEvent(
                eventSeq: sequence, observedAt: observed, modelName: record.model, messageId: id, dedupeKey: id,
                inputTokens: counts.input, outputTokens: counts.output, reasoningTokens: Int64(tokens.thoughts ?? 0),
                cacheReadTokens: Int64(tokens.cached ?? 0), sourceOffset: offset
            )
        }
        if file.pathExtension == "json" {
            let conversation = try decoder.decode(Record.self, from: Data(contentsOf: file, options: [.mappedIfSafe]))
            header = conversation
            for (offset, message) in (conversation.messages ?? []).enumerated() { consume(message, offset: Int64(offset)) }
        } else {
            let result = try JSONLStreamReader.readLines(from: file, startingAt: 0) { line in
                let record = try decoder.decode(Record.self, from: Data(line.text.utf8))
                consume(record, offset: line.offset)
                // 早期 JSONL 的 $set.messages 可以带上一次完整的历史投影。
                for message in record.set?.messages ?? [] { consume(message, offset: line.offset) }
            }
            if result.residual != nil { throw LocalAgentParserError.incompleteLine }
        }
        guard !events.isEmpty else { return nil }
        guard let key = header?.sessionId, !key.isEmpty else { throw LocalAgentParserError.missingSessionKey }
        let directory = file.deletingLastPathComponent()
        let isChild = directory.lastPathComponent != "chats" && directory.deletingLastPathComponent().lastPathComponent == "chats"
        let chats = isChild ? directory.deletingLastPathComponent() : directory
        let marker = chats.deletingLastPathComponent().appendingPathComponent(".project_root")
        let project = (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = events.values.sorted { $0.eventSeq < $1.eventSeq }
        return ParsedSession(
            sourceKind: .geminiChat, sessionKey: key,
            projectPath: project?.hasPrefix("/") == true ? project : nil, cliVersion: nil,
            startedAt: date(header?.startTime) ?? rows.first?.observedAt,
            updatedAt: rows.map(\.observedAt).max(), events: rows, rawMeta: [:],
            rootSessionKey: isChild ? directory.lastPathComponent : nil
        )
    }

    private struct Record: Decodable {
        let sessionId: String?
        let startTime: String?
        let messages: [Record]?
        let set: HistoricalMessages?
        let id: String?
        let timestamp: String?
        let type: String?
        let model: String?
        let tokens: Tokens?

        enum CodingKeys: String, CodingKey {
            case sessionId, startTime, messages, id, timestamp, type, model, tokens
            case set = "$set"
        }
    }

    private struct HistoricalMessages: Decodable { let messages: [Record]? }

    private struct Tokens: Decodable {
        let input, output, cached, thoughts, tool, total: Int32?

        var breakdown: (input: Int64, output: Int64)? {
            guard input != nil || output != nil || total != nil,
                  [input, output, cached, thoughts, tool, total].compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else { return nil }
            let prompt = Int64(input ?? 0)
            let generated = Int64(output ?? 0) + Int64(thoughts ?? 0)
            let toolPrompt = Int64(tool ?? 0)
            let hit = Int64(cached ?? 0)
            // totalTokenCount 决定工具提示是否已经包含在 promptTokenCount。
            let fullInput = prompt + toolPrompt
            guard hit <= prompt else { return nil }
            if let total, total > 0 {
                let reportedInput = Int64(total) - generated
                guard reportedInput >= hit else { return nil }
                return (reportedInput - hit, generated)
            }
            return (fullInput - hit, generated)
        }
    }
}
