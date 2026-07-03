import Foundation

public final class OpenCodeSessionAdapter {
    private let sourceDatabase: SQLiteDatabase
    private let isoFormatter = ISO8601DateFormatter()

    public init(sourceDatabase: SQLiteDatabase) {
        self.sourceDatabase = sourceDatabase
    }

    public func changedSessions(after highWaterMark: String?) throws -> [ParsedAgentSession] {
        var sessions: [ParsedAgentSession] = []
        var messageSessionKeys = Set<String>()

        if try tableExists("message") {
            let messageSessions = try changedMessageSessions(after: highWaterMark)
            sessions.append(contentsOf: messageSessions)
            messageSessionKeys.formUnion(messageSessions.map(\.sessionKey))
        }

        if try tableExists("session") {
            var legacySessionKeys = Set<String>()
            for session in try changedLegacySessions(after: highWaterMark)
            where !messageSessionKeys.contains(session.sessionKey) && legacySessionKeys.insert(session.sessionKey).inserted {
                sessions.append(session)
            }
        }

        return sessions.sorted { lhs, rhs in
            let lhsDate = lhs.updatedAt ?? lhs.startedAt ?? Date.distantPast
            let rhsDate = rhs.updatedAt ?? rhs.startedAt ?? Date.distantPast
            if lhsDate == rhsDate {
                return lhs.sessionKey < rhs.sessionKey
            }
            return lhsDate < rhsDate
        }
    }

    private func changedLegacySessions(after highWaterMark: String?) throws -> [ParsedAgentSession] {
        let usesNumericTimestamp = try columnUsesNumericAffinity(table: "session", column: "time_updated")
        let rows = try sourceDatabase.query(
            """
            SELECT id, directory, model, agent, time_created, time_updated,
                   tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, cost
            FROM session
            WHERE (? IS NULL OR time_updated > ?)
            ORDER BY time_updated ASC
            """,
            highWaterParameters(highWaterMark, numeric: usesNumericTimestamp)
        )

        return rows.compactMap { row in
            guard let sessionKey = row.string("id") else { return nil }
            let agent = row.string("agent")
            return ParsedAgentSession(
                sourceKind: .opencodeSQLite,
                sessionKey: sessionKey,
                projectPath: row.string("directory"),
                modelName: row.string("model"),
                cliVersion: nil,
                startedAt: parseOpenCodeDate(row, column: "time_created"),
                updatedAt: parseOpenCodeDate(row, column: "time_updated"),
                usage: ParsedSessionUsage(
                    inputTokens: row.int("tokens_input"),
                    outputTokens: row.int("tokens_output"),
                    reasoningTokens: row.int("tokens_reasoning"),
                    cacheReadTokens: row.int("tokens_cache_read"),
                    cacheWriteTokens: row.int("tokens_cache_write"),
                    costUSDMicros: row.double("cost").map(costMicros)
                ),
                usageSequence: 1,
                sourceOffset: nil,
                rawMeta: rawMeta(provider: nil, agent: agent)
            )
        }
    }

    private func changedMessageSessions(after highWaterMark: String?) throws -> [ParsedAgentSession] {
        let hasUpdatedColumn = try columnExists(table: "message", column: "time_updated")
        let rows: [SQLiteRow]
        if hasUpdatedColumn {
            let usesNumericTimestamp = try columnUsesNumericAffinity(table: "message", column: "time_updated")
            rows = try sourceDatabase.query(
                """
                SELECT id, session_id, time_updated, data
                FROM message
                WHERE (? IS NULL OR time_updated > ?)
                ORDER BY time_updated ASC, id ASC
                """,
                highWaterParameters(highWaterMark, numeric: usesNumericTimestamp)
            )
        } else {
            rows = try sourceDatabase.query(
                """
                SELECT id, session_id, json_extract(data, '$.time.created') AS time_updated, data
                FROM message
                WHERE (? IS NULL OR json_extract(data, '$.time.created') > ?)
                ORDER BY json_extract(data, '$.time.created') ASC, id ASC
                """,
                highWaterParameters(highWaterMark, numeric: true)
            )
        }

        var sessions: [ParsedAgentSession] = []
        var seenMessageIds = Set<String>()
        for row in rows {
            guard let data = row.string("data"),
                  let parsed = parseMessageRow(row: row, data: data),
                  seenMessageIds.insert(parsed.messageId).inserted else {
                continue
            }
            sessions.append(parsed.session)
        }

        return sessions.sorted { lhs, rhs in
            let lhsDate = lhs.updatedAt ?? lhs.startedAt ?? Date.distantPast
            let rhsDate = rhs.updatedAt ?? rhs.startedAt ?? Date.distantPast
            if lhsDate == rhsDate {
                return lhs.sessionKey < rhs.sessionKey
            }
            return lhsDate < rhsDate
        }
    }

