import XCTest
@testable import TokenMeterCore

final class LocalAgentScannerTests: XCTestCase {
    func testScansCodexJSONLOnceThenSkipsUnchangedFile() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rollout.jsonl")
        try writeJSONL(codexJSONL(inputTokens: 1, outputTokens: 2), to: file)
        let database = try migratedDatabase(rootKind: .codexJSONL, rootPath: directory.path)

        let scanner = LocalAgentScanner(database: database)
        try await scanner.scanRoot(id: 1)
        try await scanner.scanRoot(id: 1)

        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM agent_sessions"), 1)
        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM source_files"), 1)
        XCTAssertEqual(try scalarInt(database, "SELECT files_seen AS value FROM scan_runs ORDER BY id DESC LIMIT 1"), 1)
        XCTAssertEqual(try scalarInt(database, "SELECT files_changed AS value FROM scan_runs ORDER BY id DESC LIMIT 1"), 0)
    }

    func testRescansAppendedJSONLAndUpdatesLatestUsageForSameSession() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rollout.jsonl")
        try writeJSONL(codexJSONL(inputTokens: 1, outputTokens: 2), to: file)
        let database = try migratedDatabase(rootKind: .codexJSONL, rootPath: directory.path)
        let scanner = LocalAgentScanner(database: database)

        try await scanner.scanRoot(id: 1)
        try appendJSONL(#"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":3,"output_tokens":4}}}}"#, to: file)
        try await scanner.scanRoot(id: 1)

        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM agent_sessions"), 1)
        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM session_usage"), 2)
        XCTAssertEqual(try scalarInt(database, latestTotalTokensSQL), 7)
        XCTAssertEqual(try scalarInt(database, "SELECT files_changed AS value FROM scan_runs ORDER BY id DESC LIMIT 1"), 1)
    }

    func testJSONLScannerDispatchesClaudeAndOmpParsersBySourceKind() async throws {
        let cases: [(kind: SourceKind, fileName: String, fixture: String, expectedProvider: String, expectedSession: String, expectedTotal: Int64)] = [
            (
                .claudeJSONL,
                "claude.jsonl",
                #"{"type":"summary","summary":"Do not store this","leafUuid":"claude-session-1"}"# + "\n" +
                    #"{"sessionId":"claude-session-1","cwd":"/repo","timestamp":"2026-07-03T02:00:00Z","version":"1.2.3","type":"assistant","requestId":"req-1","message":{"id":"msg-1","model":"claude-sonnet","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":3,"cache_creation_input_tokens":4},"content":[{"type":"text","text":"SECRET_RESPONSE"}]}}"# + "\n",
                "claude-code",
                "claude-session-1",
                37
            ),
            (
                .ompJSONL,
                "omp.jsonl",
                #"{"type":"session","id":"omp-session-1","cwd":"/repo","timestamp":"2026-07-03T03:00:00Z"}"# + "\n" +
                    #"{"type":"model_change","model":"gpt-5.5","timestamp":"2026-07-03T03:01:00Z"}"# + "\n" +
                    #"{"type":"message","timestamp":"2026-07-03T03:02:00Z","message":{"role":"assistant","content":"SECRET_OMP_RESPONSE","usage":{"inputTokens":11,"outputTokens":22,"reasoningTokens":1,"cacheReadTokens":5,"cacheWriteTokens":6,"totalTokens":45}}}"# + "\n",
                "omp",
                "omp-session-1",
                45
            )
        ]

        for testCase in cases {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try Data(testCase.fixture.utf8).write(to: directory.appendingPathComponent(testCase.fileName))
            let database = try migratedDatabase(rootKind: testCase.kind, rootPath: directory.path)

            try await LocalAgentScanner(database: database).scanRoot(id: 1)

            let rows = try database.query("SELECT source_kind, source_session_key, provider_id, raw_meta_json FROM agent_sessions")
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows[0].string("source_kind"), testCase.kind.rawValue)
            XCTAssertEqual(rows[0].string("source_session_key"), testCase.expectedSession)
            XCTAssertEqual(rows[0].string("provider_id"), testCase.expectedProvider)
            XCTAssertEqual(try scalarInt(database, latestTotalTokensSQL), testCase.expectedTotal)
            let rawMetadata = try XCTUnwrap(rows[0].string("raw_meta_json"))
            XCTAssertFalse(rawMetadata.contains("SECRET"))
            XCTAssertFalse(rawMetadata.contains("Do not store"))
        }
    }

    func testScansOpenCodeSQLiteRootAndStoresHighWaterCursor() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let openCodeURL = directory.appendingPathComponent("opencode.db")
        let sourceDatabase = try SQLiteDatabase(path: openCodeURL.path)
        try sourceDatabase.execute("""
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
        try sourceDatabase.execute(
            """
            INSERT INTO session(id, directory, model, agent, time_created, time_updated, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, cost)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text("opencode-session-1"),
                .text("/repo"),
                .text("claude-sonnet"),
                .text("build"),
                .text("2026-07-03T00:00:00Z"),
                .text("2026-07-03T00:10:00Z"),
                .int(10),
                .int(20),
                .int(3),
                .int(4),
                .int(5),
                .double(0.012345)
            ]
        )
        try sourceDatabase.close()
        let database = try migratedDatabase(rootKind: .opencodeSQLite, rootPath: openCodeURL.path)
        let scanner = LocalAgentScanner(database: database)

        try await scanner.scanRoot(id: 1)
        try await scanner.scanRoot(id: 1)

        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM agent_sessions"), 1)
        XCTAssertEqual(try scalarInt(database, latestTotalTokensSQL), 42)
        XCTAssertEqual(try database.query("SELECT last_successful_cursor FROM scan_roots WHERE id = 1")[0].string("last_successful_cursor"), "2026-07-03T00:10:00Z")
        XCTAssertEqual(try scalarInt(database, "SELECT files_changed AS value FROM scan_runs ORDER BY id DESC LIMIT 1"), 0)
    }

    func testFailedOpenCodeDatabaseDoesNotMarkSourceFileParsed() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let openCodeURL = directory.appendingPathComponent("opencode.db")
        try Data("not a sqlite database".utf8).write(to: openCodeURL)
        let database = try migratedDatabase(rootKind: .opencodeSQLite, rootPath: openCodeURL.path)

        do {
            try await LocalAgentScanner(database: database).scanRoot(id: 1)
            XCTFail("Expected corrupt OpenCode database to fail the scan")
        } catch {
            let sourceFile = try database.query("SELECT parse_status, parse_error, last_parsed_run_id FROM source_files LIMIT 1")[0]
            XCTAssertEqual(sourceFile.string("parse_status"), "failed")
            XCTAssertEqual(sourceFile.string("parse_error"), "database operation failed")
            XCTAssertNil(sourceFile.int("last_parsed_run_id"))

            let run = try database.query("SELECT status, files_seen, files_changed FROM scan_runs ORDER BY id DESC LIMIT 1")[0]
            XCTAssertEqual(run.string("status"), "partial")
            XCTAssertEqual(run.int("files_seen"), 1)
            XCTAssertEqual(run.int("files_changed"), 1)
        }
    }

    func testOpenCodeHighWaterCursorPreservesMilliseconds() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let openCodeURL = directory.appendingPathComponent("opencode.db")
        let sourceDatabase = try SQLiteDatabase(path: openCodeURL.path)
        try sourceDatabase.execute("""
        CREATE TABLE message (
          id TEXT PRIMARY KEY,
          session_id TEXT,
          data TEXT
        )
        """)
        try sourceDatabase.execute(
            "INSERT INTO message(id, session_id, data) VALUES (?, ?, ?)",
            [
                .text("msg-1"),
                .text("opencode-session-ms"),
                .text("""
                {
                  "id": "msg-1",
                  "sessionID": "opencode-session-ms",
                  "providerID": "anthropic",
                  "modelID": "claude-sonnet",
                  "time": { "created": 1783036800123 },
                  "tokens": { "input": 10, "output": 20, "cache": { "read": 3, "write": 4 } },
                  "cost": 0.001
                }
                """)
            ]
        )
        try sourceDatabase.close()
        let database = try migratedDatabase(rootKind: .opencodeSQLite, rootPath: openCodeURL.path)
        let scanner = LocalAgentScanner(database: database)

        try await scanner.scanRoot(id: 1)
        XCTAssertEqual(try database.query("SELECT last_successful_cursor FROM scan_roots WHERE id = 1")[0].string("last_successful_cursor"), "2026-07-03T00:00:00.123Z")

        try await scanner.scanRoot(id: 1)

        XCTAssertEqual(try scalarInt(database, "SELECT files_changed AS value FROM scan_runs ORDER BY id DESC LIMIT 1"), 0)
    }

    func testScanFailureRecordsPartialFileProgress() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeJSONL(codexJSONL(inputTokens: 1, outputTokens: 2), to: directory.appendingPathComponent("a-valid.jsonl"))
        let blockedFile = directory.appendingPathComponent("z-blocked.jsonl")
        try writeJSONL(codexJSONL(inputTokens: 3, outputTokens: 4), to: blockedFile)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blockedFile.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: blockedFile.path) }
        let database = try migratedDatabase(rootKind: .codexJSONL, rootPath: directory.path)

        do {
            try await LocalAgentScanner(database: database).scanRoot(id: 1)
            XCTFail("Expected unreadable JSONL file to fail the scan")
        } catch {
            let run = try database.query("SELECT status, files_seen, files_changed FROM scan_runs ORDER BY id DESC LIMIT 1")[0]
            XCTAssertEqual(run.string("status"), "partial")
            XCTAssertEqual(run.int("files_seen"), 2)
            XCTAssertEqual(run.int("files_changed"), 2)
        }
    }

    func testScanFailureDoesNotPersistSensitivePathTextInErrors() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blockedFile = directory.appendingPathComponent("SECRET_PROMPT.jsonl")
        try writeJSONL(codexJSONL(inputTokens: 1, outputTokens: 2), to: blockedFile)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blockedFile.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: blockedFile.path) }
        let database = try migratedDatabase(rootKind: .codexJSONL, rootPath: directory.path)

        do {
            try await LocalAgentScanner(database: database).scanRoot(id: 1)
            XCTFail("Expected unreadable JSONL file to fail the scan")
        } catch {
            let errorText = try [
                database.query("SELECT parse_error AS value FROM source_files LIMIT 1").first?.string("value"),
                database.query("SELECT error_summary AS value FROM scan_runs ORDER BY id DESC LIMIT 1").first?.string("value"),
                database.query("SELECT last_error AS value FROM scan_roots WHERE id = 1").first?.string("value")
            ].compactMap { $0 }.joined(separator: "\n")
            XCTAssertFalse(errorText.contains("SECRET_PROMPT"))
            XCTAssertFalse(errorText.contains("/"))
        }
    }

    func testFailedJSONLFileIsRetriedWhenUnchangedAfterPermissionRecovers() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blockedFile = directory.appendingPathComponent("retry.jsonl")
        try writeJSONL(codexJSONL(inputTokens: 8, outputTokens: 13), to: blockedFile)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blockedFile.path)
        let database = try migratedDatabase(rootKind: .codexJSONL, rootPath: directory.path)
        let scanner = LocalAgentScanner(database: database)

        do {
            try await scanner.scanRoot(id: 1)
            XCTFail("Expected unreadable JSONL file to fail the scan")
        } catch {}

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: blockedFile.path)
        try await scanner.scanRoot(id: 1)

        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM agent_sessions"), 1)
        XCTAssertEqual(try scalarInt(database, latestTotalTokensSQL), 21)
        XCTAssertEqual(try database.query("SELECT parse_status FROM source_files LIMIT 1")[0].string("parse_status"), "ok")
        XCTAssertEqual(try scalarInt(database, "SELECT files_changed AS value FROM scan_runs ORDER BY id DESC LIMIT 1"), 1)
    }

    func testSeedsDefaultScanRootsFromHomeDirectory() throws {
        let homeDirectory = URL(fileURLWithPath: "/tmp/token-meter-home", isDirectory: true)
        let roots = TokenMeterPaths.defaultScanRoots(homeDirectory: homeDirectory)

        XCTAssertEqual(roots.map(\.kind), [.claudeJSONL, .codexJSONL, .opencodeSQLite, .ompJSONL])
        XCTAssertEqual(roots.map { $0.rootURL.path }, [
            "/tmp/token-meter-home/.claude/projects",
            "/tmp/token-meter-home/.codex/sessions",
            "/tmp/token-meter-home/.local/share/opencode/opencode.db",
            "/tmp/token-meter-home/.omp/agent/sessions"
        ])

        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)
        try LocalAgentScanner.seedDefaultScanRoots(database: database, homeDirectory: homeDirectory)

        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM scan_roots"), 4)
        XCTAssertEqual(try database.query("SELECT stable_source_key FROM scan_roots WHERE kind = ?", [.text(SourceKind.codexJSONL.rawValue)]).first?.string("stable_source_key"), "codex_jsonl:/tmp/token-meter-home/.codex/sessions")
    }
}

