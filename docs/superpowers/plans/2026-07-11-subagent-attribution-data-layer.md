# 子代理归并 · 数据层实现计划（Plan 1 / 2）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让四家 agent（OMP/Codex/OpenCode/Claude Code）的子代理会话在库里带上"指向根主会话"的关联，为 Plan 2 的查询层归并与下钻打好数据基础。

**Architecture:** 只加派生表列、不碰核心汇总逻辑。`agent_sessions` 加 `root_session_key`（指根主会话的 `source_session_key`）与 `subagent_label`（可读名字）；`source_files` 加 `subagent_label`（Claude 子代理文件专用）。各家用各自最强的父子信号填值：Codex/OpenCode parser 从内容读、OMP scanner 从文件路径推导、Claude scanner 读 `.meta.json` 边车。**Claude 解析归属完全不改**（其子代理已归父会话）。

**Tech Stack:** Swift（TokenMeterCore）、SQLite、XCTest。

**上游 spec:** `docs/superpowers/specs/2026-07-11-subagent-attribution-design.md`（§4 数据模型、§5 各家填值、§2 关联信号覆盖率）。

**Plan 2（展示层，随后编写）:** `overviewRepository` 查询层归并（主会话合计=自己+子会话）、会话数只算主会话、isLive 纳入子代理、`subagentBreakdown` 下钻（含 Claude 按 `source_file` 分组分支）、SessionRail 数量徽标 + 下钻浮窗。**不在本 plan 内。**

---

## 涉及文件

- `Sources/TokenMeterCore/TokenMeterDatabaseSchema.swift` — 加三列，bump `derivedVersion`。
- `Sources/TokenMeterCore/UsageEventModels.swift` — `ParsedSession` 加 `rootSessionKey`/`subagentLabel`。
- `Sources/TokenMeterCore/UsageEventWriter.swift` — `upsertAgentSession` 写两列；`write()` 加 override 参数。
- `Sources/TokenMeterCore/CodexUsageEventParser.swift` — 读 `parent_thread_id`/`agent_role`/`agent_nickname`，标 `isSidechain`。
- `Sources/TokenMeterCore/LocalAgentParsing.swift`（`ParserState`）— 加 `rootSessionKey`/`subagentLabel`，供 Codex 续读恢复。
- `Sources/TokenMeterCore/OpenCodeUsageEventAdapter.swift` — 读 `session.parent_id`/`session.agent`。
- `Sources/TokenMeterCore/OmpUsageEventParser.swift` — 加纯函数 `subagentAttribution(relativePath:)`。
- `Sources/TokenMeterCore/LocalAgentScanner.swift` — OMP 接线（调 attribution + write override）；Claude 读边车 + `UPDATE source_files.subagent_label`。
- 测试：`Tests/TokenMeterCoreTests/{LocalAgentScannerTests,UsageEventWriterTests,CodexUsageEventParserTests,OpenCodeUsageEventAdapterTests,OmpUsageEventParserTests}.swift`。

**术语一致性（后续任务共用）:**
- 列名：`root_session_key`、`subagent_label`（SQL）；Swift 属性 `rootSessionKey`、`subagentLabel`。
- OMP 纯函数：`OmpUsageEventParser.subagentAttribution(relativePath:) -> (rootSessionKey: String?, label: String?)`。
- `write()` 覆盖参数：`rootSessionKeyOverride: String? = nil`、`subagentLabelOverride: String? = nil`。

---

## Task 1: schema 加三列 + bump derivedVersion

**Files:**
- Modify: `Sources/TokenMeterCore/TokenMeterDatabaseSchema.swift`
- Test: `Tests/TokenMeterCoreTests/LocalAgentScannerTests.swift`（复用 `migratedDatabase` helper）

- [ ] **Step 1: 写失败测试**（加到 `LocalAgentScannerTests.swift` 顶部的测试方法区）

```swift
func testDerivedSchemaHasSubagentAttributionColumns() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try migratedDatabase(rootKind: .ompJSONL, rootPath: directory.path)

    let sessionCols = try database.query("PRAGMA table_info(agent_sessions)").compactMap { $0.string("name") }
    XCTAssertTrue(sessionCols.contains("root_session_key"), "agent_sessions 缺 root_session_key")
    XCTAssertTrue(sessionCols.contains("subagent_label"), "agent_sessions 缺 subagent_label")

    let fileCols = try database.query("PRAGMA table_info(source_files)").compactMap { $0.string("name") }
    XCTAssertTrue(fileCols.contains("subagent_label"), "source_files 缺 subagent_label")
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter LocalAgentScannerTests/testDerivedSchemaHasSubagentAttributionColumns`
Expected: FAIL（三个 `XCTAssertTrue` 均失败，列尚不存在）。

- [ ] **Step 3: 实现——加列并 bump 版本**

