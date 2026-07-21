import Foundation

/// OpenCode 的 SQLite 适配器。每次检测到变化后读取一份完整快照：数据库只有万级消息，
/// 全库裁决能正确处理 fork 复制、跨表重叠与删除，避免“只看本轮 changed session”遗漏旧父历史。
public final class OpenCodeUsageEventAdapter {
    private let sourceDatabase: SQLiteDatabase
    private let isoFormatter = ISO8601DateFormatter()

    public init(sourceDatabase: SQLiteDatabase) {
        self.sourceDatabase = sourceDatabase
    }

    public func changedSessions(after highWaterMark: String?) throws -> [ParsedSession] {
        let hasV1 = try tableExists("message")
        let hasV2 = try tableExists("session_message")
        guard hasV1 || hasV2 else { return [] }
        if let highWaterMark,
           try !hasRowsChanged(after: highWaterMark, hasV1: hasV1, hasV2: hasV2) {
            return []
        }
        return try allSessions(hasV1: hasV1, hasV2: hasV2)
    }

    /// 无条件读取当前完整快照。由 scanner 在 SQLite 文件指纹变化、上次扫描未完成，或首次扫描时调用；
    /// 这样即使变化是 DELETE（没有任何新 high-water row），也能清掉派生库里的旧事件。
    func snapshot() throws -> [ParsedSession] {
        let hasV1 = try tableExists("message")
        let hasV2 = try tableExists("session_message")
        guard hasV1 || hasV2 else { return [] }
        return try allSessions(hasV1: hasV1, hasV2: hasV2)
    }

    private func allSessions(hasV1: Bool, hasV2: Bool) throws -> [ParsedSession] {
        let directories = try sessionDirectories()
        let attribution = try sessionAttribution()
        var candidates: [OpenCodeCandidate] = []

        if hasV1 {
            for row in try messageRows(table: "message", assistantTypeColumn: false) {
                if let parsed = parseMessageRow(row: row, forcedAssistant: false) {
                    candidates.append(candidate(parsed, attribution: attribution))
                }
            }
        }
        if hasV2 {
            for row in try messageRows(table: "session_message", assistantTypeColumn: true) {
                if let parsed = parseMessageRow(row: row, forcedAssistant: true) {
                    candidates.append(candidate(parsed, attribution: attribution))
                }
            }
        }

        // 根会话优先，随后用时间/session/row id 建立稳定顺序；fork copy 与父记录碰撞时保留父记录。
        candidates.sort {
            let lhsIsRoot = $0.rootSessionKey == nil
            let rhsIsRoot = $1.rootSessionKey == nil
            if lhsIsRoot != rhsIsRoot { return lhsIsRoot }
            if $0.parsed.createdMilliseconds != $1.parsed.createdMilliseconds {
                return $0.parsed.createdMilliseconds < $1.parsed.createdMilliseconds
            }
            if $0.parsed.sessionKey != $1.parsed.sessionKey {
                return $0.parsed.sessionKey < $1.parsed.sessionKey
            }
            return $0.parsed.rowID < $1.parsed.rowID
        }

        var retained: [OpenCodeCandidate] = []
        var buckets: [OpenCodeFingerprintIdentity: [Int]] = [:]
        for candidate in candidates {
            let identity = OpenCodeFingerprintIdentity(
                scope: candidate.dedupeScopeKey,
                fingerprint: candidate.parsed.fingerprint
            )
            let duplicateIndex = buckets[identity, default: []].first { index in
                shouldMergeMessageIDs(
                    retained[index].effectiveEmbeddedMessageID,
                    candidate.parsed.embeddedMessageID
                )
            }
            if let duplicateIndex {
                // 与 Tokscale 相同：无 id 的副本先与第一个具体 id 合并后，要把该 id 提升为
                // 槽位身份；否则另一个不同 id 也会继续和 nil 匹配，被错误吞掉。
                if retained[duplicateIndex].effectiveEmbeddedMessageID == nil,
                   let embeddedMessageID = candidate.parsed.embeddedMessageID {
                    retained[duplicateIndex].effectiveEmbeddedMessageID = embeddedMessageID
                }
                continue
            }
            buckets[identity, default: []].append(retained.count)
            retained.append(candidate)
        }

        var eventsBySession: [String: [OpenCodeCandidate]] = [:]
        for candidate in retained {
            eventsBySession[candidate.parsed.sessionKey, default: []].append(candidate)
        }

        var sessions: [ParsedSession] = []
        for sessionKey in eventsBySession.keys.sorted() {
            guard let sessionCandidates = eventsBySession[sessionKey] else { continue }
            let ordered = sessionCandidates.sorted {
                if $0.parsed.createdMilliseconds == $1.parsed.createdMilliseconds {
                    return $0.parsed.messageID < $1.parsed.messageID
                }
                return $0.parsed.createdMilliseconds < $1.parsed.createdMilliseconds
            }
            var events: [UsageEvent] = []
            events.reserveCapacity(ordered.count)
            for (index, candidate) in ordered.enumerated() {
                let parsed = candidate.parsed
                let sequence = index + 1
                events.append(
                    UsageEvent(
                        eventSeq: sequence,
                        observedAt: parsed.observedAt,
                        modelName: parsed.modelName,
                        messageId: candidate.effectiveEmbeddedMessageID ?? parsed.messageID,
                        dedupeKey: parsed.persistentDedupeKey(
                            embeddedMessageID: candidate.effectiveEmbeddedMessageID
                        ),
                        dedupeScopeKey: candidate.dedupeScopeKey,
                        inputTokens: parsed.inputTokens,
                        // OpenCode 的 output 不含 reasoning；在边界处归一为完整输出。
                        outputTokens: saturatingAdd(parsed.outputTokens, parsed.reasoningTokens),
                        reasoningTokens: parsed.reasoningTokens,
                        cacheReadTokens: parsed.cacheReadTokens,
                        cacheWrite5mTokens: parsed.cacheWriteTokens,
                        cacheWrite1hTokens: 0,
                        reportedCostUSDMicros: parsed.reportedCostUSDMicros,
                        sourceOffset: Int64(sequence),
                        isSidechain: candidate.rootSessionKey != nil
                    )
                )
            }

            guard let first = events.first, let last = events.last else { continue }
            let firstCandidate = ordered[0]
            let provider = ordered.compactMap { $0.parsed.provider }.first
            sessions.append(
                ParsedSession(
                    sourceKind: .opencodeSQLite,
                    sessionKey: sessionKey,
                    projectPath: directories[sessionKey],
                    cliVersion: nil,
                    startedAt: first.observedAt,
                    updatedAt: last.observedAt,
                    events: events,
                    rawMeta: rawMeta(provider: provider),
                    rootSessionKey: firstCandidate.rootSessionKey,
                    subagentLabel: attribution[sessionKey]?.agent
                )
            )
        }
        return sessions
    }

