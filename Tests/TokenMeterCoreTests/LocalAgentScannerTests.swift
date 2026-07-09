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

    func testResumeContinuesCumulativeDiffFromParserState() async throws {
        // 续读时 Codex 的累计差分必须从 parser_state.lastCumulative 接着算，而不是从零重来。
        // （这条不靠 +1 那个 bug——它守的是"累计基线跨续读被恢复"这个另外的不变量：
        //  若不恢复，第二条会把整份累计值当增量，凭空翻倍。）
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rollout.jsonl")
        try writeJSONL(codexJSONL(inputTokens: 1, outputTokens: 2), to: file)
        let database = try migratedDatabase(rootKind: .codexJSONL, rootPath: directory.path)
        let scanner = LocalAgentScanner(database: database)

        try await scanner.scanRoot(id: 1)
        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM usage_events"), 1)

        // 累计值推进到 {3,4}。恢复基线 {1,2} → 第二条增量 {2,2}；不恢复则会当成 {3,4}。
        try appendJSONL(codexTokenCount(inputTokens: 3, outputTokens: 4, timestamp: "2026-07-08T02:00:00Z"), to: file)
        try await scanner.scanRoot(id: 1)

        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM usage_events"), 2)
        let rows = try database.query("SELECT event_seq, tokens_input FROM usage_events ORDER BY event_seq")
        XCTAssertEqual(rows.compactMap { $0.int("event_seq") }, [1, 2])
        XCTAssertEqual(rows.compactMap { $0.int("tokens_input") }, [1, 2], "第二条 input 必须是 3-1=2，证明累计基线从 parser_state 恢复")
        XCTAssertEqual(try scalarInt(database, "SELECT coalesce(sum(tokens_total),0) AS value FROM usage_events"), 7)
    }

    func testResumeIsCorrectWhenALineHasLeadingWhitespace() async throws {
        // 一行若以空格开头，从其第二字节起的残片仍是合法 JSON。
        // 用 max(source_offset)+1 续读会重复消费它，并因 eventSeq 递增而
        // 绕过 UNIQUE(source_file_id, event_seq)，静默地把 token 算两遍。
        // 写两次扫描，断言事件总数不变（正确应为两条，而非三条）。
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rollout.jsonl")
        // 第二行故意以一个空格开头。
        let initialJSONL = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"ws-session\",\"cwd\":\"/repo\"}}\n" +
            " {\"type\":\"event_msg\",\"timestamp\":\"2026-07-08T01:00:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":5,\"output_tokens\":3}}}}\n"
        try writeJSONL(initialJSONL, to: file)
        let database = try migratedDatabase(rootKind: .codexJSONL, rootPath: directory.path)
        let scanner = LocalAgentScanner(database: database)

        try await scanner.scanRoot(id: 1)
        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM usage_events"), 1)

        // 追加一行触发续读。
        try appendJSONL("{\"type\":\"event_msg\",\"timestamp\":\"2026-07-08T02:00:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":7,\"output_tokens\":2}}}}", to: file)
        try await scanner.scanRoot(id: 1)

        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM usage_events"), 2, "带前导空白的行不得被续读重复消费")
        XCTAssertEqual(try scalarInt(database, "SELECT coalesce(sum(tokens_total),0) AS value FROM usage_events"), 17)
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

    func testClaudeAuxiliaryFileMentioningUsageInProseIsNotAFailure() async throws {
        // 一行合法 JSON，没有 sessionId，正文里含字面量 "usage"（这里是某条 hook 日志的字符串值），
        // 但它没有挂在 message 下的 usage 对象——不是会话文件。
        // 旧实现用便宜的子串探测把它误判成"缺 sessionId 的坏会话文件"、抛错、把 root 拖成 partial；
        // 新实现由 parser 从解析后的字典判定它是辅助文件，返回空会话、静默跳过。
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let auxLine = #"{"event":"skill_injection","hookEvent":"UserPromptSubmit","note":"usage","timestamp":"2026-07-03T18:44:03Z"}"#
        try writeJSONL(auxLine + "\n", to: directory.appendingPathComponent("aux-usage-in-prose.jsonl"))

        let database = try migratedDatabase(rootKind: .claudeJSONL, rootPath: directory.path)
        do {
            try await LocalAgentScanner(database: database).scanRoot(id: 1)
        } catch {
            // 旧实现会在这里抛错；捕获后靠下面的断言暴露它把 root 拖成了 partial。
        }

        let run = try database.query("SELECT status, error_summary FROM scan_runs ORDER BY id DESC LIMIT 1")[0]
        XCTAssertEqual(run.string("status"), "ok", "正文里字面量提到 usage 的辅助文件不得把 root 拖成 partial")
        XCTAssertNil(run.string("error_summary"))
        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM source_files WHERE parse_status = 'failed'"), 0)
        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM usage_events"), 0)
        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM agent_sessions"), 0)
    }

    func testClaudeSessionFileWithUsageButNoSessionIdStillFails() async throws {
        // 真正坏掉的会话文件：有挂在 message 下的 usage 对象、带真实 token，但缺 sessionId。
        // 放宽辅助文件判定后，它绝不能被静默吞掉——必须仍然解析失败、把 root 标为 partial、
        // 且一条用量都不落库，否则这台会计工具会丢掉真实用量却一声不响。
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try writeJSONL(claudeJSONLMissingSessionKey(inputTokens: 11, outputTokens: 22), to: directory.appendingPathComponent("broken-session.jsonl"))

        let database = try migratedDatabase(rootKind: .claudeJSONL, rootPath: directory.path)
        var threw = false
        do {
            try await LocalAgentScanner(database: database).scanRoot(id: 1)
        } catch {
            threw = true
        }
        XCTAssertTrue(threw, "缺 sessionId 但有 usage 的坏会话文件必须让扫描失败")

        let run = try database.query("SELECT status FROM scan_runs ORDER BY id DESC LIMIT 1")[0]
        XCTAssertEqual(run.string("status"), "partial", "坏会话文件必须把 root 标为 partial")
        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM source_files WHERE parse_status = 'failed'"), 1)
        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM usage_events"), 0, "坏会话文件的用量绝不能被写入")
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

        XCTAssertEqual(roots.map(\.kind), [.claudeJSONL, .codexJSONL, .codexJSONL, .opencodeSQLite, .ompJSONL])
        XCTAssertEqual(roots.map { $0.rootURL.path }, [
            "/tmp/token-meter-home/.claude/projects",
            "/tmp/token-meter-home/.codex/sessions",
            "/tmp/token-meter-home/.codex/archived_sessions",
            "/tmp/token-meter-home/.local/share/opencode/opencode.db",
            "/tmp/token-meter-home/.omp/agent/sessions"
        ])

        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)
        try LocalAgentScanner.seedDefaultScanRoots(database: database, homeDirectory: homeDirectory)

        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM scan_roots"), 5)
        // 两个 codex root 的 stable_source_key 靠 path 区分，不撞 UNIQUE(stable_source_key)。
        XCTAssertEqual(
            try database.query("SELECT stable_source_key FROM scan_roots WHERE kind = ? ORDER BY root_path", [.text(SourceKind.codexJSONL.rawValue)])
                .compactMap { $0.string("stable_source_key") },
            [
                "codex_jsonl:/tmp/token-meter-home/.codex/archived_sessions",
                "codex_jsonl:/tmp/token-meter-home/.codex/sessions"
            ]
        )
    }

    func testCodexArchivedSessionsRootIsScanned() async throws {
        // Codex 会把旧 session 从 ~/.codex/sessions 挪进 ~/.codex/archived_sessions（同为
        // rollout-*.jsonl）。两个默认 codex root 各放一个【不同】 session，两根都必须被扫描，
        // 事件数与 token 数是两者之和。修复前 archived_sessions 不在 defaultScanRoots 里，
        // 只有 sessions 被扫，断言（2 条事件、25 token）失败。
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let sessionsDir = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        let archivedDir = home.appendingPathComponent(".codex/archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archivedDir, withIntermediateDirectories: true)
        try writeJSONL(codexJSONL(inputTokens: 10, outputTokens: 5, sessionId: "live-session"), to: sessionsDir.appendingPathComponent("rollout-live.jsonl"))
        try writeJSONL(codexJSONL(inputTokens: 7, outputTokens: 3, sessionId: "archived-session"), to: archivedDir.appendingPathComponent("rollout-archived.jsonl"))

        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)
        try LocalAgentScanner.seedDefaultScanRoots(database: database, homeDirectory: home)
        let scanner = LocalAgentScanner(database: database)
        for row in try database.query("SELECT id FROM scan_roots WHERE kind = ? ORDER BY id", [.text(SourceKind.codexJSONL.rawValue)]) {
            try await scanner.scanRoot(id: try XCTUnwrap(row.int("id")))
        }

        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM agent_sessions"), 2, "sessions 与 archived_sessions 各贡献一个 session")
        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM usage_events"), 2)
        // sessions: 10+5=15，archived: 7+3=10 → 25。
        XCTAssertEqual(try scalarInt(database, "SELECT coalesce(sum(tokens_total),0) AS value FROM usage_events"), 25)
    }

    func testTheSameCodexSessionInBothRootsIsNotCountedTwice() async throws {
        // 同一个 session（同一 source_session_key）同时出现在 sessions 与 archived_sessions 里。
        // codex 的 token_count 事件没有 messageId，UsageEvent.dedupeKey 为 nil，
        // UsageEventDeduplicator 原样放行——所以这条只能靠别的机制保证。
        //
        // 唯一挡住重复计数的，是"归档是移动而非复制"这条【外部】假设（本机实测两目录文件名
        // 交集为 0）。它无法在代码里强制。本测试把同一 session 直接塞进两个 root，断言 token
        // 只算一次（15，而非 30）。今天它会红：agent_sessions 因 UNIQUE(source_kind,
        // source_session_key) upsert 成一行，但两份事件分别挂在不同 source_file_id 上、codex
        // 无 dedupe_key，两遍都被计入。留红作为"归档是移动"这一外部假设的显式标记。
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionsDir = directory.appendingPathComponent("sessions", isDirectory: true)
        let archivedDir = directory.appendingPathComponent("archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archivedDir, withIntermediateDirectories: true)
        // 同一 session id，不同文件名（模拟归档换名），内容一致。
        try writeJSONL(codexJSONL(inputTokens: 10, outputTokens: 5, sessionId: "same-session"), to: sessionsDir.appendingPathComponent("rollout-live.jsonl"))
        try writeJSONL(codexJSONL(inputTokens: 10, outputTokens: 5, sessionId: "same-session"), to: archivedDir.appendingPathComponent("rollout-archived.jsonl"))

        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)
        try database.execute(
            "INSERT INTO scan_roots(id, kind, root_path, display_name, stable_source_key) VALUES (?, ?, ?, ?, ?)",
            [.int(1), .text(SourceKind.codexJSONL.rawValue), .text(sessionsDir.path), .text("Codex"), .text("codex_jsonl:\(sessionsDir.path)")]
        )
        try database.execute(
            "INSERT INTO scan_roots(id, kind, root_path, display_name, stable_source_key) VALUES (?, ?, ?, ?, ?)",
            [.int(2), .text(SourceKind.codexJSONL.rawValue), .text(archivedDir.path), .text("Codex (Archived)"), .text("codex_jsonl:\(archivedDir.path)")]
        )
        let scanner = LocalAgentScanner(database: database)
        try await scanner.scanRoot(id: 1)
        try await scanner.scanRoot(id: 2)

        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM agent_sessions"), 1, "同一 session 因 upsert 只应有一行")
        XCTAssertEqual(
            try scalarInt(database, "SELECT coalesce(sum(tokens_total),0) AS value FROM usage_events"),
            15,
            "同一 session 的 token 必须只算一次；codex 无 dedupeKey，今天会算成 30"
        )
    }

    func testInPlaceRewriteToLargerBodyDoesNotResumeWithStaleContent() async throws {
        // 原地改写成更大的不同内容（同 inode + 更大 size）与"追加"在 shouldResume 眼里长得一样。
        // 只有内容指纹能分辨：改写会改开头字节，指纹变 → 全量重读，而非从旧游标续读。
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rollout.jsonl")
        let initialJSONL = """
        {"type":"session_meta","payload":{"id":"session-A","cwd":"/work/a"}}
        {"type":"event_msg","timestamp":"2026-07-08T01:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":5,"output_tokens":3}}}}

        """
        let rewrittenJSONL = """
        {"type":"session_meta","payload":{"id":"session-B","cwd":"/work/b"}}
        {"type":"event_msg","timestamp":"2026-07-08T02:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"output_tokens":20}}}}
        {"type":"event_msg","timestamp":"2026-07-08T02:01:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":15,"output_tokens":30}}}}

        """
        // 改写必须更大，否则 shouldResume 的 size 判据先兜住，测不到指纹这一层。
        XCTAssertGreaterThan(Data(rewrittenJSONL.utf8).count, Data(initialJSONL.utf8).count)
        try writeJSONL(initialJSONL, to: file)
        let database = try migratedDatabase(rootKind: .codexJSONL, rootPath: directory.path)
        let scanner = LocalAgentScanner(database: database)

        try await scanner.scanRoot(id: 1)
        let inodeBefore = (try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber)?.int64Value

        // Data.write 非原子，原地覆盖保留 inode——这正是 shouldResume 靠 inode 分辨不出改写的原因。
        try writeJSONL(rewrittenJSONL, to: file)
        let inodeAfter = (try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber)?.int64Value
        XCTAssertEqual(inodeBefore, inodeAfter, "原地改写应保留 inode")

        try await scanner.scanRoot(id: 1)

        XCTAssertEqual(
            try scalarInt(database, "SELECT count(*) AS value FROM usage_events WHERE session_id = (SELECT id FROM agent_sessions WHERE source_session_key = 'session-A')"),
            0,
            "stale event from overwritten content A must not persist"
        )
        let bTotals = try database.query(
            """
            SELECT e.tokens_total
            FROM agent_sessions s JOIN usage_events e ON e.session_id = s.id
            WHERE s.source_session_key = 'session-B'
            ORDER BY e.event_seq
            """
        ).compactMap { $0.int("tokens_total") }
        XCTAssertEqual(bTotals, [30, 15], "改写后只应有 B 的事件")
    }

    func testNullFingerprintRowFullRereadsInsteadOfResuming() async throws {
        // content_fingerprint 为 NULL（读不出，或行早于指纹功能）时必须 fail closed：全量重读，不续读。
        // 若续读，会用旧的 resumeOffset（这里故意指到文件末尾之后），读不到任何东西、陈旧事件残留。
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rollout.jsonl")
        try writeJSONL(codexJSONL(inputTokens: 9, outputTokens: 4, sessionId: "real-session"), to: file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let sizeBytes = try XCTUnwrap((attributes[.size] as? NSNumber)?.int64Value)
        let mtimeNs = Int64((try XCTUnwrap(attributes[.modificationDate] as? Date).timeIntervalSince1970 * 1_000_000_000).rounded())
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.int64Value
        let dev = (attributes[.systemNumber] as? NSNumber)?.int64Value
        let database = try migratedDatabase(rootKind: .codexJSONL, rootPath: directory.path)
        try database.execute("INSERT INTO scan_runs(id, scan_root_id, run_kind, status) VALUES (99,1,'incremental','ok')")
        try database.execute("INSERT INTO agent_sessions(id, source_kind, source_session_key, scan_root_id, provider_id, source_revision) VALUES (77,'codex_jsonl','stale-session',1,'codex','r')")
        // size 比现在小（看起来"变大了" → 满足 shouldResume 的 grew 判据），mtime 不一致（skip 失效），
        // content_fingerprint 为 NULL，resumeOffset 指到文件末尾之后。
        try database.execute(
            """
            INSERT INTO source_files(id, scan_root_id, relative_path, canonical_path, file_type, size_bytes, mtime_ns,
                inode, dev, first_seen_run_id, last_seen_run_id, last_parsed_run_id, content_fingerprint, parse_status, parser_state)
            VALUES (5, 1, 'rollout.jsonl', ?, 'jsonl_session', ?, ?, ?, ?, 99, 99, 99, NULL, 'ok', ?)
            """,
            [
                .text(file.path),
                .int(1),
                .int(mtimeNs - 1),
                inode.map(SQLiteValue.int) ?? .null,
                dev.map(SQLiteValue.int) ?? .null,
                .text("{\"lastEventSeq\":5,\"resumeOffset\":\(sizeBytes + 100)}")
            ]
        )
        try database.execute(
            """
            INSERT INTO usage_events(session_id, source_file_id, event_seq, observed_epoch_ms, model_canonical, tokens_input, cost_source, source_offset)
            VALUES (77, 5, 1, 1000, 'stale-model', 999, 'unknown', 0)
            """
        )

        try await LocalAgentScanner(database: database).scanRoot(id: 1)

        XCTAssertEqual(
            try scalarInt(database, "SELECT count(*) AS value FROM usage_events WHERE session_id = 77"),
            0,
            "指纹缺失时必须全量重读、清掉陈旧事件，而不是续读"
        )
        XCTAssertEqual(
            try scalarInt(database, "SELECT count(*) AS value FROM usage_events WHERE session_id = (SELECT id FROM agent_sessions WHERE source_session_key = 'real-session')"),
            1
        )
    }

    func testCursorIsNotAdvancedUntilEventsAreCommitted() async throws {
        // I2：游标（size/mtime/resumeOffset + parse_status=ok）必须在事件提交【之后】才推进。
        // 模拟硬崩溃：事件写完后、游标推进前中止 → 行必须留在 pending，下次扫描据此全量重读，不丢不重。
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rollout.jsonl")
        try writeJSONL(codexJSONL(inputTokens: 3, outputTokens: 4, sessionId: "crash-session"), to: file)
        let database = try migratedDatabase(rootKind: .codexJSONL, rootPath: directory.path)
        let scanner = LocalAgentScanner(database: database)

        struct SimulatedCrash: Error {}
        scanner.testHookAfterEventWrite = { _ in throw SimulatedCrash() }
        do {
            try await scanner.scanRoot(id: 1)
        } catch {
            // 崩溃中止整根，符合预期。
        }

        // 崩溃后：事件已提交，但行必须停在 pending（游标未推进）。
        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM usage_events"), 1)
        XCTAssertEqual(
            try database.query("SELECT parse_status FROM source_files WHERE relative_path = 'rollout.jsonl'").first?.string("parse_status"),
            "pending",
            "事件已提交、游标未推进时必须是 pending，否则崩溃后会被永久跳过"
        )

        // 恢复：正常扫描 → pending → 全量重读 → deleteEvents 清旧再重写 → 不丢不重。
        scanner.testHookAfterEventWrite = nil
        try await scanner.scanRoot(id: 1)
        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM usage_events"), 1, "恢复后不得重复计数")
        XCTAssertEqual(
            try database.query("SELECT parse_status FROM source_files WHERE relative_path = 'rollout.jsonl'").first?.string("parse_status"),
            "ok"
        )
    }

    func testShrinkRewriteDeletesOrphanedEventsFromLongerOldContent() async throws {
        // 全量重读时 deleteEvents 必须清掉旧内容的尾部事件：新内容更短，旧的 event_seq 尾行
        // 会被 ON CONFLICT(source_file_id, event_seq) DO UPDATE 漏过而残留，凭空多算。
        // 这是唯一能咬到 deleteEvents 的场景——等量或更多事件时 DO UPDATE 恰好把它盖住。
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rollout.jsonl")
        let initialJSONL = """
        {"type":"session_meta","payload":{"id":"shrink-session","cwd":"/repo"}}
        {"type":"event_msg","timestamp":"2026-07-08T01:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"output_tokens":4}}}}
        {"type":"event_msg","timestamp":"2026-07-08T01:01:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":15,"output_tokens":10}}}}

        """
        let rewrittenJSONL = """
        {"type":"session_meta","payload":{"id":"shrink-session","cwd":"/repo"}}
        {"type":"event_msg","timestamp":"2026-07-08T02:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":3,"output_tokens":2}}}}

        """
        XCTAssertLessThan(Data(rewrittenJSONL.utf8).count, Data(initialJSONL.utf8).count)
        try writeJSONL(initialJSONL, to: file)
        let database = try migratedDatabase(rootKind: .codexJSONL, rootPath: directory.path)
        let scanner = LocalAgentScanner(database: database)

        try await scanner.scanRoot(id: 1)
        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM usage_events"), 2)

        try writeJSONL(rewrittenJSONL, to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_820_000_000)], ofItemAtPath: file.path)
        try await scanner.scanRoot(id: 1)

        XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM usage_events"), 1, "更短的改写后，旧内容的尾部事件不得残留")
        XCTAssertEqual(try scalarInt(database, "SELECT coalesce(sum(tokens_total),0) AS value FROM usage_events"), 5)
    }

    func testMalformedFingerprintNeverResumes() async throws {
        // 各种畸形/边界的 content_fingerprint 都必须 fail closed：全量重读、清掉陈旧事件，不续读。
        // 核心是负长度：Int("-5") 能解析，currentSize >= -5 恒真，hashPrefix(length:-5) 走空串分支，
        // 于是 "-N:<空串哈希>" 会对**任何**新内容返回 true（带旧身份续读）。其余是回归锁。
        let emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" // SHA256("")
        let cases: [String?] = [
            "-5:\(emptyHash)",      // 负长度 + 空串哈希：本 bug 的核心
            "",                     // 空串
            "abc",                  // 无冒号
            ":deadbeef",            // 缺长度
            "12x:abcd",             // 长度非整数
            "10:short",             // 哈希长度不对
            "999999:\(emptyHash)",  // 长度大于文件
            nil                     // 无指纹
        ]
        for fingerprint in cases {
            let staleSurvivors = try await staleSessionEventCount(storedFingerprint: fingerprint)
            XCTAssertEqual(staleSurvivors, 0, "content_fingerprint=\(fingerprint ?? "NULL") 必须全量重读，而不是续读")
        }
    }

    /// 预置一个 (指纹 + 陈旧事件 + resumeOffset 指到文件末尾之后) 的行，扫一个"变大"的真实文件，
    /// 返回陈旧会话残留的事件数：0 = 全量重读（fail closed），1 = 错误续读。
    private func staleSessionEventCount(storedFingerprint: String?) async throws -> Int64 {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rollout.jsonl")
        try writeJSONL(codexJSONL(inputTokens: 9, outputTokens: 4, sessionId: "real-session"), to: file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let sizeBytes = try XCTUnwrap((attributes[.size] as? NSNumber)?.int64Value)
        let mtimeNs = Int64((try XCTUnwrap(attributes[.modificationDate] as? Date).timeIntervalSince1970 * 1_000_000_000).rounded())
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.int64Value
        let dev = (attributes[.systemNumber] as? NSNumber)?.int64Value
        let database = try migratedDatabase(rootKind: .codexJSONL, rootPath: directory.path)
        try database.execute("INSERT INTO scan_runs(id, scan_root_id, run_kind, status) VALUES (99,1,'incremental','ok')")
        try database.execute("INSERT INTO agent_sessions(id, source_kind, source_session_key, scan_root_id, provider_id, source_revision) VALUES (77,'codex_jsonl','stale-session',1,'codex','r')")
        try database.execute(
            """
            INSERT INTO source_files(id, scan_root_id, relative_path, canonical_path, file_type, size_bytes, mtime_ns,
                inode, dev, first_seen_run_id, last_seen_run_id, last_parsed_run_id, content_fingerprint, parse_status, parser_state)
            VALUES (5, 1, 'rollout.jsonl', ?, 'jsonl_session', ?, ?, ?, ?, 99, 99, 99, ?, 'ok', ?)
            """,
            [
                .text(file.path),
                .int(1),
                .int(mtimeNs - 1),
                inode.map(SQLiteValue.int) ?? .null,
                dev.map(SQLiteValue.int) ?? .null,
                storedFingerprint.map(SQLiteValue.text) ?? .null,
                .text("{\"lastEventSeq\":5,\"resumeOffset\":\(sizeBytes + 100)}")
            ]
        )
        try database.execute(
            """
            INSERT INTO usage_events(session_id, source_file_id, event_seq, observed_epoch_ms, model_canonical, tokens_input, cost_source, source_offset)
            VALUES (77, 5, 1, 1000, 'stale-model', 999, 'unknown', 0)
            """
        )
        try await LocalAgentScanner(database: database).scanRoot(id: 1)
        return try scalarInt(database, "SELECT count(*) AS value FROM usage_events WHERE session_id = 77")
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
