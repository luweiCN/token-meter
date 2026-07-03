public struct MenuBarTokenSummary: Equatable {
    public let providerId: String
    public let modelName: String?
    public let totalTokens: Int64

    public init(providerId: String, modelName: String?, totalTokens: Int64) {
        self.providerId = providerId
        self.modelName = modelName
        self.totalTokens = totalTokens
    }
}

public final class MenuBarSummaryRepository {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    public func primarySummary(providerId: String) throws -> MenuBarTokenSummary? {
        let rows = try database.query(
            """
            SELECT s.provider_id, s.model_name, u.tokens_total
            FROM agent_sessions s
            JOIN session_usage_latest latest ON latest.session_id = s.id
            JOIN session_usage u ON u.id = latest.session_usage_id
            WHERE s.provider_id = ? AND s.status = 'active'
            ORDER BY u.observed_at DESC, s.session_updated_at DESC, u.id DESC
            LIMIT 1
            """,
            [.text(providerId)]
        )
        guard let row = rows.first else { return nil }
        return MenuBarTokenSummary(
            providerId: row.string("provider_id") ?? providerId,
            modelName: row.string("model_name"),
            totalTokens: row.int("tokens_total") ?? 0
        )
    }
}