    private func candidate(
        _ parsed: ParsedOpenCodeMessage,
        attribution: [String: OpenCodeAttribution]
    ) -> OpenCodeCandidate {
        let root = ultimateRoot(for: parsed.sessionKey, attribution: attribution)
        return OpenCodeCandidate(
            parsed: parsed,
            rootSessionKey: root,
            // OpenCode 的 fork 关系可能已被清理或并未写入 session.parent_id；Tokscale 因此
            // 在整个 OpenCode 源内按「完整计费指纹 + embedded message id」裁决复制历史。
            // embedded id 不同时 shouldMergeMessageIDs 会保留两条，故全局 scope 不会吞掉
            // 仅仅恰好拥有相同 token 数值的真实不同消息。
            dedupeScopeKey: "opencode",
            effectiveEmbeddedMessageID: parsed.embeddedMessageID
        )
    }

    private func parseMessageRow(row: SQLiteRow, forcedAssistant: Bool) -> ParsedOpenCodeMessage? {
        guard let data = row.string("data"),
              let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)),
              let dictionary = object as? [String: Any],
              let rowID = row.string("row_id") else { return nil }

        if !forcedAssistant, stringValue(dictionary["role"]) != "assistant" {
            return nil
        }

        let embeddedMessageID = stringValue(dictionary["id"])
        let messageID = embeddedMessageID ?? rowID
        let sessionKey = stringValue(dictionary["sessionID"])
            ?? row.string("session_id")
            ?? messageID
        let nestedModel = dictionary["model"] as? [String: Any]
        let modelName = stringValue(dictionary["modelID"])
            ?? stringValue(nestedModel?["id"])
        let provider = stringValue(dictionary["providerID"])
            ?? stringValue(nestedModel?["providerID"])

        guard let tokens = dictionary["tokens"] as? [String: Any] else { return nil }
        let cache = tokens["cache"] as? [String: Any]
        let inputTokens = max(0, intValue(tokens["input"]) ?? 0)
        let outputTokens = max(0, intValue(tokens["output"]) ?? 0)
        let reasoningTokens = max(0, intValue(tokens["reasoning"]) ?? 0)
        let cacheReadTokens = max(0, intValue(cache?["read"]) ?? 0)
        let cacheWriteTokens = max(0, intValue(cache?["write"]) ?? 0)
        guard inputTokens > 0 || outputTokens > 0 || reasoningTokens > 0
                || cacheReadTokens > 0 || cacheWriteTokens > 0 else { return nil }

        let time = dictionary["time"] as? [String: Any]
        let createdMilliseconds = doubleValue(time?["created"])
            ?? row.double("row_created")
            ?? row.double("row_updated")
            ?? 0
        let completedMilliseconds = doubleValue(time?["completed"]).map {
            Int64($0.rounded())
        }
        let observedAt = Date(timeIntervalSince1970: createdMilliseconds / 1_000)

        let reportedCostUSDMicros: Int64?
        if let cost = doubleValue(dictionary["cost"]), cost.isFinite, cost > 0 {
            reportedCostUSDMicros = Int64((cost * 1_000_000).rounded())
        } else {
            reportedCostUSDMicros = nil
        }
        let agent = stringValue(dictionary["mode"]) ?? stringValue(dictionary["agent"])
        let fingerprint = OpenCodeFingerprint(
            createdMilliseconds: Int64(createdMilliseconds.rounded()),
            completedMilliseconds: completedMilliseconds,
            modelName: modelName ?? "unknown",
            provider: provider ?? "unknown",
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            reportedCostUSDMicros: reportedCostUSDMicros ?? 0,
            agent: agent
        )

        return ParsedOpenCodeMessage(
            rowID: rowID,
            embeddedMessageID: embeddedMessageID,
            messageID: messageID,
            sessionKey: sessionKey,
            createdMilliseconds: createdMilliseconds,
            observedAt: observedAt,
            modelName: modelName,
            provider: provider,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            reportedCostUSDMicros: reportedCostUSDMicros,
            fingerprint: fingerprint
        )
    }

    private func shouldMergeMessageIDs(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case let (.some(lhs), .some(rhs)): return lhs == rhs
        case (.none, _), (_, .none): return true
        }
    }

    private func ultimateRoot(
        for sessionKey: String,
        attribution: [String: OpenCodeAttribution]
    ) -> String? {
        var current = sessionKey
        var root: String?
        var visited: Set<String> = [sessionKey]
        while let parent = attribution[current]?.parent,
              !parent.isEmpty,
              visited.insert(parent).inserted {
            root = parent
            current = parent
        }
        return root
    }

    private func hasRowsChanged(after highWaterMark: String, hasV1: Bool, hasV2: Bool) throws -> Bool {
        if hasV1, try tableHasRowsChanged("message", after: highWaterMark) { return true }
        if hasV2, try tableHasRowsChanged("session_message", after: highWaterMark) { return true }
        return false
    }

    private func tableHasRowsChanged(_ table: String, after highWaterMark: String) throws -> Bool {
        let hasUpdated = try columnExists(table: table, column: "time_updated")
        let expression = hasUpdated ? "time_updated" : "json_extract(data, '$.time.created')"
        let numeric = hasUpdated
            ? try columnUsesNumericAffinity(table: table, column: "time_updated")
            : true
        let parameters = highWaterParameters(highWaterMark, numeric: numeric)
        return try !sourceDatabase.query(
            "SELECT 1 AS changed FROM \(table) WHERE \(expression) > ? LIMIT 1",
            [parameters[1]]
        ).isEmpty
    }

    private func messageRows(table: String, assistantTypeColumn: Bool) throws -> [SQLiteRow] {
        let createdExpression = try columnExists(table: table, column: "time_created")
            ? "time_created"
            : "json_extract(data, '$.time.created')"
        let updatedExpression = try columnExists(table: table, column: "time_updated")
            ? "time_updated"
            : "json_extract(data, '$.time.created')"
        let typeFilter = assistantTypeColumn ? "WHERE type = 'assistant'" : ""
        return try sourceDatabase.query(
            """
            SELECT id AS row_id, session_id, \(createdExpression) AS row_created,
                   \(updatedExpression) AS row_updated, data
            FROM \(table)
            \(typeFilter)
            ORDER BY session_id, \(createdExpression), id
            """
        )
    }

    private func sessionDirectories() throws -> [String: String] {
        guard try tableExists("session"),
              try columnExists(table: "session", column: "directory") else { return [:] }
        var directories: [String: String] = [:]
        for row in try sourceDatabase.query("SELECT id, directory FROM session") {
            if let id = row.string("id"), let directory = row.string("directory"), !directory.isEmpty {
                directories[id] = directory
            }
        }
        return directories
    }

    private func sessionAttribution() throws -> [String: OpenCodeAttribution] {
        guard try tableExists("session") else { return [:] }
        let hasParent = try columnExists(table: "session", column: "parent_id")
        let hasAgent = try columnExists(table: "session", column: "agent")
        guard hasParent || hasAgent else { return [:] }
        let rows = try sourceDatabase.query(
            "SELECT id, \(hasParent ? "parent_id" : "NULL AS parent_id"), \(hasAgent ? "agent" : "NULL AS agent") FROM session"
        )
        var result: [String: OpenCodeAttribution] = [:]
        for row in rows {
            guard let id = row.string("id") else { continue }
            result[id] = OpenCodeAttribution(parent: row.string("parent_id"), agent: row.string("agent"))
        }
        return result
    }

    private func rawMeta(provider: String?) -> [String: String] {
        var meta = ["source": "opencode"]
        if let provider, !provider.isEmpty { meta["provider"] = provider }
        return meta
    }

    private func tableExists(_ tableName: String) throws -> Bool {
        try !sourceDatabase.query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
            [.text(tableName)]
        ).isEmpty
    }

    private func columnExists(table: String, column: String) throws -> Bool {
        try columnType(table: table, column: column) != nil
    }

    private func columnUsesNumericAffinity(table: String, column: String) throws -> Bool {
        guard let type = try columnType(table: table, column: column)?.uppercased() else { return false }
        return type.contains("INT") || type.contains("REAL") || type.contains("FLOA")
            || type.contains("DOUB") || type.contains("NUM")
    }

    private func columnType(table: String, column: String) throws -> String? {
        try sourceDatabase.query("PRAGMA table_info(\(table))")
            .first { $0.string("name") == column }?
            .string("type")
    }

    private func highWaterParameters(_ highWaterMark: String, numeric: Bool) -> [SQLiteValue] {
        if numeric {
            let milliseconds = highWaterMilliseconds(highWaterMark) ?? 0
            return [.double(milliseconds), .double(milliseconds)]
        }
        return [.text(highWaterMark), .text(highWaterMark)]
    }

    private func highWaterMilliseconds(_ highWaterMark: String) -> Double? {
        if let milliseconds = Double(highWaterMark) { return milliseconds }
        return parseISODate(highWaterMark).map { $0.timeIntervalSince1970 * 1_000 }
    }

    private func parseISODate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? isoFormatter.date(from: value)
    }

    private func intValue(_ value: Any?) -> Int64? {
        switch value {
        case let number as NSNumber: return number.int64Value
        case let string as String: return Int64(string)
        default: return nil
        }
    }

    private func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string)
        default: return nil
        }
    }

    private func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    private func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int64.max : result.partialValue
    }
}

