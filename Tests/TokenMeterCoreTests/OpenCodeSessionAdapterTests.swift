import XCTest
@testable import TokenMeterCore

final class OpenCodeSessionAdapterTests: XCTestCase {
    func testReadsSessionsChangedAfterHighWaterMark() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try database.execute("""
        CREATE TABLE session (
          id TEXT PRIMARY KEY,
          directory TEXT,
          model TEXT,
          agent TEXT,
          time_created TEXT,
          time_updated TEXT,
          tokens_input INTEGER,
          tokens_output INTEGER,
          tokens_reasoning INTEGER,
          tokens_cache_read INTEGER,
          tokens_cache_write INTEGER,
          cost REAL
        )
        """)
        try database.execute("""
        INSERT INTO session(id, directory, model, agent, time_created, time_updated, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, cost)
        VALUES ('s1', '/repo', 'claude-sonnet', 'build', '2026-07-03T00:00:00Z', '2026-07-03T00:10:00Z', 10, 20, 3, 4, 5, 0.012345)
        """)
        try database.execute("""
        INSERT INTO session(id, directory, model, agent, time_created, time_updated, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, cost)
        VALUES ('old', '/repo', 'claude-haiku', 'build', '2026-07-01T00:00:00Z', '2026-07-01T00:10:00Z', 1, 2, 0, 0, 0, 0.000001)
        """)