在 `TokenMeterDatabaseSchema.swift`：

`derivedVersion` 从 `4` 改为 `5`（并在其上方注释追加一行说明：`// 5：agent_sessions 加 root_session_key/subagent_label、source_files 加 subagent_label（子代理归并）`）：
```swift
public static let derivedVersion: Int64 = 5
```

`agent_sessions` 的 `CREATE TABLE` 里，在 `raw_meta_json TEXT,` 之后、`UNIQUE(source_kind, source_session_key)` 之前，插入两列：
```sql
      raw_meta_json TEXT,
      root_session_key TEXT,
      subagent_label TEXT,
      UNIQUE(source_kind, source_session_key)
```

`source_files` 的 `CREATE TABLE` 里，在 `parser_state TEXT,` 之后插入一列：
```sql
      parser_state TEXT,
      subagent_label TEXT,
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter LocalAgentScannerTests/testDerivedSchemaHasSubagentAttributionColumns`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenMeterCore/TokenMeterDatabaseSchema.swift Tests/TokenMeterCoreTests/LocalAgentScannerTests.swift
git commit -m "feat: add sub-agent attribution columns to the derived schema"
```

---

## Task 2: `ParsedSession` 加字段 + writer 写入 agent_sessions

**Files:**
- Modify: `Sources/TokenMeterCore/UsageEventModels.swift`（`ParsedSession`）
- Modify: `Sources/TokenMeterCore/UsageEventWriter.swift`（`upsertAgentSession` + `write`）
- Test: `Tests/TokenMeterCoreTests/UsageEventWriterTests.swift`

- [ ] **Step 1: 写失败测试**（加到 `UsageEventWriterTests.swift`）

```swift
func testWritesRootSessionKeyAndSubagentLabelFromParsedSession() throws {
    let database = try makeDatabase()
    let writer = UsageEventWriter(database: database, costCalculator: calculator())

    let sub = ParsedSession(
        sourceKind: .claudeJSONL, sessionKey: "child-1", projectPath: "/repo", cliVersion: nil,
        startedAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1),
        events: [event(seq: 1, at: 1)], rawMeta: [:],
        rootSessionKey: "parent-1", subagentLabel: "Explore"
    )
    try writer.write(sub, scanRootId: 1, sourceFileId: 2, runId: nil)

    let row = try database.query(
        "SELECT root_session_key, subagent_label FROM agent_sessions WHERE source_session_key = 'child-1'"
    )[0]
    XCTAssertEqual(row.string("root_session_key"), "parent-1")
    XCTAssertEqual(row.string("subagent_label"), "Explore")
}