private struct OpenCodeAttribution {
    let parent: String?
    let agent: String?
}

private struct OpenCodeCandidate {
    let parsed: ParsedOpenCodeMessage
    let rootSessionKey: String?
    let dedupeScopeKey: String
    var effectiveEmbeddedMessageID: String?
}

private struct OpenCodeFingerprintIdentity: Hashable {
    let scope: String
    let fingerprint: OpenCodeFingerprint
}

private struct OpenCodeFingerprint: Hashable {
    let createdMilliseconds: Int64
    let completedMilliseconds: Int64?
    let modelName: String
    let provider: String
    let inputTokens: Int64
    let outputTokens: Int64
    let reasoningTokens: Int64
    let cacheReadTokens: Int64
    let cacheWriteTokens: Int64
    let reportedCostUSDMicros: Int64
    let agent: String?

    var stableKey: String {
        [
            "fingerprint", String(createdMilliseconds), completedMilliseconds.map(String.init) ?? "",
            modelName, provider, String(inputTokens), String(outputTokens), String(reasoningTokens),
            String(cacheReadTokens), String(cacheWriteTokens), String(reportedCostUSDMicros), agent ?? ""
        ].joined(separator: "\u{1F}")
    }
}

private struct ParsedOpenCodeMessage {
    let rowID: String
    let embeddedMessageID: String?
    let messageID: String
    let sessionKey: String
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
    let fingerprint: OpenCodeFingerprint

    func persistentDedupeKey(embeddedMessageID: String?) -> String {
        if let embeddedMessageID {
            return fingerprint.stableKey + "\u{1F}id:" + embeddedMessageID
        }
        return fingerprint.stableKey + "\u{1F}no-id"
    }
}
