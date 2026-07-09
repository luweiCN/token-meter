import Foundation

/// OpenCode 把会话存在一个 SQLite 库里，不是 JSONL，因此不走 UsageEventParser 协议。
///
/// 旧的 OpenCodeSessionAdapter 的 parseMessageRow 本来就是逐条消息解析的，
/// 只是 mergeMessageSession / mergeUsage 又把它们求和回一条。这里照抄它的
/// SQL 与 JSON 解析，但**不做任何合并**：一条 message = 一个 UsageEvent。
public final class OpenCodeUsageEventAdapter {
    private let sourceDatabase: SQLiteDatabase
    private let isoFormatter = ISO8601DateFormatter()

    public init(sourceDatabase: SQLiteDatabase) {
        self.sourceDatabase = sourceDatabase
    }

    public func changedSessions(after highWaterMark: String?) throws -> [ParsedSession] {
        guard try tableExists("message") else { return [] }
        let hasUpdatedColumn = try columnExists(table: "message", column: "time_updated")

        // 第一遍：找出 high-water-mark 之后有变化的 session。
        let changedRows = try changedMessageRows(after: highWaterMark, hasUpdatedColumn: hasUpdatedColumn)
        var changedSessionKeys = Set<String>()
        for row in changedRows {
            guard let data = row.string("data"),
                  let event = parseMessageRow(row: row, data: data) else { continue }
            changedSessionKeys.insert(event.sessionKey)
        }
        guard !changedSessionKeys.isEmpty else { return [] }

        // 第二遍：对每个变化的 session 全量重读，保证 eventSeq 能从 1 稳定编号。
        var eventsByKey: [String: [ParsedMessageEvent]] = [:]
        var seenMessageIds = Set<String>()
        for sessionKey in changedSessionKeys.sorted() {
            for row in try messageRows(for: sessionKey, hasUpdatedColumn: hasUpdatedColumn) {
                guard let data = row.string("data"),
                      let event = parseMessageRow(row: row, data: data),
                      seenMessageIds.insert(event.messageId).inserted else { continue }
                eventsByKey[event.sessionKey, default: []].append(event)
            }
        }

        let directories = try sessionDirectories()

        var sessions: [ParsedSession] = []
        for (sessionKey, parsedEvents) in eventsByKey {
            // 组内按 time.created 升序（同刻用 messageId 兜底），再从 1 编号。
            let ordered = parsedEvents.sorted {
                if $0.createdMilliseconds == $1.createdMilliseconds {
                    return $0.messageId < $1.messageId
                }
                return $0.createdMilliseconds < $1.createdMilliseconds
            }

            var events: [UsageEvent] = []
            events.reserveCapacity(ordered.count)
            for (index, parsed) in ordered.enumerated() {
                let sequence = index + 1
                events.append(
                    UsageEvent(
                        eventSeq: sequence,
                        observedAt: parsed.observedAt,
                        modelName: parsed.modelName,
                        messageId: parsed.messageId,
                        // OpenCode 的 message 没有 request id，dedupeKey 恒为 nil
                        // （adapter 已用 seenMessageIds 去重，保持今天的行为）。
                        requestId: nil,
                        dedupeKey: nil,
                        // cache 独立于 input，原样取值，绝不像 Codex 那样减 cached。
                        inputTokens: parsed.inputTokens,
                        // output 已含 reasoning，reasoning 仅做展示不进总量。
                        outputTokens: parsed.outputTokens,
                        reasoningTokens: parsed.reasoningTokens,
                        cacheReadTokens: parsed.cacheReadTokens,
                        // OpenCode 不区分缓存写入档位，整笔归 5m。
                        cacheWrite5mTokens: parsed.cacheWriteTokens,
                        cacheWrite1hTokens: 0,
                        reportedCostUSDMicros: parsed.reportedCostUSDMicros,
                        // 数据库源没有字节偏移，用 session 内 1-based 序号，
                        // 让 max(source_offset) 仍是可续读的游标。
                        sourceOffset: Int64(sequence),
                        isSidechain: false
                    )
                )
            }

            guard let first = events.first, let last = events.last else { continue }
            let provider = ordered.compactMap { $0.provider }.first
            sessions.append(
                ParsedSession(
                    sourceKind: .opencodeSQLite,
                    sessionKey: sessionKey,
                    projectPath: directories[sessionKey],
                    cliVersion: nil,
                    startedAt: first.observedAt,
                    updatedAt: last.observedAt,
                    events: events,
                    rawMeta: rawMeta(provider: provider)
                )
            )
        }

        return sessions.sorted { $0.sessionKey < $1.sessionKey }
    }