func testWriteOverrideBeatsParsedSessionValue() throws {
    let database = try makeDatabase()
    let writer = UsageEventWriter(database: database, costCalculator: calculator())

    // ParsedSession 自身无 root（OMP parser 读不到路径），由 scanner 用 override 传入。
    try writer.write(session([event(seq: 1, at: 1)]), scanRootId: 1, sourceFileId: 1, runId: nil,
                     rootSessionKeyOverride: "root-x", subagentLabelOverride: "Developer-X")

    let row = try database.query(
        "SELECT root_session_key, subagent_label FROM agent_sessions WHERE source_session_key = 's1'"
    )[0]
    XCTAssertEqual(row.string("root_session_key"), "root-x")
    XCTAssertEqual(row.string("subagent_label"), "Developer-X")
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter UsageEventWriterTests/testWritesRootSessionKeyAndSubagentLabelFromParsedSession`
Expected: FAIL（编译错误：`ParsedSession` 无 `rootSessionKey` 参数、`write` 无 override 参数）。

- [ ] **Step 3: 实现**

`UsageEventModels.swift` — `ParsedSession` 加两个属性与 init 参数（默认 nil，不破坏现有 4 家 parser 的构造）：
```swift
public struct ParsedSession: Equatable {
    public let sourceKind: SourceKind
    public let sessionKey: String
    public let projectPath: String?
    public let cliVersion: String?
    public let startedAt: Date?
    public let updatedAt: Date?
    public let events: [UsageEvent]
    public let rawMeta: [String: String]
    public let rootSessionKey: String?
    public let subagentLabel: String?

    public init(
        sourceKind: SourceKind,
        sessionKey: String,
        projectPath: String?,
        cliVersion: String?,
        startedAt: Date?,
        updatedAt: Date?,
        events: [UsageEvent],
        rawMeta: [String: String],
        rootSessionKey: String? = nil,
        subagentLabel: String? = nil
    ) {
        self.sourceKind = sourceKind
        self.sessionKey = sessionKey
        self.projectPath = projectPath
        self.cliVersion = cliVersion
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.events = events
        self.rawMeta = rawMeta
        self.rootSessionKey = rootSessionKey
        self.subagentLabel = subagentLabel
    }
}
```

`UsageEventWriter.swift` — `write()` 加 override 参数，转交给 `upsertAgentSession`：
```swift
public func write(
    _ session: ParsedSession,
    scanRootId: Int64,
    sourceFileId: Int64,
    runId: Int64?,
    rootSessionKeyOverride: String? = nil,
    subagentLabelOverride: String? = nil
) throws {
    try database.execute("BEGIN IMMEDIATE")
    do {
        let projectId = try upsertProject(session.projectPath)
        try upsertAgentSession(
            session, scanRootId: scanRootId, projectId: projectId, runId: runId,
            rootSessionKey: rootSessionKeyOverride ?? session.rootSessionKey,
            subagentLabel: subagentLabelOverride ?? session.subagentLabel
        )
        let sessionId = try lookupSessionId(sourceKind: session.sourceKind, sessionKey: session.sessionKey)

        for event in UsageEventDeduplicator.deduplicate(session.events) {
            try writeEvent(event, sessionId: sessionId, sourceFileId: sourceFileId)
        }
        try database.execute("COMMIT")
    } catch {
        try? database.execute("ROLLBACK")
        throw error
    }
}
```

`upsertAgentSession` 签名加两个参数，INSERT 列表加 `root_session_key, subagent_label`，VALUES 加两个 `?`，`ON CONFLICT ... DO UPDATE SET` 加两行，参数数组加两项。完整改写：
```swift
private func upsertAgentSession(
    _ session: ParsedSession, scanRootId: Int64, projectId: Int64?, runId: Int64?,
    rootSessionKey: String?, subagentLabel: String?
) throws {
    try database.execute(
        """
        INSERT INTO agent_sessions(
            source_kind, source_session_key, scan_root_id, project_id, provider_id,
            cli_version, session_started_at, session_updated_at, source_revision,
            first_seen_run_id, last_seen_run_id, last_indexed_run_id, raw_meta_json,
            root_session_key, subagent_label
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(source_kind, source_session_key) DO UPDATE SET
            scan_root_id = excluded.scan_root_id,
            project_id = excluded.project_id,
            provider_id = excluded.provider_id,
            cli_version = excluded.cli_version,
            session_started_at = coalesce(agent_sessions.session_started_at, excluded.session_started_at),
            session_updated_at = excluded.session_updated_at,
            source_revision = excluded.source_revision,
            last_seen_run_id = excluded.last_seen_run_id,
            last_indexed_run_id = excluded.last_indexed_run_id,
            raw_meta_json = excluded.raw_meta_json,
            root_session_key = excluded.root_session_key,
            subagent_label = excluded.subagent_label
        """,
        [
            .text(session.sourceKind.rawValue),
            .text(session.sessionKey),
            .int(scanRootId),
            sqliteInt(projectId),
            .text(providerId(for: session.sourceKind)),
            sqliteText(session.cliVersion),
            sqliteText(session.startedAt.map(dateFormatter.string(from:))),
            sqliteText(session.updatedAt.map(dateFormatter.string(from:))),
            .text("\(session.sourceKind.rawValue):\(session.events.count)"),
            sqliteInt(runId),
            sqliteInt(runId),
            sqliteInt(runId),
            sqliteText(rawMetaJSON(session.rawMeta)),
            sqliteText(rootSessionKey),
            sqliteText(subagentLabel)
        ]
    )
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter UsageEventWriterTests`
Expected: PASS（新增两个 + 原有测试全绿）。

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenMeterCore/UsageEventModels.swift Sources/TokenMeterCore/UsageEventWriter.swift Tests/TokenMeterCoreTests/UsageEventWriterTests.swift
git commit -m "feat: persist root_session_key/subagent_label on agent_sessions"
```

---

## Task 3: Codex parser 填 root/label + 标记 isSidechain

**Files:**
- Modify: `Sources/TokenMeterCore/LocalAgentParsing.swift`（`ParserState` 加两字段）
- Modify: `Sources/TokenMeterCore/CodexUsageEventParser.swift`
- Test: `Tests/TokenMeterCoreTests/CodexUsageEventParserTests.swift`

**背景（spec §2.1）:** `parent_thread_id` 在 `session_meta.payload` 顶层，或 `payload.source.subagent.thread_spawn.parent_thread_id`；名字来自 `agent_role`+`agent_nickname`。字段缺失（vanilla codex）→ 一切留 nil、退化成独立主会话、不报错。`session_meta` 只在文件开头出现，续读片段没有它 → 关联信息必须存进 `ParserState` 恢复。

- [ ] **Step 1: 写失败测试**（加到 `CodexUsageEventParserTests.swift`）

```swift
func testFlagsSubagentSessionFromParentThreadId() throws {
    let subMeta = #"{"type":"session_meta","payload":{"id":"child-1","cwd":"/repo","parent_thread_id":"parent-1","agent_role":"worker","agent_nickname":"swift-otter"}}"#
    let lines = [
        line(subMeta, offset: 0),
        line(turnContext, offset: 1),
        line(#"{"type":"event_msg","timestamp":"2026-07-08T01:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5}}}}"#, offset: 2)
    ]
    let (session, _) = try CodexUsageEventParser.parse(lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/c.jsonl"), resuming: nil)

    XCTAssertEqual(session.rootSessionKey, "parent-1")
    XCTAssertEqual(session.subagentLabel, "worker · swift-otter")
    XCTAssertTrue(session.events.allSatisfy { $0.isSidechain }, "子代理会话的事件应全部标为 sidechain")
}

func testMainSessionHasNoRootAndNoSidechain() throws {
    // 无 parent_thread_id 的普通会话（含 vanilla codex）：一切留空、事件非 sidechain。
    let lines = [
        line(meta, offset: 0),
        line(turnContext, offset: 1),
        line(#"{"type":"event_msg","timestamp":"2026-07-08T01:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":5}}}}"#, offset: 2)
    ]
    let (session, _) = try CodexUsageEventParser.parse(lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/c.jsonl"), resuming: nil)

    XCTAssertNil(session.rootSessionKey)
    XCTAssertNil(session.subagentLabel)
    XCTAssertTrue(session.events.allSatisfy { !$0.isSidechain })
}

func testSubagentFlagSurvivesResume() throws {
    // 续读片段无 session_meta：关联信息须从 ParserState 恢复，否则续读的事件漏标 sidechain。
    let firstMeta = #"{"type":"session_meta","payload":{"id":"child-1","parent_thread_id":"parent-1","agent_role":"explorer","agent_nickname":"n"}}"#
    let (_, state) = try CodexUsageEventParser.parse(
        lines: [line(firstMeta, offset: 0), line(turnContext, offset: 1)],
        sourceURL: URL(fileURLWithPath: "/tmp/c.jsonl"), resuming: nil
    )
    let (session, _) = try CodexUsageEventParser.parse(
        lines: [line(#"{"type":"event_msg","timestamp":"2026-07-08T02:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":3,"cached_input_tokens":0,"output_tokens":1}}}}"#, offset: 2)],
        sourceURL: URL(fileURLWithPath: "/tmp/c.jsonl"), resuming: state
    )
    XCTAssertEqual(session.rootSessionKey, "parent-1")
    XCTAssertTrue(session.events.allSatisfy { $0.isSidechain })
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter CodexUsageEventParserTests/testFlagsSubagentSessionFromParentThreadId`
Expected: FAIL（`session.rootSessionKey` 恒为 nil；`isSidechain` 恒为 false）。

- [ ] **Step 3: 实现**

`LocalAgentParsing.swift` — `ParserState` 加两字段（默认 nil），init 加两参数：在 `updatedAt` 之后加 `public var rootSessionKey: String?` 与 `public var subagentLabel: String?`，init 参数同名默认 `nil`，并在 init 体内赋值。

`CodexUsageEventParser.swift`：
- 加两个实例属性（在 `updatedAt` 附近）：
```swift
private var rootThreadId: String?
private var subagentLabel: String?
```
- init 从 state 恢复：
```swift
rootThreadId = state?.rootSessionKey
subagentLabel = state?.subagentLabel
```
- `consume` 的 `case "session_meta":` 分支末尾追加读取（`payload` 已在该分支可用）：
```swift
case "session_meta":
    sessionKey = payload.flatMap { JSONDictionary.string($0, "id") } ?? sessionKey
    projectPath = payload.flatMap { JSONDictionary.string($0, "cwd") } ?? projectPath
    if let payload {
        let spawn = JSONDictionary.dictionary(payload, "source")
            .flatMap { JSONDictionary.dictionary($0, "subagent") }
            .flatMap { JSONDictionary.dictionary($0, "thread_spawn") }
        rootThreadId = JSONDictionary.string(payload, "parent_thread_id")
            ?? spawn.flatMap { JSONDictionary.string($0, "parent_thread_id") }
            ?? rootThreadId
        let role = JSONDictionary.string(payload, "agent_role") ?? spawn.flatMap { JSONDictionary.string($0, "agent_role") }
        let nickname = JSONDictionary.string(payload, "agent_nickname") ?? spawn.flatMap { JSONDictionary.string($0, "agent_nickname") }
        subagentLabel = [role, nickname].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? subagentLabel
    }
```
- 事件构造处（`events.append(UsageEvent(...))`）把 `isSidechain: false` 改为 `isSidechain: rootThreadId != nil`。
- `finish` 构造 `ParsedSession` 时补 `rootSessionKey: rootThreadId, subagentLabel: subagentLabel`，构造返回的 `ParserState` 时补 `rootSessionKey: rootThreadId, subagentLabel: subagentLabel`。
- 在文件底部加一个私有小工具（若仓库尚无）：
```swift
private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
```
（若 `String.nilIfEmpty` 已存在于本模块，跳过此扩展，避免重复定义。）

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter CodexUsageEventParserTests`
Expected: PASS（三个新测试 + 原有全绿；原有 token 断言不变，证明 isSidechain 修正不动数字）。

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenMeterCore/LocalAgentParsing.swift Sources/TokenMeterCore/CodexUsageEventParser.swift Tests/TokenMeterCoreTests/CodexUsageEventParserTests.swift
git commit -m "feat: link Codex sub-agent sessions to their parent thread"
```

---

## Task 4: OpenCode adapter 读 parent_id/agent

**Files:**
- Modify: `Sources/TokenMeterCore/OpenCodeUsageEventAdapter.swift`
- Test: `Tests/TokenMeterCoreTests/OpenCodeUsageEventAdapterTests.swift`

**背景（spec §2）:** `session` 表原生列 `parent_id`（可空，子会话指父）、`agent`（子会话名字）。单层、零孤儿。只读 `session` 表结构列，不碰 `message.data` 正文。

- [ ] **Step 1: 写失败测试**（加到 `OpenCodeUsageEventAdapterTests.swift`；建内存库 fixture）

```swift
func testAttributesSubSessionToParentViaParentId() throws {
    let source = try SQLiteDatabase(path: ":memory:")
    try source.execute("""
        CREATE TABLE session(id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT, agent TEXT);
        CREATE TABLE message(id TEXT PRIMARY KEY, session_id TEXT, time_created REAL, time_updated REAL, data TEXT);
    """)
    try source.execute("INSERT INTO session(id, parent_id, directory, agent) VALUES ('main-1', NULL, '/repo', NULL), ('sub-1', 'main-1', '/repo', 'reviewer')")
    // 主会话与子会话各一条带 token 的 message。
    try source.execute("""
        INSERT INTO message(id, session_id, time_created, time_updated, data) VALUES
        ('m1','main-1',1000,1000,'{"id":"m1","sessionID":"main-1","tokens":{"input":100,"output":10}}'),
        ('m2','sub-1',2000,2000,'{"id":"m2","sessionID":"sub-1","tokens":{"input":50,"output":5}}')
    """)

    let sessions = try OpenCodeUsageEventAdapter(sourceDatabase: source).changedSessions(after: nil)
    let sub = try XCTUnwrap(sessions.first { $0.sessionKey == "sub-1" })
    let main = try XCTUnwrap(sessions.first { $0.sessionKey == "main-1" })

    XCTAssertEqual(sub.rootSessionKey, "main-1")
    XCTAssertEqual(sub.subagentLabel, "reviewer")
    XCTAssertNil(main.rootSessionKey, "主会话不应有 root")
    XCTAssertNil(main.subagentLabel)
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter OpenCodeUsageEventAdapterTests/testAttributesSubSessionToParentViaParentId`
Expected: FAIL（`sub.rootSessionKey` 为 nil）。

- [ ] **Step 3: 实现**

在 `OpenCodeUsageEventAdapter` 加一个和 `sessionDirectories()` 平行的读取（读 `parent_id`/`agent`），并在构造 `ParsedSession` 处填字段。

新增方法（放 `sessionDirectories()` 旁）：
```swift
/// 每个 session 的 (parent_id, agent)。测试库缺列时对应值为 nil。
private func sessionAttribution() throws -> [String: (parent: String?, agent: String?)] {
    guard try tableExists("session") else { return [:] }
    let hasParent = try columnExists(table: "session", column: "parent_id")
    let hasAgent = try columnExists(table: "session", column: "agent")
    guard hasParent || hasAgent else { return [:] }
    let rows = try sourceDatabase.query("SELECT id, \(hasParent ? "parent_id" : "NULL AS parent_id"), \(hasAgent ? "agent" : "NULL AS agent") FROM session")
    var out: [String: (parent: String?, agent: String?)] = [:]
    for row in rows {
        guard let id = row.string("id") else { continue }
        out[id] = (row.string("parent_id"), row.string("agent"))
    }
    return out
}
```

在 `changedSessions(after:)` 里，`let directories = try sessionDirectories()` 之后加 `let attribution = try sessionAttribution()`，并在 `sessions.append(ParsedSession(...))` 处补两个参数：
```swift
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
        rootSessionKey: attribution[sessionKey]?.parent,
        subagentLabel: attribution[sessionKey]?.agent
    )
)
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter OpenCodeUsageEventAdapterTests`
Expected: PASS（新测试 + 原有全绿）。

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenMeterCore/OpenCodeUsageEventAdapter.swift Tests/TokenMeterCoreTests/OpenCodeUsageEventAdapterTests.swift
git commit -m "feat: link OpenCode sub-sessions to their parent via session.parent_id"
```

---

## Task 5: OMP 从文件路径推导 root/label

**Files:**
- Modify: `Sources/TokenMeterCore/OmpUsageEventParser.swift`（加纯函数 `subagentAttribution`）
- Modify: `Sources/TokenMeterCore/LocalAgentScanner.swift`（omp 分支调纯函数 + 传 write override）
- Test: `Tests/TokenMeterCoreTests/OmpUsageEventParserTests.swift`（纯函数单测）+ `Tests/TokenMeterCoreTests/LocalAgentScannerTests.swift`（端到端）

**背景（spec §5.1）:** 主会话 `source_session_key` = `session` 行 UUID，而文件名/目录名形如 `<ISO时间戳>_<UUID>`。子文件所在目录名 == 父文件 basename。`root_session_key` 必须等于根主会话的 `source_session_key`（= 纯 UUID），因此要从顶层目录名里提取标准 UUID 段。相对路径（相对 scan root `~/.omp/agent/sessions`）：主会话 `<proj>/<file>.jsonl`（2 段）；子代理 `<proj>/<ts>_<UUID>/[.../]<label>.jsonl`（≥3 段）。

- [ ] **Step 1: 写失败测试**（纯函数 → `OmpUsageEventParserTests.swift`）

```swift
func testSubagentAttributionFromNestedPath() {
    // 一层子代理：<proj>/<ts>_<UUID>/Developer-X.jsonl
    let a = OmpUsageEventParser.subagentAttribution(
        relativePath: "-code-ai-x/2026-07-01T11-20-18Z_019f247b-3a29-7000-9fcd-9677ee2fec1e/Developer-X.jsonl")
    XCTAssertEqual(a.rootSessionKey, "019f247b-3a29-7000-9fcd-9677ee2fec1e")
    XCTAssertEqual(a.label, "Developer-X")
}

func testSubagentAttributionPinsGrandchildToRoot() {
    // 两层（孙代理）仍指向最顶层根 UUID（拍平）。
    let a = OmpUsageEventParser.subagentAttribution(
        relativePath: "-code-ai-x/2026-07-01T11-20-18Z_019f247b-3a29-7000-9fcd-9677ee2fec1e/Developer-X/Developer-X.Child.jsonl")
    XCTAssertEqual(a.rootSessionKey, "019f247b-3a29-7000-9fcd-9677ee2fec1e")
    XCTAssertEqual(a.label, "Developer-X.Child")
}

func testMainSessionPathHasNoAttribution() {
    let a = OmpUsageEventParser.subagentAttribution(
        relativePath: "-code-ai-x/2026-07-01T11-20-18Z_019f247b-3a29-7000-9fcd-9677ee2fec1e.jsonl")
    XCTAssertNil(a.rootSessionKey)
    XCTAssertNil(a.label)
}

func testNonUuidTopLevelDegradesToNoRoot() {
    // 顶层目录名不含标准 UUID（主会话曾回落到短 id）→ 无法关联，退化，不报错。
    let a = OmpUsageEventParser.subagentAttribution(relativePath: "-proj/2026-07-01T11-20Z_019f1d68/Child.jsonl")
    XCTAssertNil(a.rootSessionKey)
}
```

端到端（`LocalAgentScannerTests.swift`）：
```swift
func testOmpSubagentGetsRootSessionKeyFromPath() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let uuid = "019f247b-3a29-7000-9fcd-9677ee2fec1e"
    let proj = root.appendingPathComponent("-proj")
    let subdir = proj.appendingPathComponent("2026-07-01T11-20-18Z_\(uuid)")
    try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
    // 主会话文件（session 行 id == 纯 UUID）
    try writeJSONL("{\"type\":\"session\",\"id\":\"\(uuid)\",\"timestamp\":\"2026-07-08T01:00:00Z\",\"cwd\":\"/repo\"}\n{\"type\":\"message\",\"id\":\"m1\",\"timestamp\":\"2026-07-08T01:05:00Z\",\"message\":{\"role\":\"assistant\",\"model\":\"m\",\"usage\":{\"input\":10}}}",
        to: proj.appendingPathComponent("2026-07-01T11-20-18Z_\(uuid).jsonl"))
    // 子代理文件
    try writeJSONL("{\"type\":\"session\",\"id\":\"child-uuid\",\"timestamp\":\"2026-07-08T01:10:00Z\",\"cwd\":\"/repo\"}\n{\"type\":\"message\",\"id\":\"m2\",\"timestamp\":\"2026-07-08T01:11:00Z\",\"message\":{\"role\":\"assistant\",\"model\":\"m\",\"usage\":{\"input\":5}}}",
        to: subdir.appendingPathComponent("Developer-X.jsonl"))
    let database = try migratedDatabase(rootKind: .ompJSONL, rootPath: root.path)

    try await LocalAgentScanner(database: database).scanRoot(id: 1)

    XCTAssertEqual(try scalarText(database, "SELECT root_session_key FROM agent_sessions WHERE source_session_key = 'child-uuid'"), uuid)
    XCTAssertEqual(try scalarText(database, "SELECT subagent_label FROM agent_sessions WHERE source_session_key = 'child-uuid'"), "Developer-X")
    XCTAssertNil(try scalarTextOptional(database, "SELECT root_session_key FROM agent_sessions WHERE source_session_key = '\(uuid)'"))
}
```

若 `scalarText`/`scalarTextOptional` helper 尚不存在，在文件底部 helper 区加：
```swift
private func scalarText(_ database: SQLiteDatabase, _ sql: String) throws -> String? {
    try database.query(sql).first?.string("root_session_key")
        ?? database.query(sql).first?.string("subagent_label")
}
```
（更稳妥：直接在测试里用 `database.query(sql).first?.string("<列名>")` 取值，避免 helper 猜列名。执行时用后者。）

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter OmpUsageEventParserTests/testSubagentAttributionFromNestedPath`
Expected: FAIL（`OmpUsageEventParser` 无 `subagentAttribution` 方法，编译失败）。

- [ ] **Step 3: 实现**

`OmpUsageEventParser.swift` 加静态纯函数：
```swift
/// 从子代理文件相对 scan root 的路径推导 (根主会话 UUID, 子代理名字)。
/// 主会话（≤2 段）或顶层目录名不含标准 UUID → (nil, nil)（退化，不关联）。
public static func subagentAttribution(relativePath: String) -> (rootSessionKey: String?, label: String?) {
    let parts = relativePath.split(separator: "/").map(String.init)
    guard parts.count >= 3 else { return (nil, nil) }   // <proj>/<file>.jsonl 是主会话
    guard let uuid = standardUUID(in: parts[1]) else { return (nil, nil) }
    let label = parts[parts.count - 1].replacingOccurrences(of: ".jsonl", with: "")
    return (uuid, label.isEmpty ? nil : label)
}

private static let uuidRegex = try! NSRegularExpression(
    pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

private static func standardUUID(in text: String) -> String? {
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = uuidRegex.firstMatch(in: text, range: range),
          let r = Range(match.range, in: text) else { return nil }
    return String(text[r])
}
```

`LocalAgentScanner.swift` — 在第 375 行的 `writer.write(...)` 处，对 omp kind 传 override。改为：
```swift
let ompAttribution = root.kind == .ompJSONL
    ? OmpUsageEventParser.subagentAttribution(relativePath: relativePath)
    : (rootSessionKey: nil, label: nil)
try writer.write(session, scanRootId: root.id, sourceFileId: fileId, runId: runId,
                 rootSessionKeyOverride: ompAttribution.rootSessionKey,
                 subagentLabelOverride: ompAttribution.label)
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter OmpUsageEventParserTests && swift test --filter LocalAgentScannerTests/testOmpSubagentGetsRootSessionKeyFromPath`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenMeterCore/OmpUsageEventParser.swift Sources/TokenMeterCore/LocalAgentScanner.swift Tests/TokenMeterCoreTests/OmpUsageEventParserTests.swift Tests/TokenMeterCoreTests/LocalAgentScannerTests.swift
git commit -m "feat: derive OMP sub-agent's root session from its file path"
```

---

## Task 6: Claude 读 .meta.json 边车 → source_files.subagent_label

**Files:**
- Modify: `Sources/TokenMeterCore/LocalAgentScanner.swift`（读边车 + 一条 UPDATE）
- Test: `Tests/TokenMeterCoreTests/LocalAgentScannerTests.swift`

**背景（spec §5.4）:** Claude **不改解析归属**。子代理文件路径含 `/subagents/`，同名 `.meta.json` 边车里 `agentType` 是名字。写入 `source_files.subagent_label`。边车缺失/读取失败 → 留 NULL、不阻断。

- [ ] **Step 1: 写失败测试**（`LocalAgentScannerTests.swift`）

```swift
func testClaudeSubagentFileGetsLabelFromMetaSidecar() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sid = "shared-session"
    let subdir = root.appendingPathComponent("\(sid)/subagents")
    try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
    // 父会话文件（顶层）
    try writeJSONL(claudeJSONL(sessionKey: sid, inputTokens: 10, outputTokens: 20),
                   to: root.appendingPathComponent("\(sid).jsonl"))
    // 子代理文件：行内 sessionId 仍是父（归属不变），加 isSidechain
    try writeJSONL("{\"type\":\"assistant\",\"sessionId\":\"\(sid)\",\"isSidechain\":true,\"timestamp\":\"2026-07-08T01:05:00Z\",\"message\":{\"role\":\"assistant\",\"id\":\"sc1\",\"model\":\"claude-fable-5\",\"usage\":{\"input_tokens\":3,\"output_tokens\":1}}}",
                   to: subdir.appendingPathComponent("agent-abc123.jsonl"))
    // 边车
    try Data(#"{"agentType":"Explore","toolUseId":"tu-1","spawnDepth":1}"#.utf8)
        .write(to: subdir.appendingPathComponent("agent-abc123.meta.json"))
    let database = try migratedDatabase(rootKind: .claudeJSONL, rootPath: root.path)

    try await LocalAgentScanner(database: database).scanRoot(id: 1)

    let label = try database.query(
        "SELECT subagent_label FROM source_files WHERE relative_path = '\(sid)/subagents/agent-abc123.jsonl'"
    ).first?.string("subagent_label")
    XCTAssertEqual(label, "Explore")
    // 归属不变：子代理事件仍归父会话、标 sidechain。
    XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM usage_events WHERE is_sidechain = 1"), 1)
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter LocalAgentScannerTests/testClaudeSubagentFileGetsLabelFromMetaSidecar`
Expected: FAIL（`subagent_label` 为 nil）。

- [ ] **Step 3: 实现**

`LocalAgentScanner.swift` — 加两个私有方法：
```swift
/// Claude 子代理文件（路径含 /subagents/）的同名 .meta.json 里读 agentType。其它情况返回 nil。
private func claudeSubagentLabel(for file: URL, relativePath: String, kind: SourceKind) -> String? {
    guard kind == .claudeJSONL, relativePath.contains("/subagents/") else { return nil }
    let sidecar = file.deletingPathExtension().appendingPathExtension("meta.json")
    guard let data = try? Data(contentsOf: sidecar),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return JSONDictionary.string(object, "agentType")
}

private func setSourceFileSubagentLabel(fileId: Int64, label: String) throws {
    try database.execute("UPDATE source_files SET subagent_label = ? WHERE id = ?", [.text(label), .int(fileId)])
}
```

在第 375 行 `writer.write(...)` 成功之后（`try testHookAfterEventWrite?(fileId)` 之前或之后均可），加：
```swift
if let label = claudeSubagentLabel(for: file, relativePath: relativePath, kind: root.kind) {
    try setSourceFileSubagentLabel(fileId: fileId, label: label)
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter LocalAgentScannerTests/testClaudeSubagentFileGetsLabelFromMetaSidecar`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenMeterCore/LocalAgentScanner.swift Tests/TokenMeterCoreTests/LocalAgentScannerTests.swift
git commit -m "feat: label Claude sub-agent files from their .meta.json sidecar"
```

---

## 收尾：全量套件 + 真实重扫验证

- [ ] **Step 1: 跑全套 Swift 测试**

Run: `swift test`
Expected: 全绿（新增测试 + 原有 252 个）。

- [ ] **Step 2: 对真实语料做一次只读抽查**（不改生产库，仅确认填值符合预期）

用一份生产库副本（`TOKEN_METER_DB_PATH` 指向副本）跑一次全量重扫，然后抽查：
```sql
-- 各家有多少子会话被关联（应与 spec §2 覆盖率量级相符：OMP 数百、Codex/OpenCode 数十）
SELECT source_kind, count(*) FROM agent_sessions WHERE root_session_key IS NOT NULL GROUP BY source_kind;
-- Claude 子代理文件是否拿到名字
SELECT count(*) FROM source_files WHERE subagent_label IS NOT NULL;
```

Expected: OMP/Codex/OpenCode 的 `root_session_key` 非空计数量级合理；Claude `source_files.subagent_label` 非空。**不在生产库上跑，用副本。**

---

## Self-Review（写计划者自查记录）

- **Spec 覆盖**：§4 数据模型→Task 1；§5.1 OMP→Task 5；§5.2 Codex→Task 3；§5.3 OpenCode→Task 4；§5.4 Claude→Task 6；writer 写入→Task 2。§6 查询归并、§7 UI 属于 Plan 2，本 plan 明确不含。
- **退化路径**：Codex vanilla（无字段）→ Task 3 `testMainSessionHasNoRootAndNoSidechain`；OMP 非 UUID 顶层→ Task 5 `testNonUuidTopLevelDegradesToNoRoot`；均断言不报错。
- **类型一致**：`rootSessionKey`/`subagentLabel`（Swift）↔ `root_session_key`/`subagent_label`（SQL）全程一致；`write` override 参数名 `rootSessionKeyOverride`/`subagentLabelOverride` 在 Task 2 定义、Task 5 使用，一致。
- **不碰核心**：`RollupBuilder`、各家 token 采集/去重逻辑一行不动；Claude 解析归属不动（Task 6 只加一条 source_files UPDATE）。
