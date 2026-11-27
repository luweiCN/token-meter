import Foundation

extension AntigravityCLIUsage {
    package static func topLevelSessionCount(_ sessions: [(sessionKey: String, scanRootPath: String)]) -> Int? {
        var total = 0
        for (root, records) in Dictionary(grouping: sessions, by: \.scanRootPath) {
            guard (root as NSString).isAbsolutePath else { return nil }
            let profile = URL(fileURLWithPath: root, isDirectory: true).deletingLastPathComponent()
            let keys = Set(records.map(\.sessionKey))
            guard let count = try? topLevelSessionCount(keys, profile: profile) else { return nil }
            total += count
        }
        return total
    }

    private static func topLevelSessionCount(_ keys: Set<String>, profile: URL) throws -> Int? {
        let metadata = profile.appendingPathComponent("cache/conversation_metadata.json")
        let entries = (try? JSONDecoder().decode(ConversationCache.self, from: Data(contentsOf: metadata)))?.conversations
        let candidates = keys.filter { entries?[$0]?.isInternal != true }
        guard !candidates.isEmpty else { return 0 }

        // 日期和用量都由账本提供。只查当天键对应的官方摘要，正文和逐会话数据库均无需打开。
        let database = try SQLiteDatabase(path: profile.appendingPathComponent("conversation_summaries.db").path, readOnly: true)
        defer { try? database.close() }
        let hasParents = try !database.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'conversation_parents'").isEmpty
        let parentColumn = hasParents ? "p.parent_id" : "NULL"
        let parentJoin = hasParents ? "LEFT JOIN conversation_parents p ON p.conversation_id = active.value" : ""
        let request = String(decoding: try JSONEncoder().encode(candidates), as: UTF8.self)
        let rows = try database.query(
            """
            SELECT active.value AS id, s.parent_conversation_id AS parent, s.nesting_depth AS depth,
                   \(parentColumn) AS indexed_parent
              FROM json_each(?) active
              LEFT JOIN conversation_summaries s ON s.conversation_id = active.value
              \(parentJoin)
            """,
            [.text(request)]
        )

        var count = 0
        for row in rows {
            guard let id = row.string("id") else { return nil }
            let depth = row.int("depth")
            let parent = row.string("parent")
            let indexedParent = row.string("indexed_parent")
            if depth.map({ $0 > 0 }) == true || parent?.isEmpty == false || indexedParent?.isEmpty == false { continue }
            guard entries?[id]?.isInternal == false, depth == 0, parent == "" else { return nil }
            count += 1
        }
        return count
    }
}

private struct ConversationCache: Decodable {
    let conversations: [String: Entry]

    struct Entry: Decodable {
        let isInternal: Bool?

        private enum CodingKeys: String, CodingKey { case isInternal = "is_internal", summary }
        private enum SummaryKeys: String, CodingKey { case isInternal = "Internal" }

        init(from decoder: Decoder) {
            let fields = try? decoder.container(keyedBy: CodingKeys.self)
            let summary = try? fields?.nestedContainer(keyedBy: SummaryKeys.self, forKey: .summary)
            let summaryFlag = try? summary?.decode(Bool.self, forKey: .isInternal)
            if fields?.contains(.isInternal) == true {
                let flag = try? fields?.decode(Bool.self, forKey: .isInternal)
                isInternal = summaryFlag == nil || summaryFlag == flag ? flag : nil
            } else {
                isInternal = summaryFlag
            }
        }
    }
}
