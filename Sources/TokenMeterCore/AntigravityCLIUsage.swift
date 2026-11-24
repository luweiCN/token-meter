import Foundation

package enum AntigravityCLIUsage {
    package static let displayName = "Antigravity CLI"

    static func session(at file: URL) throws -> ParsedSession? {
        let db = try SQLiteDatabase(path: file.path, readOnly: true)
        defer { try? db.close() }
        // 时间、模型和用量必须来自同一 WAL 快照，CLI 可能正在写下一轮。
        try db.execute("BEGIN")
        defer { try? db.execute("ROLLBACK") }

        let tables = Set(try db.query("SELECT name FROM sqlite_master WHERE type = 'table'").compactMap { $0.string("name") })
        guard !tables.isEmpty else { return nil }
        guard tables.contains("gen_metadata") else { throw LocalAgentParserError.unsupportedFormat }
        guard !(try db.query("SELECT 1 FROM gen_metadata LIMIT 1")).isEmpty else { return nil }
        var createdAt: Date?
        var projectPath: String?
        if tables.contains("trajectory_metadata_blob") {
            try db.forEachIndexedBlob("SELECT 0, data FROM trajectory_metadata_blob WHERE id = 'main'") { _, data in
                let meta = try WireMessage(data)
                createdAt = try meta.timestamp(2)
                if let uri = try meta.message(1)?.string(1), let url = URL(string: uri), url.isFileURL {
                    projectPath = url.path
                }
            }
        }
        var timeByResponse: [String: Date] = [:]
        var timeByGeneration: [Int64: Date] = [:]
        if tables.contains("steps") {
            try db.forEachIndexedBlob("SELECT idx, metadata FROM steps WHERE step_type = 15 AND metadata IS NOT NULL ORDER BY idx") { _, data in
                let meta = try WireMessage(data)
                guard let time = try meta.timestamp(1) else { return }
                if let id = try meta.message(9)?.string(11) { timeByResponse[id] = time }
                if let reference = try meta.message(20) { timeByGeneration[try reference.count(3)] = time }
            }
        }

        var events: [UsageEvent] = []
        try db.forEachIndexedBlob("SELECT idx, data FROM gen_metadata ORDER BY idx") { index, data in
            guard let chat = try WireMessage(data).message(1), let usage = try chat.message(4) else { return }
            let input = try usage.count(2)
            let thinking = try usage.count(9)
            let output = usage.has(3) ? try usage.count(3) : thinking + (try usage.count(10))
            let write = try usage.count(4)
            let read = try usage.count(5)
            // 没有 Token 字段的初始化记录只带模型枚举值。
            guard input + output + write + read > 0 else { return }
            let responseID = usage.string(11)
            guard let observed = try responseID.flatMap({ timeByResponse[$0] }) ?? timeByGeneration[index]
                ?? chat.message(9)?.timestamp(4) ?? createdAt else { throw LocalAgentParserError.unsupportedFormat }
            events.append(UsageEvent(
                eventSeq: Int(index), observedAt: observed, modelName: modelName(id: chat.string(19), label: chat.string(21)),
                messageId: responseID, dedupeKey: responseID ?? "generation:\(index)",
                inputTokens: input, outputTokens: output, reasoningTokens: thinking,
                cacheReadTokens: read, cacheWrite5mTokens: write, sourceOffset: index
            ))
        }
        guard !events.isEmpty else { return nil }
        return ParsedSession(
            sourceKind: .antigravitySQLite, sessionKey: file.deletingPathExtension().lastPathComponent,
            projectPath: projectPath, cliVersion: nil, startedAt: createdAt ?? events.first?.observedAt,
            updatedAt: events.map(\.observedAt).max(), events: events, rawMeta: [:]
        )
    }

    static func modelName(id: String?, label: String?) -> String? {
        // AGY 在同一条生成记录里同时给内部路由和套餐展示名。只有两者的模型名
        // 和已知路由格式吻合时，才使用公开模型 ID 匹配价格。其他 SKU 保留原名。
        guard let id, let label, label.hasPrefix("Gemini "), label.hasSuffix(")"),
              let opening = label.range(of: " (", options: .backwards) else { return id }
        let model = label[..<opening.lowerBound].lowercased().replacingOccurrences(of: " ", with: "-")
        let effort = label[opening.upperBound..<label.index(before: label.endIndex)].lowercased()
        if id == "\(model)-tiered-\(effort)" || id == "\(model)-n" { return model }
        return id
    }
}

/// 只索引字段边界。生成记录的其他字段可能包含整段上下文，跳过时不解码或复制。
private struct WireMessage {
    private enum Value { case integer(UInt64), bytes(Data) }
    private var fields: [UInt64: Value] = [:]

    init(_ data: Data) throws {
        var offset = data.startIndex
        func varint() throws -> UInt64 {
            var result: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard offset < data.endIndex else { break }
                let byte = data[offset]
                offset += 1
                guard shift != 63 || byte <= 1 else { break }
                result |= UInt64(byte & 127) << shift
                if byte < 128 { return result }
            }
            throw LocalAgentParserError.unsupportedFormat
        }
        while offset < data.endIndex {
            let tag = try varint()
            let number = tag >> 3
            guard number > 0 else { throw LocalAgentParserError.unsupportedFormat }
            let size: UInt64
            switch tag & 7 {
            case 0:
                fields[number] = .integer(try varint())
                continue
            case 1: size = 8
            case 2: size = try varint()
            case 5: size = 4
            default: throw LocalAgentParserError.unsupportedFormat
            }
            guard size <= UInt64(data.endIndex - offset) else { throw LocalAgentParserError.unsupportedFormat }
            let end = offset + Int(size)
            fields[number] = .bytes(data[offset..<end])
            offset = end
        }
    }

    func has(_ field: UInt64) -> Bool { fields[field] != nil }

    func count(_ field: UInt64) throws -> Int64 {
        guard let value = fields[field] else { return 0 }
        guard case let .integer(n) = value, n <= UInt64(UInt32.max) else { throw LocalAgentParserError.unsupportedFormat }
        return Int64(n)
    }

    func message(_ field: UInt64) throws -> WireMessage? {
        guard case let .bytes(data) = fields[field] else { return nil }
        return try WireMessage(data)
    }

    func string(_ field: UInt64) -> String? {
        guard case let .bytes(data) = fields[field], !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func timestamp(_ field: UInt64) throws -> Date? {
        guard let stamp = try message(field) else { return nil }
        let seconds = try stamp.count(1)
        guard seconds > 0 else { return nil }
        let nanos = try stamp.count(2)
        guard nanos < 1_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000)
    }
}