private let latestTotalTokensSQL = """
SELECT u.tokens_total AS value
FROM session_usage_latest latest
JOIN session_usage u ON u.id = latest.session_usage_id
LIMIT 1
"""

private func codexJSONL(inputTokens: Int64, outputTokens: Int64) -> String {
    """
    {"type":"session_meta","payload":{"id":"s1","cwd":"/repo"}}
    {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(inputTokens),"output_tokens":\(outputTokens)}}}}

    """
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func writeJSONL(_ content: String, to file: URL) throws {
    try Data(content.utf8).write(to: file)
}

private func appendJSONL(_ line: String, to file: URL) throws {
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((line + "\n").utf8))
}

private func migratedDatabase(rootKind: SourceKind, rootPath: String) throws -> SQLiteDatabase {
    let database = try SQLiteDatabase(path: ":memory:")
    try TokenMeterDatabaseMigrator.migrate(database)
    try database.execute(
        """
        INSERT INTO scan_roots(id, kind, root_path, display_name, stable_source_key)
        VALUES (?, ?, ?, ?, ?)
        """,
        [
            .int(1),
            .text(rootKind.rawValue),
            .text(rootPath),
            .text(rootKind.rawValue),
            .text("\(rootKind.rawValue):\(rootPath)")
        ]
    )
    return database
}

private func scalarInt(_ database: SQLiteDatabase, _ sql: String, _ parameters: [SQLiteValue] = []) throws -> Int64 {
    try XCTUnwrap(database.query(sql, parameters).first?.int("value"))
}