    private func parseMessageRow(row: SQLiteRow, data: String) -> ParsedMessageSession? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)),
              let dictionary = object as? [String: Any] else {
            return nil
        }

        let messageId = stringValue(dictionary["id"]) ?? row.string("id")
        guard let messageId else { return nil }
        let sessionKey = stringValue(dictionary["sessionID"]) ?? row.string("session_id") ?? messageId
        let tokens = dictionary["tokens"] as? [String: Any]
        let cache = tokens?["cache"] as? [String: Any]
        let usage = ParsedSessionUsage(
            inputTokens: intValue(tokens?["input"]),
            outputTokens: intValue(tokens?["output"]),
            reasoningTokens: intValue(tokens?["reasoning"]),
            cacheReadTokens: intValue(cache?["read"]),
            cacheWriteTokens: intValue(cache?["write"]),
            costUSDMicros: doubleValue(dictionary["cost"]).map(costMicros)
        )
        guard usage.totalTokens > 0 else { return nil }

        let createdMilliseconds = doubleValue((dictionary["time"] as? [String: Any])?["created"])
        let updatedMilliseconds = row.double("time_updated") ?? createdMilliseconds
        let createdAt = createdMilliseconds.map { Date(timeIntervalSince1970: $0 / 1000) }
        let updatedAt = updatedMilliseconds.map { Date(timeIntervalSince1970: $0 / 1000) }
        let sequence = createdMilliseconds.map { Int64($0.rounded()) } ?? updatedMilliseconds.map { Int64($0.rounded()) } ?? 1
        let provider = stringValue(dictionary["providerID"])
        let model = stringValue(dictionary["modelID"])

        return ParsedMessageSession(
            messageId: messageId,
            createdMilliseconds: createdMilliseconds,
            session: ParsedAgentSession(
                sourceKind: .opencodeSQLite,
                sessionKey: sessionKey,
                projectPath: nil,
                modelName: model,
                cliVersion: nil,
                startedAt: createdAt,
                updatedAt: updatedAt,
                usage: usage,
                usageSequence: max(Int(sequence), 1),
                sourceOffset: nil,
                rawMeta: rawMeta(provider: provider, agent: "opencode")
            )
        )
    }

    private func tableExists(_ tableName: String) throws -> Bool {
        let rows = try sourceDatabase.query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
            [.text(tableName)]
        )
        return !rows.isEmpty
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

    private func rawMeta(provider: String?, agent: String?) -> [String: String] {
        var meta = ["source": "opencode"]
        if let provider, !provider.isEmpty {
            meta["provider"] = provider
        }
        if let agent, !agent.isEmpty {
            meta["agent"] = agent
        }
        return meta
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

    private func parseOpenCodeDate(_ row: SQLiteRow, column: String) -> Date? {
        if let milliseconds = row.double(column) {
            return Date(timeIntervalSince1970: milliseconds / 1000)
        }
        return parseISODate(row.string(column))
    }

    private func parseISODate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return isoFormatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private func costMicros(_ cost: Double) -> Int64 {
        Int64((cost * 1_000_000).rounded())
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

private struct ParsedMessageSession {
    let messageId: String
    let createdMilliseconds: Double?
    let session: ParsedAgentSession
}
