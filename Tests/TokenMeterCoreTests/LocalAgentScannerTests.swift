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
        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM usage_events"), 1)
        XCTAssertEqual(try scalarInt(database, "SELECT files_seen AS value FROM scan_runs ORDER BY id DESC LIMIT 1"), 1)
        XCTAssertEqual(try scalarInt(database, "SELECT files_changed AS value FROM scan_runs ORDER BY id DESC LIMIT 1"), 0)
    }

    func testUnchangedFileIsSkippedEntirely() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rollout.jsonl")
        try writeJSONL(codexJSONL(inputTokens: 5, outputTokens: 6), to: file)
        let database = try migratedDatabase(rootKind: .codexJSONL, rootPath: directory.path)
        let scanner = LocalAgentScanner(database: database)

        try await scanner.scanRoot(id: 1)
        let eventsAfterFirst = try scalarInt(database, "SELECT count(*) AS value FROM usage_events")
        try await scanner.scanRoot(id: 1)

        // 指纹未变的文件不应被重新解析：usage_events 行数不变，第二轮 files_changed = 0。
        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM usage_events"), eventsAfterFirst)
        XCTAssertEqual(try scalarInt(database, "SELECT files_changed AS value FROM scan_runs ORDER BY id DESC LIMIT 1"), 0)
    }

    func testResumesFromLastSourceOffsetPerFile() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rollout.jsonl")
        try writeJSONL(codexJSONL(inputTokens: 1, outputTokens: 2), to: file)
        let database = try migratedDatabase(rootKind: .codexJSONL, rootPath: directory.path)
        let scanner = LocalAgentScanner(database: database)

        try await scanner.scanRoot(id: 1)
        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM usage_events"), 1)

        // 追加一行后重扫，只应新增一条事件，且 event_seq 从 parser_state 续上（1 -> 2）。
        try appendJSONL(codexTokenCount(inputTokens: 3, outputTokens: 4, timestamp: "2026-07-08T02:00:00Z"), to: file)
        try await scanner.scanRoot(id: 1)

        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM usage_events"), 2)
        let seqs = try database.query("SELECT event_seq FROM usage_events ORDER BY event_seq")
            .compactMap { $0.int("event_seq") }
        XCTAssertEqual(seqs, [1, 2])
        XCTAssertEqual(try scalarInt(database, "SELECT coalesce(sum(tokens_total),0) AS value FROM usage_events"), 7)
    }

    func testSubagentFileGetsItsOwnEventSeqNamespace() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 父文件与 subagents/ 下的子文件共享同一个 sessionId。
        try writeJSONL(claudeJSONL(sessionKey: "shared-session", inputTokens: 10, outputTokens: 20), to: directory.appendingPathComponent("parent.jsonl"))
        let subagentsDirectory = directory.appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagentsDirectory, withIntermediateDirectories: true)
        try writeJSONL(claudeJSONL(sessionKey: "shared-session", inputTokens: 3, outputTokens: 4), to: subagentsDirectory.appendingPathComponent("child.jsonl"))

        let database = try migratedDatabase(rootKind: .claudeJSONL, rootPath: directory.path)
        try await LocalAgentScanner(database: database).scanRoot(id: 1)

        // 一个 agent_session，两个 source_file，各自的 event_seq 都从 1 开始。
        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM agent_sessions"), 1)
        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM source_files"), 2)
        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM usage_events"), 2)
        let seqs = try database.query("SELECT event_seq FROM usage_events")
            .compactMap { $0.int("event_seq") }
        XCTAssertEqual(seqs.sorted(), [1, 1])
    }

    func testRollupsAreRebuiltAfterScan() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeJSONL(codexJSONL(inputTokens: 7, outputTokens: 8), to: directory.appendingPathComponent("rollout.jsonl"))
        let database = try migratedDatabase(rootKind: .codexJSONL, rootPath: directory.path)

        try await LocalAgentScanner(database: database).scanRoot(id: 1)

        // 扫描后 daily_rollup / session_rollup 应非空。
        XCTAssertGreaterThan(try scalarInt(database, "SELECT count(*) AS value FROM daily_rollup"), 0)
        XCTAssertGreaterThan(try scalarInt(database, "SELECT count(*) AS value FROM session_rollup"), 0)
        XCTAssertEqual(try scalarInt(database, "SELECT tokens_total AS value FROM session_rollup LIMIT 1"), 15)
    }

    func testRescansAppendedJSONLAndAddsEventForSameSession() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rollout.jsonl")
        try writeJSONL(codexJSONL(inputTokens: 1, outputTokens: 2), to: file)
        let database = try migratedDatabase(rootKind: .codexJSONL, rootPath: directory.path)
        let scanner = LocalAgentScanner(database: database)

        try await scanner.scanRoot(id: 1)
        try appendJSONL(codexTokenCount(inputTokens: 3, outputTokens: 4, timestamp: "2026-07-08T02:00:00Z"), to: file)
        try await scanner.scanRoot(id: 1)

        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM agent_sessions"), 1)
        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM usage_events"), 2)
        XCTAssertEqual(try scalarInt(database, "SELECT coalesce(sum(tokens_total),0) AS value FROM usage_events"), 7)
        XCTAssertEqual(try scalarInt(database, "SELECT files_changed AS value FROM scan_runs ORDER BY id DESC LIMIT 1"), 1)
    }

    func testAppendedCodexJSONLScanResumesFromParserStateAndPreservesSessionMetadata() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rollout.jsonl")
        let initialJSONL = """
        {"type":"session_meta","payload":{"id":"codex-state-session","cwd":"/work/repo"}}
        {"type":"turn_context","payload":{"model":"gpt-5.5","cwd":"/work/repo"}}
        {"type":"event_msg","timestamp":"2026-07-03T04:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"output_tokens":5}}}}

        """
        try writeJSONL(initialJSONL, to: file)
        let database = try migratedDatabase(rootKind: .codexJSONL, rootPath: directory.path)
        let scanner = LocalAgentScanner(database: database)

        try await scanner.scanRoot(id: 1)
        try appendJSONL(codexTokenCount(inputTokens: 14, outputTokens: 9, timestamp: "2026-07-03T05:00:00Z"), to: file)
        let fullFileSize = Int64((try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0)

        try await scanner.scanRoot(id: 1)

        // 会话身份跨续读保留：sessionKey 在 agent_sessions，projectPath 在 projects，model 在 usage_events。
        let sessions = try database.query("SELECT id, source_session_key, project_id FROM agent_sessions")
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].string("source_session_key"), "codex-state-session")
        XCTAssertNotNil(sessions[0].int("project_id"))
        XCTAssertEqual(try database.query("SELECT canonical_path FROM projects LIMIT 1").first?.string("canonical_path"), "/work/repo")

        let models = try database.query("SELECT DISTINCT model_name FROM usage_events").compactMap { $0.string("model_name") }
        XCTAssertEqual(models, ["gpt-5.5"], "续读的事件也应带上从 parser_state 恢复的 model")

        // event1 = 10+5 = 15，event2 = Δ{4,4} = 8，合计 23。
        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM usage_events"), 2)
        XCTAssertEqual(try scalarInt(database, "SELECT coalesce(sum(tokens_total),0) AS value FROM usage_events"), 23)

        let parserStateJSON = try XCTUnwrap(database.query("SELECT parser_state FROM source_files WHERE relative_path = 'rollout.jsonl'").first?.string("parser_state"))
        let parserState = try jsonObject(parserStateJSON)
        XCTAssertEqual((parserState["lastEventSeq"] as? NSNumber)?.int64Value, 2)
        XCTAssertEqual(parserState["sessionKey"] as? String, "codex-state-session")
        XCTAssertEqual(parserState["projectPath"] as? String, "/work/repo")
        XCTAssertEqual(parserState["modelName"] as? String, "gpt-5.5")

        // 只读追加部分，不重读整文件。
        let secondRunBytesRead = try scalarInt(database, "SELECT bytes_read AS value FROM scan_runs ORDER BY id DESC LIMIT 1")
        XCTAssertLessThan(secondRunBytesRead, fullFileSize)
    }

    func testAppendedCodexDuplicateCumulativeSnapshotDoesNotDuplicateUsage() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rollout.jsonl")
        try writeJSONL(codexJSONL(inputTokens: 10, outputTokens: 5, sessionId: "codex-duplicate-session"), to: file)
        let database = try migratedDatabase(rootKind: .codexJSONL, rootPath: directory.path)
        let scanner = LocalAgentScanner(database: database)

        try await scanner.scanRoot(id: 1)
        // 追加一条与累计值完全相同的快照：差分为 0，不应产生新事件。
        try appendJSONL(codexTokenCount(inputTokens: 10, outputTokens: 5, timestamp: "2026-07-08T02:00:00Z"), to: file)
        try await scanner.scanRoot(id: 1)

        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM agent_sessions"), 1)
        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM usage_events"), 1)
        XCTAssertEqual(try scalarInt(database, "SELECT coalesce(sum(tokens_total),0) AS value FROM usage_events"), 15)
        let parserStateJSON = try XCTUnwrap(database.query("SELECT parser_state FROM source_files WHERE relative_path = 'rollout.jsonl'").first?.string("parser_state"))
        XCTAssertEqual((try jsonObject(parserStateJSON)["lastEventSeq"] as? NSNumber)?.int64Value, 1)
    }

    func testAppendedCodexTokenCountWithoutTimestampIsSkippedAndUpdatedAtPreserved() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rollout.jsonl")
        try writeJSONL(codexJSONL(inputTokens: 10, outputTokens: 5, sessionId: "codex-timestamp-session", timestamp: "2026-07-03T04:00:00Z"), to: file)
        let database = try migratedDatabase(rootKind: .codexJSONL, rootPath: directory.path)
        let scanner = LocalAgentScanner(database: database)

        try await scanner.scanRoot(id: 1)
        let firstUpdatedAt = try XCTUnwrap(
            database.query("SELECT session_updated_at FROM agent_sessions WHERE source_session_key = 'codex-timestamp-session'").first?.string("session_updated_at")
        )

        // 追加一条没有 timestamp 的 token_count：v2 要求每条事件都有观测时间，缺时间的整条跳过。
        try appendJSONL(#"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":14,"output_tokens":9}}}}"#, to: file)
        try await scanner.scanRoot(id: 1)

        let secondUpdatedAt = try database.query(
            "SELECT session_updated_at FROM agent_sessions WHERE source_session_key = 'codex-timestamp-session'"
        )[0].string("session_updated_at")
        XCTAssertEqual(secondUpdatedAt, firstUpdatedAt)
        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM usage_events"), 1)
        XCTAssertEqual(try scalarInt(database, "SELECT coalesce(sum(tokens_total),0) AS value FROM usage_events"), 15)
    }

    func testFullRereadClearsCodexParserUsageStateBeforeResumingNewSession() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rollout.jsonl")
        let initialJSONL = """
        {"type":"session_meta","payload":{"id":"codex-stale-old","cwd":"/work/old"}}
        {"type":"event_msg","timestamp":"2026-07-03T05:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"output_tokens":5}}}}

        """
        let rewrittenJSONL = """
        {"type":"session_meta","payload":{"id":"codex-stale-new","cwd":"/work/new"}}

        """
        XCTAssertLessThan(Data(rewrittenJSONL.utf8).count, Data(initialJSONL.utf8).count)
        try writeJSONL(initialJSONL, to: file)
        let database = try migratedDatabase(rootKind: .codexJSONL, rootPath: directory.path)
        let scanner = LocalAgentScanner(database: database)

        try await scanner.scanRoot(id: 1)
        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM usage_events"), 1)

        try writeJSONL(rewrittenJSONL, to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_820_000_100)],
            ofItemAtPath: file.path
        )
        try await scanner.scanRoot(id: 1)
        // 改写成更短的内容后全量重读，旧 session 的事件被清掉，新 session 暂无事件。
        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM usage_events WHERE session_id = (SELECT id FROM agent_sessions WHERE source_session_key = 'codex-stale-new')"), 0)

        try appendJSONL(codexTokenCount(inputTokens: 10, outputTokens: 5, timestamp: "2026-07-03T06:00:00Z"), to: file)
        try await scanner.scanRoot(id: 1)

        let newSessionTotals = try database.query(
            """
            SELECT e.tokens_total
            FROM agent_sessions s
            JOIN usage_events e ON e.session_id = s.id
            WHERE s.source_session_key = 'codex-stale-new'
            ORDER BY e.event_seq
            """
        ).map { try XCTUnwrap($0.int("tokens_total")) }
        XCTAssertEqual(newSessionTotals, [15])
    }

    func testAppendedCodexLastTokenUsageWithEqualCountsCreatesAnotherUsageEvent() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rollout.jsonl")
        let initialJSONL = """
        {"type":"session_meta","payload":{"id":"codex-last-usage-repeat","cwd":"/work/repo"}}
        {"type":"event_msg","timestamp":"2026-07-03T04:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"output_tokens":5}}}}

        """
        try writeJSONL(initialJSONL, to: file)
        let database = try migratedDatabase(rootKind: .codexJSONL, rootPath: directory.path)
        let scanner = LocalAgentScanner(database: database)

        try await scanner.scanRoot(id: 1)
        try appendJSONL(#"{"type":"event_msg","timestamp":"2026-07-03T04:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"output_tokens":5}}}}"#, to: file)
        try await scanner.scanRoot(id: 1)

        let usageRows = try database.query(
            """
            SELECT e.event_seq, e.tokens_total
            FROM agent_sessions s
            JOIN usage_events e ON e.session_id = s.id
            WHERE s.source_session_key = 'codex-last-usage-repeat'
            ORDER BY e.event_seq
            """
        )
        XCTAssertEqual(try usageRows.map { try XCTUnwrap($0.int("event_seq")) }, [1, 2])
        XCTAssertEqual(try usageRows.map { try XCTUnwrap($0.int("tokens_total")) }, [15, 15])
    }

    func testSameSizeJSONLRewriteStartsFromBeginningInsteadOfStoredOffset() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rollout.jsonl")
        let initialJSONL = """
        {"type":"session_meta","payload":{"id":"codex-rewrite-old","cwd":"/work/old"}}
        {"type":"event_msg","timestamp":"2026-07-03T05:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"output_tokens":5}}}}

        """
        let rewrittenJSONL = """
        {"type":"session_meta","payload":{"id":"codex-rewrite-new","cwd":"/work/new"}}
        {"type":"event_msg","timestamp":"2026-07-03T06:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20,"output_tokens":7}}}}

        """
        XCTAssertEqual(Data(initialJSONL.utf8).count, Data(rewrittenJSONL.utf8).count)
        try writeJSONL(initialJSONL, to: file)
        let database = try migratedDatabase(rootKind: .codexJSONL, rootPath: directory.path)
        let scanner = LocalAgentScanner(database: database)

        try await scanner.scanRoot(id: 1)
        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM agent_sessions WHERE source_session_key = 'codex-rewrite-old'"), 1)

        try writeJSONL(rewrittenJSONL, to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_820_000_000)],
            ofItemAtPath: file.path
        )
        try await scanner.scanRoot(id: 1)

        let rewrittenTotals = try database.query(
            """
            SELECT e.tokens_total
            FROM agent_sessions s
            JOIN usage_events e ON e.session_id = s.id
            WHERE s.source_session_key = 'codex-rewrite-new'
            """
        ).compactMap { $0.int("tokens_total") }
        XCTAssertEqual(rewrittenTotals, [27])
        XCTAssertGreaterThanOrEqual(
            try scalarInt(database, "SELECT bytes_read AS value FROM scan_runs ORDER BY id DESC LIMIT 1"),
            Int64(Data(rewrittenJSONL.utf8).count)
        )
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
                    #"{"type":"message","timestamp":"2026-07-03T03:02:00Z","message":{"role":"assistant","content":"SECRET_OMP_RESPONSE","usage":{"input":11,"output":22,"reasoningTokens":1,"cacheRead":5,"cacheWrite":6}}}"# + "\n",
                "omp",
                "omp-session-1",
                // v2 的 totalTokens 不含 reasoning：11+22+5+6 = 44。
                44
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
            XCTAssertEqual(try scalarInt(database, "SELECT coalesce(sum(tokens_total),0) AS value FROM usage_events"), testCase.expectedTotal)
            let rawMetadata = try XCTUnwrap(rows[0].string("raw_meta_json"))
            XCTAssertFalse(rawMetadata.contains("SECRET"))
            XCTAssertFalse(rawMetadata.contains("Do not store"))
        }
    }

    func testScansOpenCodeSQLiteRootAndStoresHighWaterCursor() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let openCodeURL = directory.appendingPathComponent("opencode.db")
        let createdMs = Int64(ISO8601DateFormatter().date(from: "2026-07-03T00:10:00Z")!.timeIntervalSince1970 * 1000)
        let sourceDatabase = try SQLiteDatabase(path: openCodeURL.path)
        try sourceDatabase.execute("CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, data TEXT)")
        try sourceDatabase.execute(
            "INSERT INTO message(id, session_id, data) VALUES (?, ?, ?)",
            [
                .text("m1"),
                .text("opencode-session-1"),
                .text("""
                {"id":"m1","sessionID":"opencode-session-1","modelID":"claude-sonnet","cost":0,"time":{"created":\(createdMs)},"tokens":{"input":10,"output":20,"reasoning":0,"cache":{"read":3,"write":9}}}
                """)
            ]
        )
        try sourceDatabase.close()
        let database = try migratedDatabase(rootKind: .opencodeSQLite, rootPath: openCodeURL.path)
        let scanner = LocalAgentScanner(database: database)

        try await scanner.scanRoot(id: 1)
        try await scanner.scanRoot(id: 1)

        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM agent_sessions"), 1)
        XCTAssertEqual(try scalarInt(database, "SELECT coalesce(sum(tokens_total),0) AS value FROM usage_events"), 42)
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
        try sourceDatabase.execute("CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, data TEXT)")
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
        XCTAssertEqual(try scalarInt(database, "SELECT coalesce(sum(tokens_total),0) AS value FROM usage_events"), 21)
        XCTAssertEqual(try database.query("SELECT parse_status FROM source_files LIMIT 1")[0].string("parse_status"), "ok")
        XCTAssertEqual(try scalarInt(database, "SELECT files_changed AS value FROM scan_runs ORDER BY id DESC LIMIT 1"), 1)
    }

    func testJSONLScanContinuesAfterBadFileAndIndexesLaterValidFiles() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try writeJSONL(claudeJSONL(sessionKey: "claude-a", inputTokens: 1, outputTokens: 2), to: directory.appendingPathComponent("a-valid.jsonl"))
        try writeJSONL(claudeJSONLMissingSessionKey(inputTokens: 3, outputTokens: 4), to: directory.appendingPathComponent("m-bad.jsonl"))
        try writeJSONL(claudeJSONL(sessionKey: "claude-z", inputTokens: 5, outputTokens: 6), to: directory.appendingPathComponent("z-valid.jsonl"))

        let database = try migratedDatabase(rootKind: .claudeJSONL, rootPath: directory.path)

        do {
            try await LocalAgentScanner(database: database).scanRoot(id: 1)
        } catch {
            // A bad file may leave the scan partial, but it must not stop later files from being indexed.
        }

        let run = try database.query("SELECT status, files_seen FROM scan_runs ORDER BY id DESC LIMIT 1")[0]
        XCTAssertEqual(run.int("files_seen"), 3, "the scanner must visit every sorted JSONL file even after one parse failure")

        let sessionKeys = try database.query("SELECT source_session_key FROM agent_sessions ORDER BY source_session_key ASC")
            .compactMap { $0.string("source_session_key") }
        XCTAssertEqual(sessionKeys, ["claude-a", "claude-z"], "valid files before and after the bad file must both be indexed")

        let failedFiles = try database.query("SELECT relative_path, parse_status FROM source_files WHERE parse_status = 'failed'")
        XCTAssertEqual(failedFiles.count, 1)
        XCTAssertEqual(failedFiles[0].string("relative_path"), "m-bad.jsonl")
    }

    func testClaudeAuxiliaryJSONLIsSkippedWithoutMarkingRootPartial() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try writeJSONL(claudeJSONL(sessionKey: "claude-valid", inputTokens: 13, outputTokens: 21), to: directory.appendingPathComponent("session.jsonl"))
        try writeJSONL(claudeAuxiliaryJSONL(), to: directory.appendingPathComponent("skill-injections.jsonl"))

        let database = try migratedDatabase(rootKind: .claudeJSONL, rootPath: directory.path)

        try await LocalAgentScanner(database: database).scanRoot(id: 1)

        let run = try database.query("SELECT status, files_seen, files_changed, error_summary FROM scan_runs ORDER BY id DESC LIMIT 1")[0]
        XCTAssertEqual(run.string("status"), "ok")
        XCTAssertEqual(run.int("files_seen"), 2)
        XCTAssertEqual(run.int("files_changed"), 2)
        XCTAssertNil(run.string("error_summary"))
        XCTAssertNil(try database.query("SELECT last_error FROM scan_roots WHERE id = 1")[0].string("last_error"))
        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM source_files WHERE parse_status = 'failed'"), 0)
        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM agent_sessions"), 1)
        XCTAssertEqual(try scalarInt(database, "SELECT coalesce(sum(tokens_total),0) AS value FROM usage_events"), 34)

        let auxiliary = try database.query("SELECT file_type, parse_status, parse_error, last_parsed_run_id FROM source_files WHERE relative_path = 'skill-injections.jsonl' LIMIT 1")[0]
        XCTAssertEqual(auxiliary.string("file_type"), "jsonl_session")
        XCTAssertEqual(auxiliary.string("parse_status"), "ok")
        XCTAssertNil(auxiliary.string("parse_error"))
        XCTAssertNotNil(auxiliary.int("last_parsed_run_id"))
    }

    func testMalformedMiddleLineIsSkippedAndValidUsageStillIndexed() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("mixed-malformed.jsonl")
        // 中间这条既畸形、又不含任何 Codex marker：会被字节预筛直接丢掉，绝不进入 parser 或库。
        let malformedLine = #"{"private":"SECRET_PRIVATE_PROMPT","misc":"not closed""#
        let mixedJSONL = """
        {"type":"session_meta","payload":{"id":"mixed-malformed-session","cwd":"/repo"}}
        \(malformedLine)
        {"type":"event_msg","timestamp":"2026-07-08T01:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2,"output_tokens":3}}}}

        """
        try writeJSONL(mixedJSONL, to: file)
        let database = try migratedDatabase(rootKind: .codexJSONL, rootPath: directory.path)

        try await LocalAgentScanner(database: database).scanRoot(id: 1)

        // 合法用量照常入库。
        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM usage_events"), 1)
        XCTAssertEqual(try scalarInt(database, "SELECT coalesce(sum(tokens_total),0) AS value FROM usage_events"), 5)
        // 畸形行的私密内容绝不落库任何文本列。
        let dump = try localAgentTextDump(database)
        XCTAssertFalse(dump.contains("SECRET_PRIVATE_PROMPT"))
    }

    func testMalformedResidualJSONLLineRecordsSanitizedParseError() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("mixed-residual-malformed.jsonl")
        let malformedResidual = #"{"private":"SECRET_PRIVATE_PROMPT","usage":"not closed""#
        let mixedJSONL = """
        {"type":"session_meta","payload":{"id":"mixed-residual-session","cwd":"/repo"}}
        {"type":"event_msg","timestamp":"2026-07-08T01:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2,"output_tokens":3}}}}
        \(malformedResidual)
        """
        try writeJSONL(mixedJSONL, to: file)
        let database = try migratedDatabase(rootKind: .codexJSONL, rootPath: directory.path)

        do {
            try await LocalAgentScanner(database: database).scanRoot(id: 1)
        } catch {
            // 整根可能被标记为 partial，但源文件必须留有脱敏后的解析元数据。
        }

        let sourceFile = try database.query("SELECT parse_status, parse_error FROM source_files WHERE relative_path = 'mixed-residual-malformed.jsonl' LIMIT 1")[0]
        XCTAssertEqual(sourceFile.string("parse_status"), "partial", "结尾残行必须让文件标为 partial")

        let parseError = try XCTUnwrap(sourceFile.string("parse_error"))
        XCTAssertFalse(parseError.isEmpty)
        XCTAssertFalse(parseError.contains(malformedResidual), "parse_error must not persist the malformed residual")
        XCTAssertFalse(parseError.contains("SECRET_PRIVATE_PROMPT"), "parse_error must not persist private JSONL content")
    }

    func testOkSourceFileWithoutUsageEventsIsRescanned() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("stale-ok.jsonl")
        try writeJSONL(codexJSONL(inputTokens: 9, outputTokens: 4), to: file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let sizeBytes = try XCTUnwrap((attributes[.size] as? NSNumber)?.int64Value)
        let modifiedAt = try XCTUnwrap(attributes[.modificationDate] as? Date)
        let mtimeNanoseconds = Int64((modifiedAt.timeIntervalSince1970 * 1_000_000_000).rounded())
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.int64Value
        let dev = (attributes[.systemNumber] as? NSNumber)?.int64Value
        let database = try migratedDatabase(rootKind: .codexJSONL, rootPath: directory.path)
        // 预置一条"指纹吻合但 usage_events 里没有任何事件"的 ok source_file，
        // 模拟 v1→v2 升级：v1 已把文件标成 ok，v2 的事件表还是空的，必须重扫。
        try database.execute(
            """
            INSERT INTO scan_runs(id, scan_root_id, run_kind, status)
            VALUES (?, ?, ?, ?)
            """,
            [.int(123), .int(1), .text("incremental"), .text("ok")]
        )
        try database.execute(
            """
            INSERT INTO source_files(
                scan_root_id, relative_path, canonical_path, file_type, size_bytes, mtime_ns,
                inode, dev, first_seen_run_id, last_seen_run_id, last_parsed_run_id,
                parse_status, parser_state
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, 123, ?, ?)
            """,
            [
                .int(1),
                .text("stale-ok.jsonl"),
                .text(file.path),
                .text("jsonl_session"),
                .int(sizeBytes),
                .int(mtimeNanoseconds),
                inode.map(SQLiteValue.int) ?? .null,
                dev.map(SQLiteValue.int) ?? .null,
                .text("ok"),
                .text(#"{"lastEventSeq":0}"#)
            ]
        )

        try await LocalAgentScanner(database: database).scanRoot(id: 1)

        XCTAssertEqual(try scalarInt(database, "SELECT coalesce(sum(tokens_total),0) AS value FROM usage_events"), 13)
        let sourceFile = try database.query("SELECT last_parsed_run_id FROM source_files WHERE relative_path = 'stale-ok.jsonl' LIMIT 1")[0]
        XCTAssertNotEqual(sourceFile.int("last_parsed_run_id"), 123)
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

// MARK: - Fixtures

private func codexJSONL(
    inputTokens: Int64,
    outputTokens: Int64,
    sessionId: String = "s1",
    timestamp: String = "2026-07-08T01:00:00Z"
) -> String {
    """
    {"type":"session_meta","payload":{"id":"\(sessionId)","cwd":"/repo"}}
    \(codexTokenCount(inputTokens: inputTokens, outputTokens: outputTokens, timestamp: timestamp))

    """
}

private func codexTokenCount(inputTokens: Int64, outputTokens: Int64, timestamp: String) -> String {
    #"{"type":"event_msg","timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(inputTokens),"output_tokens":\#(outputTokens)}}}}"#
}

private func claudeJSONL(sessionKey: String, inputTokens: Int64, outputTokens: Int64) -> String {
    """
    {"sessionId":"\(sessionKey)","cwd":"/repo/\(sessionKey)","timestamp":"2026-07-03T02:00:00Z","type":"assistant","message":{"role":"assistant","model":"claude-sonnet","usage":{"input_tokens":\(inputTokens),"output_tokens":\(outputTokens)}}}

    """
}

private func claudeJSONLMissingSessionKey(inputTokens: Int64, outputTokens: Int64) -> String {
    """
    {"timestamp":"2026-07-03T02:00:00Z","type":"assistant","message":{"role":"assistant","model":"claude-sonnet","usage":{"input_tokens":\(inputTokens),"output_tokens":\(outputTokens)}}}

    """
}

private func claudeAuxiliaryJSONL() -> String {
    """
    {"event":"skill_injection","hookEvent":"UserPromptSubmit","matchedSkills":["typescript-best-practices"],"injectedSkills":[],"droppedByBudget":[],"droppedByCap":[],"summaryOnly":false,"timestamp":"2026-07-03T18:44:03Z"}
    {"event":"skill_injection","hookEvent":"UserPromptSubmit","matchedSkills":["test-driven-development"],"injectedSkills":[],"droppedByBudget":[],"droppedByCap":[],"summaryOnly":false,"timestamp":"2026-07-03T18:44:04Z"}

    """
}

// MARK: - Helpers

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

private func jsonObject(_ json: String) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
    return try XCTUnwrap(object as? [String: Any])
}

private func localAgentTextDump(_ database: SQLiteDatabase) throws -> String {
    let rows = try database.query(
        """
        SELECT value FROM (
          SELECT source_session_key AS value FROM agent_sessions
          UNION ALL SELECT raw_meta_json FROM agent_sessions
          UNION ALL SELECT parser_state FROM source_files
          UNION ALL SELECT parse_error FROM source_files
          UNION ALL SELECT model_name FROM usage_events
          UNION ALL SELECT model_canonical FROM usage_events
          UNION ALL SELECT dedupe_key FROM usage_events
          UNION ALL SELECT project_key FROM projects
          UNION ALL SELECT canonical_path FROM projects
        )
        WHERE value IS NOT NULL
        """
    )
    return rows.compactMap { $0.string("value") }.joined(separator: "\n")
}