    /// 逐条消息解析成一个待编号的事件，**不做任何跨消息合并**。
    private func parseMessageRow(row: SQLiteRow, data: String) -> ParsedMessageEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)),
              let dictionary = object as? [String: Any] else {
            return nil
        }

        let messageId = stringValue(dictionary["id"]) ?? row.string("id")
        guard let messageId else { return nil }
        let sessionKey = stringValue(dictionary["sessionID"]) ?? row.string("session_id") ?? messageId

        let tokens = dictionary["tokens"] as? [String: Any]
        let cache = tokens?["cache"] as? [String: Any]
        let inputTokens = intValue(tokens?["input"]) ?? 0
        let outputTokens = intValue(tokens?["output"]) ?? 0
        let reasoningTokens = intValue(tokens?["reasoning"]) ?? 0
        let cacheReadTokens = intValue(cache?["read"]) ?? 0
        let cacheWriteTokens = intValue(cache?["write"]) ?? 0

        guard inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens > 0 else { return nil }

        let createdMilliseconds = doubleValue((dictionary["time"] as? [String: Any])?["created"])
            ?? row.double("time_updated")
            ?? row.double("time_created")
            ?? 0
        let observedAt = Date(timeIntervalSince1970: createdMilliseconds / 1000)

        // cost == 0 表示 OpenCode 不知道单价（套餐制），返回 nil 交给 CostCalculator 自算。
        // 存 0 会让「不知道」看起来像「免费」。
        let reportedCostUSDMicros: Int64?
        if let cost = doubleValue(dictionary["cost"]), cost > 0 {
            reportedCostUSDMicros = Int64((cost * 1_000_000).rounded())
        } else {
            reportedCostUSDMicros = nil
        }

        return ParsedMessageEvent(
            sessionKey: sessionKey,
            messageId: messageId,
            createdMilliseconds: createdMilliseconds,
            observedAt: observedAt,
            modelName: stringValue(dictionary["modelID"]),
            provider: stringValue(dictionary["providerID"]),
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            reportedCostUSDMicros: reportedCostUSDMicros
        )
    }

    /// session 表存有每个会话的工作目录，作为 projectPath。测试库只有 message 表时返回空表。
    private func sessionDirectories() throws -> [String: String] {
        guard try tableExists("session"),
              try columnExists(table: "session", column: "directory") else {
            return [:]
        }
        let rows = try sourceDatabase.query("SELECT id, directory FROM session")
        var directories: [String: String] = [:]
        for row in rows {
            if let id = row.string("id"),
               let directory = row.string("directory"),
               !directory.isEmpty {
                directories[id] = directory
            }
        }
        return directories
    }

    // MARK: - 复用旧适配器的 SQL 与 high-water-mark 逻辑

    private func changedMessageRows(after highWaterMark: String?, hasUpdatedColumn: Bool) throws -> [SQLiteRow] {
        if hasUpdatedColumn {
            let usesNumericTimestamp = try columnUsesNumericAffinity(table: "message", column: "time_updated")
            return try sourceDatabase.query(
                """
                SELECT id, session_id, time_updated, data
                FROM message
                WHERE (? IS NULL OR time_updated > ?)
                ORDER BY time_updated ASC, id ASC
                """,
                highWaterParameters(highWaterMark, numeric: usesNumericTimestamp)
            )
        }

        return try sourceDatabase.query(
            """
            SELECT id, session_id, json_extract(data, '$.time.created') AS time_updated, data
            FROM message
            WHERE (? IS NULL OR json_extract(data, '$.time.created') > ?)
            ORDER BY json_extract(data, '$.time.created') ASC, id ASC
            """,
            highWaterParameters(highWaterMark, numeric: true)
        )
    }

    private func messageRows(for sessionKey: String, hasUpdatedColumn: Bool) throws -> [SQLiteRow] {
        let updatedColumn = hasUpdatedColumn ? "time_updated" : "json_extract(data, '$.time.created') AS time_updated"
        let updatedOrder = hasUpdatedColumn ? "time_updated" : "json_extract(data, '$.time.created')"
        return try sourceDatabase.query(
            """
            SELECT id, session_id, \(updatedColumn), data
            FROM message
            WHERE session_id = ?
               OR (json_valid(data) AND json_extract(data, '$.sessionID') = ?)
            ORDER BY \(updatedOrder) ASC, id ASC
            """,
            [.text(sessionKey), .text(sessionKey)]
        )
    }

    private func highWaterParameters(_ highWaterMark: String?, numeric: Bool) -> [SQLiteValue] {
        guard let highWaterMark else {
            return [.null, .null]
        }
        if numeric {
            let milliseconds = highWaterMilliseconds(highWaterMark) ?? 0
            return [.double(milliseconds), .double(milliseconds)]
        }
        return [.text(highWaterMark), .text(highWaterMark)]
    }

    private func highWaterMilliseconds(_ highWaterMark: String) -> Double? {
        if let milliseconds = Double(highWaterMark) {
            return milliseconds
        }
        return parseISODate(highWaterMark).map { $0.timeIntervalSince1970 * 1000 }
    }

    private func rawMeta(provider: String?) -> [String: String] {
        var meta = ["source": "opencode"]
        if let provider, !provider.isEmpty {
            meta["provider"] = provider
        }
        return meta
    }

    // MARK: - schema 探测与 JSON 取值（照抄旧适配器）

    private func tableExists(_ tableName: String) throws -> Bool {
        let rows = try sourceDatabase.query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
            [.text(tableName)]
        )
        return !rows.isEmpty
    }

    private func columnExists(table: String, column: String) throws -> Bool {
        try columnType(table: table, column: column) != nil
    }

    private func columnUsesNumericAffinity(table: String, column: String) throws -> Bool {
        guard let type = try columnType(table: table, column: column)?.uppercased() else {
            return false
        }
        return type.contains("INT")
            || type.contains("REAL")
            || type.contains("FLOA")
            || type.contains("DOUB")
            || type.contains("NUM")
    }

    private func columnType(table: String, column: String) throws -> String? {
        try sourceDatabase.query("PRAGMA table_info(\(table))")
            .first { $0.string("name") == column }?
            .string("type")
    }

    private func parseISODate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractionalFormatter.date(from: value) ?? isoFormatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private func intValue(_ value: Any?) -> Int64? {
        switch value {
        case let number as NSNumber:
            return number.int64Value
        case let string as String:
            return Int64(string)
        default:
            return nil
        }
    }

    private func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }

    private func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }
}

private struct ParsedMessageEvent {
    let sessionKey: String
    let messageId: String
    let createdMilliseconds: Double
    let observedAt: Date
    let modelName: String?
    let provider: String?
    let inputTokens: Int64
    let outputTokens: Int64
    let reasoningTokens: Int64
    let cacheReadTokens: Int64
    let cacheWriteTokens: Int64
    let reportedCostUSDMicros: Int64?
}
