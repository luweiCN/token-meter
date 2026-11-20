/// 各来源在写入时已将普通输入与缓存读写拆开。命中率按已记录的输入 Token 加权。
package struct PromptCacheUsage: Equatable {
    package let readTokens: Int64
    package let inputTokens: Int64

    static let aggregateColumns = """
        sum(tokens_cache_read) AS cacheReadTokens,
        sum(tokens_input + tokens_cache_read + tokens_cache_write_5m + tokens_cache_write_1h) AS promptTokens
        """

    package init(readTokens: Int64 = 0, inputTokens: Int64 = 0) {
        self.readTokens = readTokens
        self.inputTokens = inputTokens
    }

    init(row: SQLiteRow) {
        self.init(readTokens: row.int("cacheReadTokens") ?? 0, inputTokens: row.int("promptTokens") ?? 0)
    }

    package var hitRate: Double? {
        guard inputTokens > 0 else { return nil }
        return Double(readTokens) / Double(inputTokens)
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(readTokens: lhs.readTokens + rhs.readTokens, inputTokens: lhs.inputTokens + rhs.inputTokens)
    }
}