        let sessions = try OpenCodeSessionAdapter(sourceDatabase: database).changedSessions(after: "2026-07-02T00:00:00Z")

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].sourceKind, .opencodeSQLite)
        XCTAssertEqual(sessions[0].sessionKey, "s1")
        XCTAssertEqual(sessions[0].projectPath, "/repo")
        XCTAssertEqual(sessions[0].modelName, "claude-sonnet")
        XCTAssertEqual(sessions[0].startedAt, ISO8601DateFormatter().date(from: "2026-07-03T00:00:00Z"))
        XCTAssertEqual(sessions[0].updatedAt, ISO8601DateFormatter().date(from: "2026-07-03T00:10:00Z"))
        XCTAssertEqual(sessions[0].usage?.inputTokens, 10)
        XCTAssertEqual(sessions[0].usage?.outputTokens, 20)
        XCTAssertEqual(sessions[0].usage?.reasoningTokens, 3)
        XCTAssertEqual(sessions[0].usage?.cacheReadTokens, 4)
        XCTAssertEqual(sessions[0].usage?.cacheWriteTokens, 5)
        XCTAssertEqual(sessions[0].usage?.costUSDMicros, 12_345)
        XCTAssertEqual(sessions[0].usageSequence, 1)
        XCTAssertNil(sessions[0].sourceOffset)
        XCTAssertEqual(sessions[0].rawMeta, ["source": "opencode", "agent": "build"])
    }

    func testReadsCurrentMessageTableShapeWithoutPersistingContent() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try database.execute("""
        CREATE TABLE message (
          id TEXT PRIMARY KEY,
          session_id TEXT,
          data TEXT
        )
        """)
        try database.execute(
            "INSERT INTO message(id, session_id, data) VALUES (?, ?, ?)",
            [
                .text("msg-1"),
                .text("session-1"),
                .text("""
                {
                  "id": "msg-1",
                  "sessionID": "session-1",
                  "providerID": "anthropic",
                  "modelID": "claude-sonnet-4",
                  "time": { "created": 1783036800123 },
                  "tokens": {
                    "input": 15,
                    "output": 25,
                    "cache": { "read": 7, "write": 3 },
                    "total": 50
                  },
                  "cost": 0.004321,
                  "parts": [{ "type": "text", "text": "prompt text must not leak" }],
                  "content": "assistant response must not leak",
                  "tool": { "output": "tool output must not leak" }
                }
                """)
            ]
        )
        try database.execute(
            "INSERT INTO message(id, session_id, data) VALUES (?, ?, ?)",
            [
                .text("msg-zero"),
                .text("session-ignored"),
                .text("""
                {
                  "id": "msg-zero",
                  "sessionID": "session-ignored",
                  "providerID": "anthropic",
                  "modelID": "claude-haiku",
                  "time": { "created": 1783036801123 },
                  "tokens": { "input": 0, "output": 0, "cache": { "read": 0, "write": 0 } },
                  "cost": 1.0
                }
                """)
            ]
        )

        let sessions = try OpenCodeSessionAdapter(sourceDatabase: database).changedSessions(after: "1783036800000")

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].sourceKind, .opencodeSQLite)
        XCTAssertEqual(sessions[0].sessionKey, "session-1")
        XCTAssertEqual(sessions[0].modelName, "claude-sonnet-4")
        XCTAssertEqual(sessions[0].startedAt, Date(timeIntervalSince1970: 1_783_036_800.123))
        XCTAssertEqual(sessions[0].updatedAt, Date(timeIntervalSince1970: 1_783_036_800.123))
        XCTAssertEqual(sessions[0].usage?.inputTokens, 15)
        XCTAssertEqual(sessions[0].usage?.outputTokens, 25)
        XCTAssertEqual(sessions[0].usage?.reasoningTokens, nil)
        XCTAssertEqual(sessions[0].usage?.cacheReadTokens, 7)
        XCTAssertEqual(sessions[0].usage?.cacheWriteTokens, 3)
        XCTAssertEqual(sessions[0].usage?.costUSDMicros, 4_321)
        XCTAssertEqual(sessions[0].usageSequence, 1_783_036_800_123)
        XCTAssertNil(sessions[0].sourceOffset)
        XCTAssertEqual(sessions[0].rawMeta, ["source": "opencode", "provider": "anthropic", "agent": "opencode"])
        XCTAssertFalse(sessions[0].rawMeta.values.contains { value in
            value.contains("prompt text") || value.contains("assistant response") || value.contains("tool output")
        })
    }

    func testPrefersMessageTableWhenBothTablesHaveSameSession() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try database.execute("""
        CREATE TABLE session (
          id TEXT PRIMARY KEY,
          directory TEXT,
          model TEXT,
          agent TEXT,
          time_created TEXT,
          time_updated TEXT,
          tokens_input INTEGER,
          tokens_output INTEGER,
          tokens_reasoning INTEGER,
          tokens_cache_read INTEGER,
          tokens_cache_write INTEGER,
          cost REAL
        )
        """)
        try database.execute("""
        CREATE TABLE message (
          id TEXT PRIMARY KEY,
          session_id TEXT,
          data TEXT
        )
        """)
        try database.execute("""
        INSERT INTO session(id, directory, model, agent, time_created, time_updated, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, cost)
        VALUES ('session-1', '/legacy', 'legacy-model', 'legacy-agent', '2026-07-03T00:00:00Z', '2026-07-03T00:05:00Z', 1, 2, 3, 4, 5, 0.000001)
        """)
        try database.execute(
            "INSERT INTO message(id, session_id, data) VALUES (?, ?, ?)",
            [
                .text("msg-1"),
                .text("session-1"),
                .text("""
                {
                  "sessionID": "session-1",
                  "providerID": "anthropic",
                  "modelID": "message-model",
                  "time": { "created": 1783036800123 },
                  "tokens": { "input": 100, "output": 200, "cache": { "read": 30, "write": 40 } },
                  "cost": 0.123456
                }
                """)
            ]
        )

        let sessions = try OpenCodeSessionAdapter(sourceDatabase: database).changedSessions(after: nil)

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].sessionKey, "session-1")
        XCTAssertEqual(sessions[0].modelName, "message-model")
        XCTAssertEqual(sessions[0].usage?.inputTokens, 100)
        XCTAssertEqual(sessions[0].usage?.outputTokens, 200)
        XCTAssertEqual(sessions[0].usage?.cacheReadTokens, 30)
        XCTAssertEqual(sessions[0].usage?.cacheWriteTokens, 40)
        XCTAssertEqual(sessions[0].usage?.costUSDMicros, 123_456)
        XCTAssertEqual(sessions[0].rawMeta, ["source": "opencode", "provider": "anthropic", "agent": "opencode"])
    }
}
