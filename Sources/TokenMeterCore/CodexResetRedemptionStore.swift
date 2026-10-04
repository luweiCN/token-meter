import Foundation

public final class CodexResetRedemptionStore {
    public struct Attempt {
        public let account: String
        public let credit: String
        public let key: String
        public let owner: String
    }

    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) { self.database = database }

    public func claim(account: String, credit: String, quota: String, owner: String, now: Date) throws -> Attempt? {
        try database.execute("BEGIN IMMEDIATE")
        do {
            let previous = try database.query(
                "SELECT * FROM codex_reset_redemptions WHERE account_hash = ? AND credit_hash = ?",
                [.text(account), .text(credit)]
            ).first
            let state = previous?.string("state")
            let lease = previous?.double("lease_until") ?? 0
            let updated = previous?.double("updated_at") ?? 0
            if state == "succeeded" || state == "noCredit"
                || lease > now.timeIntervalSince1970
                || (previous != nil && updated + 60 > now.timeIntervalSince1970)
                || (state == "nothingToReset" && previous?.string("quota_hash") == quota) {
                try database.execute("COMMIT")
                return nil
            }
            let key = state == "pending" ? previous?.string("idempotency_key") ?? UUID().uuidString : UUID().uuidString
            try database.execute(
                """
                INSERT INTO codex_reset_redemptions(account_hash, credit_hash, idempotency_key, state, quota_hash, owner, lease_until, updated_at)
                VALUES (?, ?, ?, 'pending', ?, ?, ?, ?)
                ON CONFLICT(account_hash, credit_hash) DO UPDATE SET
                  idempotency_key = excluded.idempotency_key, state = 'pending', quota_hash = excluded.quota_hash,
                  owner = excluded.owner, lease_until = excluded.lease_until, updated_at = excluded.updated_at
                """,
                [.text(account), .text(credit), .text(key), .text(quota), .text(owner),
                 .double(now.timeIntervalSince1970 + 120), .double(now.timeIntervalSince1970)]
            )
            try database.execute("COMMIT")
            return Attempt(account: account, credit: credit, key: key, owner: owner)
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
    }

    public func finish(_ attempt: Attempt, outcome: CodexResetOutcome?, now: Date) throws {
        let state: String
        switch outcome {
        case .reset, .alreadyRedeemed: state = "succeeded"
        case .nothingToReset: state = "nothingToReset"
        case .noCredit: state = "noCredit"
        case nil: state = "pending"
        }
        try database.execute(
            """
            UPDATE codex_reset_redemptions SET state = ?, lease_until = 0, updated_at = ?
            WHERE account_hash = ? AND credit_hash = ? AND idempotency_key = ? AND owner = ?
            """,
            [.text(state), .double(now.timeIntervalSince1970), .text(attempt.account),
             .text(attempt.credit), .text(attempt.key), .text(attempt.owner)]
        )
    }
}
