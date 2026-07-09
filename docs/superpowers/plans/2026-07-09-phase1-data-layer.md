# Phase 1：数据层 message 级改造 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 token 用量的记录粒度从「一个会话一行聚合」改成「一条 assistant API 响应一行明细」，使按天/按小时/按模型的统计成为可能，并让成本可离线自算。

**Architecture:** Swift 侧是唯一写入方：parser 输出 `[UsageEvent]` delta 事件流 → 去重 → 计价 → 写入 `usage_events` 明细表 → 重建 `daily_rollup` / `session_rollup` 两张物化汇总表。Electron 侧是唯一查询方，只读 SQLite 做聚合。Phase 1 结束时应用仍能启动、旧 UI 仍能显示，只是数字终于正确。

**Tech Stack:** Swift 5.9 / XCTest / SQLite（CSQLite）/ TypeScript / better-sqlite3 / Vitest

**Spec:** `docs/superpowers/specs/2026-07-09-dashboard-redesign-design.md`

---

## 关键背景（实现前必读）

三个数据源对 `input_tokens` 和 `output_tokens` 的定义**不一致**，这是本计划最容易出错的地方。以下由真实数据的算术恒等式验证：

| 源 | 恒等式 | 含义 |
|---|---|---|
| Codex | `total = input + output` | `cached_input ⊂ input`，`reasoning ⊂ output` |
| omp | `total = input + output + cacheRead` | cache 独立于 input，`reasoning ⊂ output` |
| Claude Code | 无 total 字段 | `input_tokens` 不含 cache |
| OpenCode | 无 total 字段 | cache 独立于 input |

归一后的 `UsageEvent` 字段语义**固定**为：

- `inputTokens` — 非缓存输入
- `cacheReadTokens` — 缓存读取，与 `inputTokens` 不重叠
- `outputTokens` — 输出，**已包含** reasoning
- `reasoningTokens` — `outputTokens` 的子集，仅供展示，**不计入 total**

因此 **Codex adapter 必须做 `inputTokens = input_tokens - cached_input_tokens` 这个减法**，其余三个源原样取值。不做这个减法，Codex 的 token 会被计成近两倍。

### 流式约束（不可退化）

基线 commit `13ae94a` 已经把 parser 改成了**流式**：`LocalAgentSessionStreamingParser` 协议提供 `consume(_:)` / `finish(_:)`，`JSONLStreamReader.readLines(from:startingAt:onLine:)` 逐行回调。

**必须保持流式。** 本机最大的 Codex session 文件是 3.28 GB / 257,115 行。任何返回 `[JSONLLine]` 数组的路径都会把整个文件materialize进内存。

要流式的是**行**，不是**事件**：那个文件里只有 36,293 条 `token_count`，转成 `UsageEvent` 约 3.6 MB，累积在内存里毫无压力。所以 `finish()` 返回完整的 `[UsageEvent]` 是安全的。

parser 因此是 `class`（`consume` 要改内部状态），协议加 `AnyObject` 约束。为了让测试可读，协议扩展提供一个静态便利方法一次性喂完所有行——**生产路径不得使用它**。

### 新旧 parser 并存（不可跳过）

基线里的 `LocalAgentSessionParser` / `LocalAgentSessionStreamingParser` 被 `LocalAgentScanner` 和三个 parser 测试文件使用。如果 Task 6 直接改写它们，`swift build` 会从 Task 6 一路红到 Task 11——中间八个任务都失去「跑测试确认没搞砸」的能力，而一片红里再多一个红点谁也看不出来。这和 Task 3 不删 v1 表是同一个理由。

因此新 parser **全部新建文件、新命名**，旧的一行不动：

| 旧（保留至 Task 18） | 新（Task 6–10 新增） |
|---|---|
| `LocalAgentSessionParser`、`LocalAgentSessionStreamingParser` | `UsageEventParser` |
| `ClaudeCodeSessionParser`、`ClaudeCodeStreamingParser` | `ClaudeCodeUsageEventParser` |
| `CodexSessionParser`、`CodexStreamingParser` | `CodexUsageEventParser` |
| `OmpSessionParser`、`OmpStreamingParser` | `OmpUsageEventParser` |
| `OpenCodeSessionAdapter` | `OpenCodeUsageEventAdapter` |

Task 14 把 `LocalAgentScanner` 切到新 parser 与 `UsageEventWriter`，此刻旧 parser 成为死代码。Task 18 连同 v1 表一起删除它们。

**Task 6 到 Task 13，每一个任务结束时 `swift test` 都必须全绿。** 任何一个变红都说明动了不该动的东西。

---

## File Structure

**新建：**

| 文件 | 职责 |
|---|---|
| `Sources/TokenMeterCore/UsageEventModels.swift` | `UsageEvent` / `ParsedSession` / `ParserState` 类型 |
| `Sources/TokenMeterCore/UsageEventParsers.swift` | 流式协议 `UsageEventParser` |
| `Sources/TokenMeterCore/ClaudeCodeUsageEventParser.swift` | Claude adapter |
| `Sources/TokenMeterCore/CodexUsageEventParser.swift` | Codex adapter |
| `Sources/TokenMeterCore/OmpUsageEventParser.swift` | omp adapter |
| `Sources/TokenMeterCore/OpenCodeUsageEventAdapter.swift` | OpenCode adapter |
| `Sources/TokenMeterCore/ModelNameNormalizer.swift` | 模型名归一 |
| `Sources/TokenMeterCore/UsageEventDeduplicator.swift` | 去重规则 |
| `Sources/TokenMeterCore/Pricing.swift` | `ModelPricing` / `PricingSnapshot` 加载 |
| `Sources/TokenMeterCore/CostCalculator.swift` | 计价 |
| `Sources/TokenMeterCore/UsageEventWriter.swift` | 写 `usage_events` |
| `Sources/TokenMeterCore/RollupBuilder.swift` | 重建两张汇总表 |
| `Sources/TokenMeterCore/Resources/litellm-pricing.json` | 定价快照（由脚本生成） |
| `scripts/update-pricing.sh` | 手动拉取 LiteLLM 并转换 |
| `scripts/transform_pricing.py` | 转换脚本 |
| `scripts/reconcile-with-ccusage.sh` | 与 ccusage 对账 |

**改造：**

| 文件 | 改动 |
|---|---|
| `Sources/TokenMeterCore/TokenMeterDatabaseSchema.swift` | 新增 `v2` 与 `dropV1Tables` |
| `Sources/TokenMeterCore/TokenMeterDatabaseMigrator.swift` | v0→v2 与 v1→v2 两条路径 |
| `Sources/TokenMeterCore/JSONLStreamReader.swift` | 逐字节循环重写 + 字节预筛（onLine 版本已在基线中） |
| `Sources/TokenMeterCore/LocalAgentScanner.swift` | 断点续读按 `source_file_id` |
| `Package.swift` | `TokenMeterCore` 增加 `resources` |
| `Electron/src/main/dashboardRepository.ts` | 改查 `daily_rollup` |
| `Electron/src/main/sessionsRepository.ts` | 改查 `session_rollup` |

**删除：** `LocalAgentModels.swift` 中的 `ParsedSessionUsage` / `ParsedAgentSession` / `ParsedSessionUsageKind`（被 `UsageEventModels.swift` 取代）。

---

## Task 1: UsageEvent / ParsedSession / ParserState 类型

**Files:**
- Create: `Sources/TokenMeterCore/UsageEventModels.swift`
- Test: `Tests/TokenMeterCoreTests/UsageEventModelsTests.swift`

- [ ] **Step 1: 写失败的测试**

`Tests/TokenMeterCoreTests/UsageEventModelsTests.swift`：

```swift
import XCTest
@testable import TokenMeterCore

final class UsageEventModelsTests: XCTestCase {
    func testTotalTokensExcludesReasoning() {
        let event = UsageEvent(
            eventSeq: 1,
            observedAt: Date(timeIntervalSince1970: 0),
            inputTokens: 100,
            outputTokens: 50,
            reasoningTokens: 20,
            cacheReadTokens: 900,
            sourceOffset: 0
        )
        // reasoning 是 output 的子集，不参与求和
        XCTAssertEqual(event.totalTokens, 1050)
    }

    func testTotalTokensSumsBothCacheWriteTiers() {
        let event = UsageEvent(
            eventSeq: 1,
            observedAt: Date(timeIntervalSince1970: 0),
            inputTokens: 10,
            outputTokens: 5,
            cacheWrite5mTokens: 100,
            cacheWrite1hTokens: 200,
            sourceOffset: 0
        )
        XCTAssertEqual(event.totalTokens, 315)
    }

    func testDedupeKeyCombinesMessageAndRequestId() {
        let event = UsageEvent(
            eventSeq: 1,
            observedAt: Date(timeIntervalSince1970: 0),
            messageId: "msg_1",
            requestId: "req_1",
            sourceOffset: 0
        )
        XCTAssertEqual(event.dedupeKey, "msg_1\u{1F}req_1")
    }

    func testDedupeKeyIsNilWhenEitherIdMissing() {
        let event = UsageEvent(
            eventSeq: 1,
            observedAt: Date(timeIntervalSince1970: 0),
            messageId: "msg_1",
            requestId: nil,
            sourceOffset: 0
        )
        XCTAssertNil(event.dedupeKey)
    }

    func testParserStateRoundTripsThroughJSON() throws {
        let state = ParserState(
            lastEventSeq: 7,
            lastCumulative: CumulativeTokenTotals(inputTokens: 100, cachedInputTokens: 90, outputTokens: 10, reasoningTokens: 2)
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(ParserState.self, from: data)
        XCTAssertEqual(decoded, state)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter UsageEventModelsTests`
Expected: 编译失败，`cannot find 'UsageEvent' in scope`

- [ ] **Step 3: 实现**

`Sources/TokenMeterCore/UsageEventModels.swift`：

```swift
import Foundation

/// 一条 assistant API 响应的用量。
///
/// 字段语义已跨源归一（见 spec 4.3.1）：
/// - `inputTokens` 不含缓存
/// - `cacheReadTokens` 与 `inputTokens` 不重叠
/// - `outputTokens` 已包含 `reasoningTokens`
/// - `reasoningTokens` 仅供展示，不计入 `totalTokens`
public struct UsageEvent: Equatable {
    public let eventSeq: Int
    public let observedAt: Date
    public let modelName: String?
    public let messageId: String?
    public let requestId: String?
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let reasoningTokens: Int64
    public let cacheReadTokens: Int64
    public let cacheWrite5mTokens: Int64
    public let cacheWrite1hTokens: Int64
    public let reportedCostUSDMicros: Int64?
    public let sourceOffset: Int64
    public let isSidechain: Bool

    public init(
        eventSeq: Int,
        observedAt: Date,
        modelName: String? = nil,
        messageId: String? = nil,
        requestId: String? = nil,
        inputTokens: Int64 = 0,
        outputTokens: Int64 = 0,
        reasoningTokens: Int64 = 0,
        cacheReadTokens: Int64 = 0,
        cacheWrite5mTokens: Int64 = 0,
        cacheWrite1hTokens: Int64 = 0,
        reportedCostUSDMicros: Int64? = nil,
        sourceOffset: Int64,
        isSidechain: Bool = false
    ) {
        self.eventSeq = eventSeq
        self.observedAt = observedAt
        self.modelName = modelName
        self.messageId = messageId
        self.requestId = requestId
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWrite5mTokens = cacheWrite5mTokens
        self.cacheWrite1hTokens = cacheWrite1hTokens
        self.reportedCostUSDMicros = reportedCostUSDMicros
        self.sourceOffset = sourceOffset
        self.isSidechain = isSidechain
    }

    /// `reasoningTokens` 不计入：它已包含在 `outputTokens` 里。
    public var totalTokens: Int64 {
        inputTokens + outputTokens + cacheReadTokens + cacheWrite5mTokens + cacheWrite1hTokens
    }

    /// 仅当 messageId 与 requestId 都存在时才构成去重键。
    public var dedupeKey: String? {
        guard let messageId, let requestId else { return nil }
        return "\(messageId)\u{1F}\(requestId)"
    }

    public var observedEpochMilliseconds: Int64 {
        Int64((observedAt.timeIntervalSince1970 * 1000).rounded())
    }
}

public struct ParsedSession: Equatable {
    public let sourceKind: SourceKind
    public let sessionKey: String
    public let projectPath: String?
    public let cliVersion: String?
    public let startedAt: Date?
    public let updatedAt: Date?
    public let events: [UsageEvent]
    public let rawMeta: [String: String]

    public init(
        sourceKind: SourceKind,
        sessionKey: String,
        projectPath: String?,
        cliVersion: String?,
        startedAt: Date?,
        updatedAt: Date?,
        events: [UsageEvent],
        rawMeta: [String: String]
    ) {
        self.sourceKind = sourceKind
        self.sessionKey = sessionKey
        self.projectPath = projectPath
        self.cliVersion = cliVersion
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.events = events
        self.rawMeta = rawMeta
    }
}

/// Codex 的 `token_count` 事件存累计值，增量续读时需要上一次的基线。
public struct CumulativeTokenTotals: Equatable, Codable {
    public var inputTokens: Int64
    public var cachedInputTokens: Int64
    public var outputTokens: Int64
    public var reasoningTokens: Int64

    public init(inputTokens: Int64 = 0, cachedInputTokens: Int64 = 0, outputTokens: Int64 = 0, reasoningTokens: Int64 = 0) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
    }
}

/// 持久化到 `source_files.parser_state`，用于单文件断点续读。
public struct ParserState: Equatable, Codable {
    public var lastEventSeq: Int
    public var lastCumulative: CumulativeTokenTotals?

    public init(lastEventSeq: Int = 0, lastCumulative: CumulativeTokenTotals? = nil) {
        self.lastEventSeq = lastEventSeq
        self.lastCumulative = lastCumulative
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter UsageEventModelsTests`
Expected: `Executed 5 tests, with 0 failures`

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenMeterCore/UsageEventModels.swift Tests/TokenMeterCoreTests/UsageEventModelsTests.swift
git commit -m "feat: add message-level UsageEvent model"
```

---

## Task 2: ModelNameNormalizer

**Files:**
- Create: `Sources/TokenMeterCore/ModelNameNormalizer.swift`
- Test: `Tests/TokenMeterCoreTests/ModelNameNormalizerTests.swift`

- [ ] **Step 1: 写失败的测试**

```swift
import XCTest
@testable import TokenMeterCore

final class ModelNameNormalizerTests: XCTestCase {
    func testKeepsAlreadyCanonicalName() {
        XCTAssertEqual(ModelNameNormalizer.canonical("claude-fable-5"), "claude-fable-5")
    }

    func testStripsEightDigitDateSuffix() {
        XCTAssertEqual(ModelNameNormalizer.canonical("claude-opus-4-8-20260101"), "claude-opus-4-8")
    }

    func testStripsProviderPrefix() {
        XCTAssertEqual(ModelNameNormalizer.canonical("vertex_ai/claude-sonnet-4"), "claude-sonnet-4")
        XCTAssertEqual(ModelNameNormalizer.canonical("bedrock/claude-haiku-4-5"), "claude-haiku-4-5")
    }

    func testStripsPrefixAndSuffixTogether() {
        XCTAssertEqual(ModelNameNormalizer.canonical("anthropic/claude-opus-4-8-20260101"), "claude-opus-4-8")
    }

    func testLowercases() {
        XCTAssertEqual(ModelNameNormalizer.canonical("GPT-5.5"), "gpt-5.5")
    }

    func testDoesNotStripVersionThatIsNotEightDigits() {
        XCTAssertEqual(ModelNameNormalizer.canonical("glm-4.6"), "glm-4.6")
        XCTAssertEqual(ModelNameNormalizer.canonical("claude-opus-4-8"), "claude-opus-4-8")
    }

    func testNilAndEmptyBecomeUnknown() {
        XCTAssertEqual(ModelNameNormalizer.canonical(nil), "unknown")
        XCTAssertEqual(ModelNameNormalizer.canonical(""), "unknown")
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter ModelNameNormalizerTests`
Expected: 编译失败，`cannot find 'ModelNameNormalizer' in scope`

- [ ] **Step 3: 实现**

`Sources/TokenMeterCore/ModelNameNormalizer.swift`：

```swift
import Foundation

public enum ModelNameNormalizer {
    public static let unknown = "unknown"

    private static let providerPrefixes = [
        "vertex_ai/",
        "bedrock/",
        "anthropic/",
        "openai/",
        "openai-codex/",
        "zai/"          // LiteLLM 用 zai/glm-4.6 作 key，OpenCode 上报的是裸 glm-4.6
    ]

    public static func canonical(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return unknown }

        var name = raw.lowercased()

        for prefix in providerPrefixes where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
            break
        }

        if let range = name.range(of: "-[0-9]{8}$", options: .regularExpression) {
            name.removeSubrange(range)
        }

        return name.isEmpty ? unknown : name
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter ModelNameNormalizerTests`
Expected: `Executed 7 tests, with 0 failures`

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenMeterCore/ModelNameNormalizer.swift Tests/TokenMeterCoreTests/ModelNameNormalizerTests.swift
git commit -m "feat: add model name normalizer"
```

---

## Task 3: schema v2（只做加法）

旧数据的日期归属与模型归属本来就是错的，**不迁移旧数据**。但也**不在本任务里删表**。

原因：`LocalAgentUsageRepository` 与 `LocalAgentScanner` 要到 Task 11 / Task 14 才切换到新表。如果 Task 3 就 DROP 掉 `session_usage` / `session_usage_latest` / `provider_daily_usage`，那么 Task 3 到 Task 10 这八个任务期间旧代码会往不存在的表里写，`swift test` 全程飘红，每个任务都失去「跑测试确认没搞砸」的能力。

因此 v2 只做加法：新表与旧表并存，旧代码继续绿着跑。**Task 18** 在 scanner 切换完成、旧表彻底无人写入之后，才把它们删掉并清空扫描游标。

`v1` 里全是 `CREATE TABLE IF NOT EXISTS`，所以 migrator 可以顺序执行 `v1` 再执行 `v2Additions`：全新库两段都跑，v1 老库只跑第二段。

**Files:**
- Modify: `Sources/TokenMeterCore/TokenMeterDatabaseSchema.swift`
- Modify: `Sources/TokenMeterCore/TokenMeterDatabaseMigrator.swift`
- Test: `Tests/TokenMeterCoreTests/TokenMeterDatabaseMigratorTests.swift`

- [ ] **Step 1: 写失败的测试**

追加到 `Tests/TokenMeterCoreTests/TokenMeterDatabaseMigratorTests.swift`：

```swift
    func testMigratesFreshDatabaseToVersion2() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)

        let version = try database.query("PRAGMA user_version")[0].int("user_version")
        XCTAssertEqual(version, 2)

        let tables = try database.query("SELECT name FROM sqlite_master WHERE type = 'table'")
            .compactMap { $0.string("name") }
        XCTAssertTrue(tables.contains("usage_events"))
        XCTAssertTrue(tables.contains("daily_rollup"))
        XCTAssertTrue(tables.contains("session_rollup"))
        XCTAssertTrue(tables.contains("model_pricing"))
    }

    func testMigrationFromV1AddsNewTablesAndKeepsLegacyOnes() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try database.execute(TokenMeterDatabaseSchema.v1)
        try database.execute(
            """
            INSERT INTO scan_roots(kind, root_path, display_name, stable_source_key, last_successful_cursor)
            VALUES ('claude_jsonl', '/tmp/claude', 'Claude', 'claude:/tmp/claude', 'cursor-123')
            """
        )

        try TokenMeterDatabaseMigrator.migrate(database)

        let tables = try database.query("SELECT name FROM sqlite_master WHERE type = 'table'")
            .compactMap { $0.string("name") }

        // 新表出现
        XCTAssertTrue(tables.contains("usage_events"))
        XCTAssertTrue(tables.contains("daily_rollup"))
        XCTAssertTrue(tables.contains("session_rollup"))
        XCTAssertTrue(tables.contains("model_pricing"))

        // 旧表保留：LocalAgentUsageRepository 与 LocalAgentScanner 要到 Task 11 / 14
        // 才切换过去。提前删表会让 Task 3-10 期间的测试全线飘红。Task 18 负责清理。
        XCTAssertTrue(tables.contains("session_usage"))
        XCTAssertTrue(tables.contains("session_usage_latest"))
        XCTAssertTrue(tables.contains("provider_daily_usage"))

        // 扫描游标此刻不动：切换完成前重扫没有意义。Task 18 清空它。
        let roots = try database.query("SELECT root_path, last_successful_cursor FROM scan_roots")
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots[0].string("last_successful_cursor"), "cursor-123")
    }

    func testMigrationIsIdempotent() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)
        try TokenMeterDatabaseMigrator.migrate(database)

        XCTAssertEqual(try database.query("PRAGMA user_version")[0].int("user_version"), 2)
    }

    func testUsageEventsTotalTokensGeneratedColumnExcludesReasoning() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)
        try database.execute(
            """
            INSERT INTO scan_roots(id, kind, root_path, display_name, stable_source_key)
            VALUES (1, 'claude_jsonl', '/tmp/c', 'C', 'c')
            """
        )
        try database.execute(
            """
            INSERT INTO source_files(id, scan_root_id, relative_path, canonical_path, file_type, size_bytes, mtime_ns)
            VALUES (1, 1, 'a.jsonl', '/tmp/c/a.jsonl', 'jsonl_session', 1, 1)
            """
        )
        try database.execute(
            """
            INSERT INTO agent_sessions(id, source_kind, source_session_key, scan_root_id, source_revision)
            VALUES (1, 'claude_jsonl', 's1', 1, 'rev')
            """
        )
        try database.execute(
            """
            INSERT INTO usage_events(
                session_id, source_file_id, event_seq, observed_epoch_ms,
                tokens_input, tokens_output, tokens_reasoning, tokens_cache_read,
                cost_source, source_offset
            ) VALUES (1, 1, 1, 0, 100, 50, 20, 900, 'unknown', 0)
            """
        )

        let total = try database.query("SELECT tokens_total FROM usage_events")[0].int("tokens_total")
        XCTAssertEqual(total, 1050)
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter TokenMeterDatabaseMigratorTests`
Expected: FAIL，`XCTAssertEqual failed: ("1") is not equal to ("2")`

- [ ] **Step 3: 实现**

在 `Sources/TokenMeterCore/TokenMeterDatabaseSchema.swift` 中把 `currentVersion` 改为 `2`，**保留 `v1` 常量原样不动**（迁移测试需要它构造旧库，且它全是 `CREATE TABLE IF NOT EXISTS`），新增 `v2Additions`：

```swift
    /// v2 只做加法：新增四张表，不触碰 v1 的任何表。
    /// v1 全是 CREATE TABLE IF NOT EXISTS，migrator 顺序执行两段即可：
    /// 全新库跑 v1 + v2Additions，v1 老库只跑 v2Additions。
    /// 旧表的删除与扫描游标清空由 Task 18 负责，那时 scanner 已切换完毕。
    public static let v2Additions = """
    CREATE TABLE IF NOT EXISTS usage_events (
      id INTEGER PRIMARY KEY,
      session_id INTEGER NOT NULL REFERENCES agent_sessions(id) ON DELETE CASCADE,
      source_file_id INTEGER NOT NULL REFERENCES source_files(id) ON DELETE CASCADE,
      event_seq INTEGER NOT NULL,
      observed_epoch_ms INTEGER NOT NULL,
      model_name TEXT,
      model_canonical TEXT,
      tokens_input INTEGER NOT NULL DEFAULT 0,
      tokens_output INTEGER NOT NULL DEFAULT 0,
      tokens_reasoning INTEGER NOT NULL DEFAULT 0,
      tokens_cache_read INTEGER NOT NULL DEFAULT 0,
      tokens_cache_write_5m INTEGER NOT NULL DEFAULT 0,
      tokens_cache_write_1h INTEGER NOT NULL DEFAULT 0,
      tokens_total INTEGER GENERATED ALWAYS AS (
        tokens_input + tokens_output +
        tokens_cache_read + tokens_cache_write_5m + tokens_cache_write_1h
      ) VIRTUAL,
      cost_usd_micros INTEGER,
      cost_source TEXT NOT NULL CHECK (cost_source IN ('reported', 'computed', 'unknown')),
      dedupe_key TEXT,
      source_offset INTEGER NOT NULL,
      is_sidechain INTEGER NOT NULL DEFAULT 0 CHECK (is_sidechain IN (0,1)),
      UNIQUE(source_file_id, event_seq)
    );

    CREATE UNIQUE INDEX IF NOT EXISTS idx_usage_dedupe
      ON usage_events(session_id, dedupe_key) WHERE dedupe_key IS NOT NULL;
    CREATE INDEX IF NOT EXISTS idx_usage_time ON usage_events(observed_epoch_ms);
    CREATE INDEX IF NOT EXISTS idx_usage_session ON usage_events(session_id, observed_epoch_ms);
    CREATE INDEX IF NOT EXISTS idx_usage_model_time ON usage_events(model_canonical, observed_epoch_ms);
    CREATE INDEX IF NOT EXISTS idx_usage_source_file ON usage_events(source_file_id, source_offset DESC);

    CREATE TABLE IF NOT EXISTS daily_rollup (
      usage_date TEXT NOT NULL,
      provider_id TEXT NOT NULL,
      source_kind TEXT NOT NULL,
      project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL,
      model_canonical TEXT NOT NULL,
      sessions_count INTEGER NOT NULL DEFAULT 0,
      events_count INTEGER NOT NULL DEFAULT 0,
      tokens_input INTEGER NOT NULL DEFAULT 0,
      tokens_output INTEGER NOT NULL DEFAULT 0,
      tokens_reasoning INTEGER NOT NULL DEFAULT 0,
      tokens_cache_read INTEGER NOT NULL DEFAULT 0,
      tokens_cache_write_5m INTEGER NOT NULL DEFAULT 0,
      tokens_cache_write_1h INTEGER NOT NULL DEFAULT 0,
      cost_usd_micros INTEGER NOT NULL DEFAULT 0,
      cost_unknown_events INTEGER NOT NULL DEFAULT 0
    );

    CREATE UNIQUE INDEX IF NOT EXISTS idx_daily_rollup_unique
      ON daily_rollup(usage_date, provider_id, source_kind, coalesce(project_id, -1), model_canonical);
    CREATE INDEX IF NOT EXISTS idx_daily_rollup_date ON daily_rollup(usage_date DESC);
    CREATE INDEX IF NOT EXISTS idx_daily_rollup_model ON daily_rollup(model_canonical, usage_date DESC);

    CREATE TABLE IF NOT EXISTS session_rollup (
      session_id INTEGER PRIMARY KEY REFERENCES agent_sessions(id) ON DELETE CASCADE,
      first_event_epoch_ms INTEGER NOT NULL,
      last_event_epoch_ms INTEGER NOT NULL,
      events_count INTEGER NOT NULL,
      tokens_total INTEGER NOT NULL,
      cost_usd_micros INTEGER NOT NULL,
      -- 与 daily_rollup 对齐：sum() 会静默跳过 cost 为 NULL 的行，
      -- 会话中途换到未定价的模型时，金额会偏低却看起来精确。
      cost_unknown_events INTEGER NOT NULL DEFAULT 0,
      primary_model TEXT
    );

    CREATE INDEX IF NOT EXISTS idx_session_rollup_last ON session_rollup(last_event_epoch_ms DESC);

    CREATE TABLE IF NOT EXISTS model_pricing (
      model_key TEXT PRIMARY KEY,
      input_per_mtok_micros INTEGER NOT NULL,
      output_per_mtok_micros INTEGER NOT NULL,
      cache_read_per_mtok_micros INTEGER NOT NULL,
      cache_write_5m_per_mtok_micros INTEGER NOT NULL,
      cache_write_1h_per_mtok_micros INTEGER NOT NULL,
      source TEXT NOT NULL CHECK (source IN ('litellm', 'builtin', 'user')),
      snapshot_version TEXT
    );

    INSERT OR IGNORE INTO schema_migrations(version, name) VALUES (2, 'phase3_message_level_usage');
    PRAGMA user_version = 2;
    """
```

`Sources/TokenMeterCore/TokenMeterDatabaseMigrator.swift` 全文替换为：

```swift
public enum TokenMeterDatabaseMigrator {
    public static func migrate(_ database: SQLiteDatabase) throws {
        try database.execute("PRAGMA journal_mode = WAL")
        try database.execute("PRAGMA synchronous = NORMAL")
        try database.execute("PRAGMA foreign_keys = ON")
        try database.execute("PRAGMA temp_store = MEMORY")
        try database.execute("PRAGMA busy_timeout = 5000")

        let currentVersion = try database.query("PRAGMA user_version")[0].int("user_version") ?? 0
        guard currentVersion <= TokenMeterDatabaseSchema.currentVersion else {
            throw TokenMeterDatabaseMigratorError.unsupportedNewerVersion(currentVersion)
        }
        guard currentVersion < TokenMeterDatabaseSchema.currentVersion else { return }

        // v1 全是 CREATE TABLE IF NOT EXISTS，重复执行安全。
        // 全新库两段都跑；v1 老库跳过第一段，只补上新表。
        if currentVersion < 1 {
            try database.execute(TokenMeterDatabaseSchema.v1)
        }
        try database.execute(TokenMeterDatabaseSchema.v2Additions)
    }
}

public enum TokenMeterDatabaseMigratorError: Error, Equatable {
    case unsupportedNewerVersion(Int64)
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter TokenMeterDatabaseMigratorTests`
Expected: 全部通过。若 `testUsageEventsTotalTokensGeneratedColumnExcludesReasoning` 返回 1070 而非 1050，说明生成列错误地加上了 `tokens_reasoning`。

再跑一次完整套件：

Run: `swift test`
Expected: 全绿。**这是本任务最重要的验收**——因为 v2 只做加法，`LocalAgentUsageRepository` 和 `LocalAgentScanner` 的既有测试必须一个不少地继续通过。任何一个变红，都说明动了不该动的表。

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenMeterCore/TokenMeterDatabaseSchema.swift Sources/TokenMeterCore/TokenMeterDatabaseMigrator.swift Tests/TokenMeterCoreTests/TokenMeterDatabaseMigratorTests.swift
git commit -m "feat: add schema v2 tables alongside v1"
```

---

## Task 4: 定价快照与更新脚本

不手写价格。脚本从 LiteLLM 拉取并转换，产物提交进仓库；运行时完全离线。

**Files:**
- Create: `scripts/transform_pricing.py`
- Create: `scripts/update-pricing.sh`
- Create: `Sources/TokenMeterCore/Resources/litellm-pricing.json`（由脚本生成）
- Create: `Sources/TokenMeterCore/Pricing.swift`
- Modify: `Package.swift`
- Test: `Tests/TokenMeterCoreTests/PricingTests.swift`

- [ ] **Step 1: 写转换脚本**

`scripts/transform_pricing.py`：

```python
#!/usr/bin/env python3
"""把 LiteLLM 的定价表转成 TokenMeter 的快照格式。

LiteLLM 的价格是「每 token 美元」，输出改成「每百万 token 美元」。
LiteLLM 未显式给出 cache 费率时按 ccgauge 已验证的默认值派生。
从 stdin 读 LiteLLM JSON，往 stdout 写快照 JSON。
"""
import json
import sys
from datetime import date

# 注意：LiteLLM 已把智谱的 provider slug 从 zhipuai 改成 zai。
# 写成 zhipuai 会让 glm-4.6 等模型一条定价都拿不到，成本静默变成 unknown。
KEEP_PROVIDERS = {"anthropic", "openai", "vertex_ai-anthropic_models", "bedrock", "zai"}
M = 1_000_000


def main() -> None:
    raw = json.load(sys.stdin)
    models = {}

    for name, spec in raw.items():
        if name == "sample_spec" or not isinstance(spec, dict):
            continue
        if spec.get("mode") != "chat":
            continue
        if spec.get("litellm_provider") not in KEEP_PROVIDERS:
            continue

        input_cost = spec.get("input_cost_per_token")
        output_cost = spec.get("output_cost_per_token")
        if not input_cost or not output_cost:
            continue

        input_m = input_cost * M
        output_m = output_cost * M
        cache_read = spec.get("cache_read_input_token_cost")
        cache_write = spec.get("cache_creation_input_token_cost")
        # LiteLLM 有 113 个模型给出了真实的 1h 缓存写入价，用它。
        # 别硬编码 input*2：claude-3-opus 的实际比值是 0.40，claude-3-haiku 是 24.00。
        cache_write_1h = spec.get("cache_creation_input_token_cost_above_1hr")

        # 必须用 `is not None` 而不是真值判断。
        # LiteLLM 把「免费」显式写成 0（glm 全系列的 cache_creation 都是 0），
        # `if cache_write` 会把这个 0 当成「字段缺失」，进而按 input*1.25 给免费的东西收费。
        # 「免费」和「不知道」是两件事，正如 cost_usd_micros 用 NULL 而不是 0。
        models[name] = {
            "inputPerMTok": round(input_m, 6),
            "outputPerMTok": round(output_m, 6),
            "cacheReadPerMTok": round(cache_read * M if cache_read is not None else input_m * 0.1, 6),
            "cacheWrite5mPerMTok": round(cache_write * M if cache_write is not None else input_m * 1.25, 6),
            "cacheWrite1hPerMTok": round(cache_write_1h * M if cache_write_1h is not None else input_m * 2.0, 6),
        }

    json.dump(
        {"snapshotVersion": date.today().isoformat(), "source": "litellm", "models": models},
        sys.stdout,
        indent=2,
        sort_keys=True,
    )
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
```

`scripts/update-pricing.sh`：

```bash
#!/usr/bin/env bash
# 手动运行，联网拉取 LiteLLM 定价表并写回仓库。产物需提交。
set -euo pipefail

URL="https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
OUT="Sources/TokenMeterCore/Resources/litellm-pricing.json"

mkdir -p "$(dirname "$OUT")"
curl -fsSL "$URL" | python3 scripts/transform_pricing.py > "$OUT"

count=$(python3 -c "import json;print(len(json.load(open('$OUT'))['models']))")
echo "wrote $OUT with $count models"
```

- [ ] **Step 2: 运行脚本生成快照**

```bash
chmod +x scripts/update-pricing.sh
./scripts/update-pricing.sh
```

Expected: `wrote Sources/TokenMeterCore/Resources/litellm-pricing.json with N models`（N 应为三位数）

若脚本输出 0 个模型，说明 LiteLLM 改了 `litellm_provider` 的取值，需要先 `curl "$URL" | python3 -c "import json,sys,collections;print(collections.Counter(v.get('litellm_provider') for v in json.load(sys.stdin).values() if isinstance(v,dict)).most_common(20))"` 查看真实取值再修 `KEEP_PROVIDERS`。

- [ ] **Step 3: 写失败的测试**

`Tests/TokenMeterCoreTests/PricingTests.swift`：

```swift
import XCTest
@testable import TokenMeterCore

final class PricingTests: XCTestCase {
    func testLoadsBundledSnapshot() throws {
        let snapshot = try PricingSnapshot.loadBundled()
        XCTAssertFalse(snapshot.snapshotVersion.isEmpty)
        XCTAssertEqual(snapshot.source, "litellm")
        XCTAssertGreaterThan(snapshot.models.count, 50)
    }

    func testBundledSnapshotContainsModelsUsedOnThisMachine() throws {
        let snapshot = try PricingSnapshot.loadBundled()
        // 快照的 key 是 LiteLLM 原始名，用归一化后的前缀匹配即可
        let canonicalKeys = Set(snapshot.models.keys.map(ModelNameNormalizer.canonical))
        XCTAssertTrue(canonicalKeys.contains { $0.contains("opus") }, "缺少 opus 系列定价")
        XCTAssertTrue(canonicalKeys.contains { $0.contains("sonnet") }, "缺少 sonnet 系列定价")
    }

    func testDecodesModelPricing() throws {
        let json = """
        {
          "snapshotVersion": "2026-07-09",
          "source": "litellm",
          "models": {
            "claude-opus-4-8": {
              "inputPerMTok": 15.0,
              "outputPerMTok": 75.0,
              "cacheReadPerMTok": 1.5,
              "cacheWrite5mPerMTok": 18.75,
              "cacheWrite1hPerMTok": 30.0
            }
          }
        }
        """
        let snapshot = try JSONDecoder().decode(PricingSnapshot.self, from: Data(json.utf8))
        let pricing = try XCTUnwrap(snapshot.models["claude-opus-4-8"])
        XCTAssertEqual(pricing.inputPerMTok, 15.0)
        XCTAssertEqual(pricing.cacheWrite1hPerMTok, 30.0)
    }
}
```

- [ ] **Step 4: 实现**

`Package.swift` 中给 `TokenMeterCore` 目标加资源：

```swift
        .target(
            name: "TokenMeterCore",
            dependencies: ["CSQLite"],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
```

`Sources/TokenMeterCore/Pricing.swift`：

```swift
import Foundation

public struct ModelPricing: Equatable, Codable {
    public let inputPerMTok: Double
    public let outputPerMTok: Double
    public let cacheReadPerMTok: Double
    public let cacheWrite5mPerMTok: Double
    public let cacheWrite1hPerMTok: Double

    public init(
        inputPerMTok: Double,
        outputPerMTok: Double,
        cacheReadPerMTok: Double,
        cacheWrite5mPerMTok: Double,
        cacheWrite1hPerMTok: Double
    ) {
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
        self.cacheReadPerMTok = cacheReadPerMTok
        self.cacheWrite5mPerMTok = cacheWrite5mPerMTok
        self.cacheWrite1hPerMTok = cacheWrite1hPerMTok
    }
}

public struct PricingSnapshot: Equatable, Codable {
    public let snapshotVersion: String
    public let source: String
    public let models: [String: ModelPricing]

    public init(snapshotVersion: String, source: String, models: [String: ModelPricing]) {
        self.snapshotVersion = snapshotVersion
        self.source = source
        self.models = models
    }

    public static func loadBundled() throws -> PricingSnapshot {
        guard let url = Bundle.module.url(forResource: "litellm-pricing", withExtension: "json") else {
            throw PricingError.bundledSnapshotMissing
        }
        return try JSONDecoder().decode(PricingSnapshot.self, from: Data(contentsOf: url))
    }
}

public enum PricingError: Error, Equatable {
    case bundledSnapshotMissing
}
```

- [ ] **Step 5: 运行测试确认通过并提交**

Run: `swift test --filter PricingTests`
Expected: `Executed 3 tests, with 0 failures`

```bash
git add Package.swift Sources/TokenMeterCore/Pricing.swift Sources/TokenMeterCore/Resources/litellm-pricing.json scripts/transform_pricing.py scripts/update-pricing.sh Tests/TokenMeterCoreTests/PricingTests.swift
git commit -m "feat: add offline LiteLLM pricing snapshot"
```

---

## Task 5: CostCalculator

**Files:**
- Create: `Sources/TokenMeterCore/CostCalculator.swift`
- Test: `Tests/TokenMeterCoreTests/CostCalculatorTests.swift`

测试用自造的 fixture 定价，不依赖真实价格，这样 LiteLLM 调价不会让测试变红。

- [ ] **Step 1: 写失败的测试**

```swift
import XCTest
@testable import TokenMeterCore

final class CostCalculatorTests: XCTestCase {
    private func makeCalculator() -> CostCalculator {
        let snapshot = PricingSnapshot(
            snapshotVersion: "test",
            source: "litellm",
            models: [
                "claude-opus-4-8": ModelPricing(
                    inputPerMTok: 10.0,
                    outputPerMTok: 100.0,
                    cacheReadPerMTok: 1.0,
                    cacheWrite5mPerMTok: 12.5,
                    cacheWrite1hPerMTok: 20.0
                )
            ]
        )
        return CostCalculator(snapshot: snapshot)
    }

    private func event(
        model: String?,
        input: Int64 = 0,
        output: Int64 = 0,
        cacheRead: Int64 = 0,
        write5m: Int64 = 0,
        write1h: Int64 = 0,
        reported: Int64? = nil
    ) -> UsageEvent {
        UsageEvent(
            eventSeq: 1,
            observedAt: Date(timeIntervalSince1970: 0),
            modelName: model,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWrite5mTokens: write5m,
            cacheWrite1hTokens: write1h,
            reportedCostUSDMicros: reported,
            sourceOffset: 0
        )
    }

    func testReportedCostWins() {
        let result = makeCalculator().cost(for: event(model: "claude-opus-4-8", input: 1_000_000, reported: 42))
        XCTAssertEqual(result.micros, 42)
        XCTAssertEqual(result.source, .reported)
    }

    func testComputesFromTokens() {
        // 1M input @ $10 + 1M output @ $100 = $110 = 110_000_000 micros
        let result = makeCalculator().cost(for: event(model: "claude-opus-4-8", input: 1_000_000, output: 1_000_000))
        XCTAssertEqual(result.micros, 110_000_000)
        XCTAssertEqual(result.source, .computed)
    }

    func testCacheTiersArePricedSeparately() {
        // 1M cacheRead @ $1 + 1M write5m @ $12.5 + 1M write1h @ $20 = $33.5
        let result = makeCalculator().cost(for: event(
            model: "claude-opus-4-8", cacheRead: 1_000_000, write5m: 1_000_000, write1h: 1_000_000
        ))
        XCTAssertEqual(result.micros, 33_500_000)
    }

    func testResolvesViaNormalizedName() {
        let result = makeCalculator().cost(for: event(model: "anthropic/claude-opus-4-8-20260101", input: 1_000_000))
        XCTAssertEqual(result.micros, 10_000_000)
        XCTAssertEqual(result.source, .computed)
    }

    func testDoesNotFallBackToFamilyPricing() {
        // fixture 里没有 claude-opus-4-9。真实快照里 opus 家族价格跨度 3 倍、
        // gpt-5 家族跨度 100 倍。借一个价格算出来的金额会被标成 computed，
        // 用户看到精确到分的数字却无从分辨它来自哪个模型。宁可说不知道。
        let result = makeCalculator().cost(for: event(model: "claude-opus-4-9", input: 1_000_000))
        XCTAssertNil(result.micros)
        XCTAssertEqual(result.source, .unknown)
    }

    func testUnknownModelYieldsNilNotZero() {
        let result = makeCalculator().cost(for: event(model: "some-unlisted-model", input: 1_000_000))
        XCTAssertNil(result.micros)
        XCTAssertEqual(result.source, .unknown)
    }

    func testCanonicalCollisionResolvesToLexicographicallyFirstKey() {
        // 三组撞名，每组四个原始 key，只有字典序最小的那个价格独特。
        //
        // 用三组而不是一组，是为了让这个测试真的守得住 init 里的 sorted(by:)。
        // 去掉 sorted 后，Swift 字典的迭代顺序随进程哈希种子变化，单组撞名
        // 只有 1/4 概率选错，测试有 25% 概率放过。三组同时蒙对的概率是
        // (1/4)^3 ≈ 1.6%，测试会以 98.4% 的概率变红。
        func priced(_ input: Double) -> ModelPricing {
            ModelPricing(inputPerMTok: input, outputPerMTok: 0, cacheReadPerMTok: 0,
                         cacheWrite5mPerMTok: 0, cacheWrite1hPerMTok: 0)
        }
        let snapshot = PricingSnapshot(snapshotVersion: "test", source: "litellm", models: [
            "alpha-1": priced(1), "alpha-1-20240101": priced(90),
            "vertex_ai/alpha-1": priced(91), "zai/alpha-1": priced(92),

            "beta-2": priced(2), "beta-2-20240101": priced(93),
            "vertex_ai/beta-2": priced(94), "zai/beta-2": priced(95),

            "gamma-3": priced(3), "gamma-3-20240101": priced(96),
            "vertex_ai/gamma-3": priced(97), "zai/gamma-3": priced(98)
        ])
        let calculator = CostCalculator(snapshot: snapshot)

        XCTAssertEqual(calculator.cost(for: event(model: "alpha-1", input: 1_000_000)).micros, 1_000_000)
        XCTAssertEqual(calculator.cost(for: event(model: "beta-2", input: 1_000_000)).micros, 2_000_000)
        XCTAssertEqual(calculator.cost(for: event(model: "gamma-3", input: 1_000_000)).micros, 3_000_000)
    }

    func testResolvesGlmThroughZaiPrefix() {
        // OpenCode 上报裸 glm-4.6；快照 key 是 zai/glm-4.6
        let snapshot = PricingSnapshot(snapshotVersion: "test", source: "litellm", models: [
            "zai/glm-4.6": ModelPricing(inputPerMTok: 0.6, outputPerMTok: 2.2, cacheReadPerMTok: 0.11,
                                        cacheWrite5mPerMTok: 0, cacheWrite1hPerMTok: 1.2)
        ])
        let result = CostCalculator(snapshot: snapshot).cost(for: event(model: "glm-4.6", input: 1_000_000))
        XCTAssertEqual(result.micros, 600_000)
        XCTAssertEqual(result.source, .computed)
    }

    func testReasoningTokensAreNotPricedSeparately() {
        // reasoning 已包含在 output 里，不得再计一次
        let withReasoning = UsageEvent(
            eventSeq: 1,
            observedAt: Date(timeIntervalSince1970: 0),
            modelName: "claude-opus-4-8",
            outputTokens: 1_000_000,
            reasoningTokens: 500_000,
            sourceOffset: 0
        )
        XCTAssertEqual(makeCalculator().cost(for: withReasoning).micros, 100_000_000)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter CostCalculatorTests`
Expected: 编译失败，`cannot find 'CostCalculator' in scope`

- [ ] **Step 3: 实现**

`Sources/TokenMeterCore/CostCalculator.swift`：

```swift
import Foundation

public enum CostSource: String, Equatable {
    case reported
    case computed
    case unknown
}

public struct CostCalculator {
    private let canonicalIndex: [String: ModelPricing]

    public init(snapshot: PricingSnapshot) {
        var index: [String: ModelPricing] = [:]
        // LiteLLM 的 key 是原始名，归一化后会撞名：一个规范名常对应多个原始 key。
        // 实测快照有 15 组，主因是 provider 前缀（claude-opus-4-8 与
        // vertex_ai/claude-opus-4-8），其次才是日期后缀。取字典序最小的那个。
        //
        // sorted 不可省略：Swift 字典的迭代顺序取决于每进程随机的哈希种子，
        // 同一份字典连跑十次会得到四种顺序。去掉它，first-write-wins 就成了掷骰子。
        for (key, pricing) in snapshot.models.sorted(by: { $0.key < $1.key }) {
            let canonical = ModelNameNormalizer.canonical(key)
            if index[canonical] == nil {
                index[canonical] = pricing
            }
        }
        canonicalIndex = index
    }

    public func cost(for event: UsageEvent) -> (micros: Int64?, source: CostSource) {
        if let reported = event.reportedCostUSDMicros {
            return (reported, .reported)
        }

        // 不做家族兜底。同家族价格能差 100 倍（gpt-5 $0.05 vs gpt-5.5 $5.00），
        // 借来的价格会被标成 computed，用户无从分辨那是不是真的。
        // 匹配不到就诚实地说不知道，让人去跑 scripts/update-pricing.sh。
        guard let pricing = canonicalIndex[ModelNameNormalizer.canonical(event.modelName)] else {
            return (nil, .unknown)
        }

        let usd =
            perMillion(event.inputTokens, pricing.inputPerMTok) +
            perMillion(event.outputTokens, pricing.outputPerMTok) +
            perMillion(event.cacheReadTokens, pricing.cacheReadPerMTok) +
            perMillion(event.cacheWrite5mTokens, pricing.cacheWrite5mPerMTok) +
            perMillion(event.cacheWrite1hTokens, pricing.cacheWrite1hPerMTok)

        return (Int64((usd * 1_000_000).rounded()), .computed)
    }

    private func perMillion(_ tokens: Int64, _ pricePerMTok: Double) -> Double {
        Double(tokens) / 1_000_000.0 * pricePerMTok
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter CostCalculatorTests`
Expected: `Executed 12 tests, with 0 failures`

- [ ] **Step 5: 让撞名且价格不一致的情况可见**

`CostCalculator` 只能为一个 canonical 保留一个价格。实测快照 15 组撞名里有 2 组价格不一致（`claude-3-opus` 的 1h 缓存价 $6.00 vs $30.00，`claude-3-haiku` 的 $6.00 vs $0.50），落选者的用户会被按胜出者的价格计费。

成因是 LiteLLM 只给 direct-API 变体写了 `cache_creation_input_token_cost_above_1hr`，vertex 变体走了 `input × 2` 派生。检测的位置应该在**生成快照的地方**，那里能看到全部原始 key。

给 `scripts/transform_pricing.py` 增加：

```python
def canonical(name: str) -> str:
    """必须与 Swift 的 ModelNameNormalizer.canonical 保持一致。"""
    name = name.lower()
    for prefix in ("vertex_ai/", "bedrock/", "anthropic/", "openai/", "openai-codex/", "zai/"):
        if name.startswith(prefix):
            name = name[len(prefix):]
            break
    return re.sub(r"-[0-9]{8}$", "", name) or "unknown"


def divergent_collisions(models: dict) -> list:
    """归一后撞名、但价格不一致的组。

    CostCalculator 只保留字典序最小的原始 key，其余 key 的用户会被按
    胜出者的价格计费。这不是猜测：claude-3-opus 与 vertex_ai/claude-3-opus
    的 1h 缓存价相差 5 倍。
    """
    groups = {}
    for key in sorted(models):
        groups.setdefault(canonical(key), []).append(key)
    return [
        (name, keys)
        for name, keys in sorted(groups.items())
        if len(keys) > 1 and len({json.dumps(models[k], sort_keys=True) for k in keys}) > 1
    ]
```

在 `main()` 写出 JSON 之前告警（写 stderr，不阻塞生成——这两个都是 2024 年的模型，只影响 1h 缓存档）：

```python
    for name, keys in divergent_collisions(models):
        print(f"warning: {name} 撞名且价格不一致，将按 {keys[0]} 计价", file=sys.stderr)
        for key in keys:
            print(f"  {key}: {json.dumps(models[key], sort_keys=True)}", file=sys.stderr)
```

`import re` 加到文件头部。

给 `scripts/test_transform_pricing.py` 增加：

```python
class CanonicalTests(unittest.TestCase):
    def test_matches_swift_normalizer(self):
        self.assertEqual(canonical("vertex_ai/claude-3-opus"), "claude-3-opus")
        self.assertEqual(canonical("claude-3-opus-20240229"), "claude-3-opus")
        self.assertEqual(canonical("zai/glm-4.6"), "glm-4.6")
        self.assertEqual(canonical("glm-4.6"), "glm-4.6")          # 非八位数字后缀不剥离
        self.assertEqual(canonical("GPT-5.5"), "gpt-5.5")


class DivergentCollisionTests(unittest.TestCase):
    def test_flags_collision_with_different_prices(self):
        models = {
            "claude-3-opus-20240229": {"inputPerMTok": 15.0, "cacheWrite1hPerMTok": 6.0},
            "vertex_ai/claude-3-opus": {"inputPerMTok": 15.0, "cacheWrite1hPerMTok": 30.0},
        }
        found = divergent_collisions(models)
        self.assertEqual(len(found), 1)
        name, keys = found[0]
        self.assertEqual(name, "claude-3-opus")
        self.assertEqual(keys[0], "claude-3-opus-20240229", "字典序最小者胜出")

    def test_ignores_collision_with_identical_prices(self):
        models = {
            "claude-fable-5": {"inputPerMTok": 10.0},
            "vertex_ai/claude-fable-5": {"inputPerMTok": 10.0},
        }
        self.assertEqual(divergent_collisions(models), [])

    def test_ignores_non_colliding_names(self):
        models = {"a": {"inputPerMTok": 1.0}, "b": {"inputPerMTok": 2.0}}
        self.assertEqual(divergent_collisions(models), [])
```

跑 `cd scripts && python3 -m unittest discover -p 'test_*.py'`，应为 18 个测试。
再跑 `./scripts/update-pricing.sh`，stderr 应打印那两组告警，快照内容不变（空 diff）。

- [ ] **Step 6: 提交**

```bash
git add Sources/TokenMeterCore/CostCalculator.swift Tests/TokenMeterCoreTests/CostCalculatorTests.swift scripts/transform_pricing.py scripts/test_transform_pricing.py
git commit -m "feat: add offline cost calculator with cache tier pricing"
```

---

## Task 6: 流式 parser 协议与 Claude adapter（全部新增）

**Files:**
- Create: `Sources/TokenMeterCore/UsageEventParsers.swift`
- Create: `Sources/TokenMeterCore/ClaudeCodeUsageEventParser.swift`
- Test: `Tests/TokenMeterCoreTests/ClaudeCodeUsageEventParserTests.swift`

`LocalAgentSessionParsers.swift`、`ClaudeCodeSessionParser.swift`、`LocalAgentScanner.swift` **一行都不动**。旧 parser 继续为 scanner 服务，直到 Task 14 切换、Task 18 删除。本任务结束时 `swift test` 必须全绿。

- [ ] **Step 1: 写失败的测试**

新建 `Tests/TokenMeterCoreTests/ClaudeCodeUsageEventParserTests.swift`：

```swift
import XCTest
@testable import TokenMeterCore

final class ClaudeCodeUsageEventParserTests: XCTestCase {
    private func line(_ text: String, offset: Int64) -> JSONLLine {
        JSONLLine(text: text, offset: offset, nextOffset: offset + 1)
    }

    func testEmitsOneEventPerAssistantMessage() throws {
        let lines = [
            line(#"{"type":"assistant","timestamp":"2026-07-08T01:00:00Z","sessionId":"s1","cwd":"/repo","requestId":"req_1","version":"2.1.0","message":{"id":"msg_1","role":"assistant","model":"claude-fable-5","usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":900,"cache_creation":{"ephemeral_5m_input_tokens":50,"ephemeral_1h_input_tokens":20}}}}"#, offset: 0),
            line(#"{"type":"assistant","timestamp":"2026-07-08T02:00:00Z","sessionId":"s1","requestId":"req_2","message":{"id":"msg_2","role":"assistant","model":"claude-opus-4-8","usage":{"input_tokens":200,"output_tokens":20}}}"#, offset: 1)
        ]

        let (session, state) = try ClaudeCodeUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/a.jsonl"), resuming: nil
        )

        XCTAssertEqual(session.sessionKey, "s1")
        XCTAssertEqual(session.projectPath, "/repo")
        XCTAssertEqual(session.cliVersion, "2.1.0")
        XCTAssertEqual(session.events.count, 2)

        XCTAssertEqual(session.events[0].modelName, "claude-fable-5")
        XCTAssertEqual(session.events[0].inputTokens, 100)
        XCTAssertEqual(session.events[0].cacheReadTokens, 900)
        XCTAssertEqual(session.events[0].cacheWrite5mTokens, 50)
        XCTAssertEqual(session.events[0].cacheWrite1hTokens, 20)
        XCTAssertEqual(session.events[0].dedupeKey, "msg_1\u{1F}req_1")

        // 同一会话内换了模型，各归各的
        XCTAssertEqual(session.events[1].modelName, "claude-opus-4-8")
        XCTAssertEqual(session.events[1].inputTokens, 200)

        XCTAssertEqual(state.lastEventSeq, 2)
    }

    func testEventTimestampsArePreservedPerMessage() throws {
        let lines = [
            line(#"{"type":"assistant","timestamp":"2026-07-06T23:30:00Z","sessionId":"s1","requestId":"r1","message":{"id":"m1","role":"assistant","model":"m","usage":{"input_tokens":1}}}"#, offset: 0),
            line(#"{"type":"assistant","timestamp":"2026-07-08T00:30:00Z","sessionId":"s1","requestId":"r2","message":{"id":"m2","role":"assistant","model":"m","usage":{"input_tokens":1}}}"#, offset: 1)
        ]

        let (session, _) = try ClaudeCodeUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/a.jsonl"), resuming: nil
        )

        // 跨天会话：两条事件必须各自保留时间戳，不能都归到最后一天
        let formatter = ISO8601DateFormatter()
        XCTAssertEqual(session.events[0].observedAt, formatter.date(from: "2026-07-06T23:30:00Z"))
        XCTAssertEqual(session.events[1].observedAt, formatter.date(from: "2026-07-08T00:30:00Z"))
    }

    func testFallsBackToLegacyCacheCreationField() throws {
        let lines = [
            line(#"{"type":"assistant","timestamp":"2026-07-08T01:00:00Z","sessionId":"s1","requestId":"r1","message":{"id":"m1","role":"assistant","model":"m","usage":{"input_tokens":1,"cache_creation_input_tokens":300}}}"#, offset: 0)
        ]

        let (session, _) = try ClaudeCodeUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/a.jsonl"), resuming: nil
        )

        // 没有 5m/1h 明细时，整笔算作 5m 档
        XCTAssertEqual(session.events[0].cacheWrite5mTokens, 300)
        XCTAssertEqual(session.events[0].cacheWrite1hTokens, 0)
    }

    func testMarksSidechainEvents() throws {
        let lines = [
            line(#"{"type":"assistant","timestamp":"2026-07-08T01:00:00Z","sessionId":"s1","requestId":"r1","isSidechain":true,"message":{"id":"m1","role":"assistant","model":"m","usage":{"input_tokens":1}}}"#, offset: 0)
        ]

        let (session, _) = try ClaudeCodeUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/a.jsonl"), resuming: nil
        )

        XCTAssertTrue(session.events[0].isSidechain)
    }

    func testSkipsNonAssistantAndUsagelessLines() throws {
        let lines = [
            line(#"{"type":"user","timestamp":"2026-07-08T01:00:00Z","sessionId":"s1","message":{"role":"user","content":"hi"}}"#, offset: 0),
            line(#"{"type":"assistant","timestamp":"2026-07-08T01:00:01Z","sessionId":"s1","message":{"id":"m1","role":"assistant","model":"m"}}"#, offset: 1)
        ]

        let (session, _) = try ClaudeCodeUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/a.jsonl"), resuming: nil
        )

        XCTAssertEqual(session.sessionKey, "s1")
        XCTAssertTrue(session.events.isEmpty)
    }

    func testResumingContinuesEventSeq() throws {
        let lines = [
            line(#"{"type":"assistant","timestamp":"2026-07-08T01:00:00Z","sessionId":"s1","requestId":"r9","message":{"id":"m9","role":"assistant","model":"m","usage":{"input_tokens":1}}}"#, offset: 500)
        ]

        let (session, state) = try ClaudeCodeUsageEventParser.parse(
            lines: lines,
            sourceURL: URL(fileURLWithPath: "/tmp/a.jsonl"),
            resuming: ParserState(lastEventSeq: 7)
        )

        XCTAssertEqual(session.events[0].eventSeq, 8)
        XCTAssertEqual(session.events[0].sourceOffset, 500)
        XCTAssertEqual(state.lastEventSeq, 8)
    }

    func testThrowsWhenSessionKeyMissing() {
        let lines = [line(#"{"type":"assistant","message":{"role":"assistant"}}"#, offset: 0)]
        XCTAssertThrowsError(
            try ClaudeCodeUsageEventParser.parse(lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/a.jsonl"), resuming: nil)
        ) { error in
            XCTAssertEqual(error as? LocalAgentParserError, .missingSessionKey)
        }
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter ClaudeCodeUsageEventParserTests`
Expected: 编译失败，`extra argument 'resuming' in call`

- [ ] **Step 3: 实现**

新建 `Sources/TokenMeterCore/UsageEventParsers.swift`。旧的 `LocalAgentSessionParser` 与 `LocalAgentSessionStreamingParser` 留在原文件里不动——它们还在给 scanner 供货，Task 18 才删。

```swift
/// parser 是流式的：逐行 consume，最后 finish 出完整事件列表。
/// 3.28 GB 的 Codex session 文件不能把 [JSONLLine] 全部读进内存。
public protocol UsageEventParser: AnyObject {
    init(resuming state: ParserState?)
    func consume(_ line: JSONLLine)
    func finish(sourceURL: URL) throws -> (session: ParsedSession, state: ParserState)
}

public extension UsageEventParser {
    /// 测试便利方法，一次性喂完所有行。
    /// **生产路径不得使用**：必须走 JSONLStreamReader 的 onLine 回调。
    static func parse(
        lines: [JSONLLine],
        sourceURL: URL,
        resuming state: ParserState? = nil
    ) throws -> (session: ParsedSession, state: ParserState) {
        let parser = Self(resuming: state)
        for line in lines { parser.consume(line) }
        return try parser.finish(sourceURL: sourceURL)
    }
}
```

`Sources/TokenMeterCore/ClaudeCodeUsageEventParser.swift` 全文替换：

```swift
import Foundation

public final class ClaudeCodeUsageEventParser: UsageEventParser {
    private var sessionKey: String?
    private var projectPath: String?
    private var cliVersion: String?
    private var startedAt: Date?
    private var updatedAt: Date?
    private var events: [UsageEvent] = []
    private var eventSeq: Int
    private let dateFormatters = ClaudeCodeUsageEventParser.makeDateFormatters()

    public init(resuming state: ParserState?) {
        eventSeq = state?.lastEventSeq ?? 0
    }

    public func consume(_ line: JSONLLine) {
        guard let object = JSONDictionary.object(from: line.text) else { return }

        sessionKey = firstString(in: object, keys: ["sessionId", "session_id", "leafUuid", "leaf_uuid"]) ?? sessionKey
        projectPath = firstString(in: object, keys: ["cwd", "project_path", "projectPath"]) ?? projectPath
        cliVersion = firstString(in: object, keys: ["version", "cliVersion", "cli_version"]) ?? cliVersion

        let timestamp = timestamp(in: object)
        if let timestamp {
            if startedAt == nil { startedAt = timestamp }
            updatedAt = timestamp
        }

        guard let message = JSONDictionary.dictionary(object, "message"),
              let usageObject = JSONDictionary.dictionary(message, "usage"),
              let observedAt = timestamp else {
            return
        }

        let type = firstString(in: object, keys: ["type"])
        let role = firstString(in: message, keys: ["role"])
        guard type == nil || type == "assistant" || role == "assistant" else { return }

        let inputTokens = JSONDictionary.int64(usageObject, "input_tokens") ?? 0
        let outputTokens = JSONDictionary.int64(usageObject, "output_tokens") ?? 0
        let cacheReadTokens = JSONDictionary.int64(usageObject, "cache_read_input_tokens") ?? 0
        let (write5m, write1h) = cacheWriteTiers(in: usageObject)

        guard inputTokens + outputTokens + cacheReadTokens + write5m + write1h > 0 else { return }

        eventSeq += 1
        events.append(
            UsageEvent(
                eventSeq: eventSeq,
                observedAt: observedAt,
                modelName: firstString(in: message, keys: ["model", "modelName", "model_name"]),
                messageId: firstString(in: message, keys: ["id"]),
                requestId: firstString(in: object, keys: ["requestId", "request_id"]),
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                reasoningTokens: 0,
                cacheReadTokens: cacheReadTokens,
                cacheWrite5mTokens: write5m,
                cacheWrite1hTokens: write1h,
                reportedCostUSDMicros: nil,
                sourceOffset: line.offset,
                isSidechain: bool(in: object, keys: ["isSidechain", "is_sidechain"]) ?? false
            )
        )
    }

    public func finish(sourceURL: URL) throws -> (session: ParsedSession, state: ParserState) {
        guard let sessionKey else { throw LocalAgentParserError.missingSessionKey }

        let session = ParsedSession(
            sourceKind: .claudeJSONL,
            sessionKey: sessionKey,
            projectPath: projectPath,
            cliVersion: cliVersion,
            startedAt: startedAt,
            updatedAt: updatedAt,
            events: events,
            rawMeta: ["source": "claude-code"]
        )
        return (session, ParserState(lastEventSeq: eventSeq, lastCumulative: nil))
    }

    /// Claude 新版把缓存写入拆成 5 分钟 / 1 小时两档，两档单价不同。
    /// 老版本只有合计字段，此时整笔归入 5m 档。
    private func cacheWriteTiers(in usage: [String: Any]) -> (write5m: Int64, write1h: Int64) {
        if let breakdown = JSONDictionary.dictionary(usage, "cache_creation") {
            return (
                JSONDictionary.int64(breakdown, "ephemeral_5m_input_tokens") ?? 0,
                JSONDictionary.int64(breakdown, "ephemeral_1h_input_tokens") ?? 0
            )
        }
        return (JSONDictionary.int64(usage, "cache_creation_input_tokens") ?? 0, 0)
    }

    private func timestamp(in object: [String: Any]) -> Date? {
        guard let value = firstString(in: object, keys: ["timestamp", "created_at", "createdAt"]) else { return nil }
        for formatter in dateFormatters {
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = JSONDictionary.string(object, key), !value.isEmpty { return value }
        }
        return nil
    }

    private func bool(in object: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = object[key] as? Bool { return value }
        }
        return nil
    }

    static func makeDateFormatters() -> [ISO8601DateFormatter] {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [withFractional, plain]
    }
}
```

注意两点：

1. 去重不在 parser 里做了，移到 Task 7 的 `UsageEventDeduplicator`。parser 只负责如实吐事件。
2. parser 是 `class`，`consume` 里遇到不感兴趣的行用 `return` 而不是 `continue`。基线 commit `13ae94a` 里已有的 `ClaudeCodeStreamingParser` 可以直接删除，它的职责被本类接管。

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter ClaudeCodeUsageEventParserTests`
Expected: `Executed 7 tests, with 0 failures`

Run: `swift test`
Expected: **全绿。** 新 parser 是全新文件，旧 parser 与 `LocalAgentScanner` 一行未动。任何一个既有测试变红，都说明碰了不该碰的东西。

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenMeterCore/UsageEventParsers.swift Sources/TokenMeterCore/ClaudeCodeUsageEventParser.swift Tests/TokenMeterCoreTests/ClaudeCodeUsageEventParserTests.swift
git commit -m "feat: emit message-level events from claude parser"
```

---

## Task 7: UsageEventDeduplicator

两条规则，第二条来自 ccusage 修复过的重复计费问题（其 issue #913）：`/btw` 类 sidechain 会用**新的 requestId** 重放父消息，规则 1 拦不住。

**Files:**
- Create: `Sources/TokenMeterCore/UsageEventDeduplicator.swift`
- Test: `Tests/TokenMeterCoreTests/UsageEventDeduplicatorTests.swift`

- [ ] **Step 1: 写失败的测试**

```swift
import XCTest
@testable import TokenMeterCore

final class UsageEventDeduplicatorTests: XCTestCase {
    private func event(
        seq: Int,
        at seconds: TimeInterval,
        messageId: String?,
        requestId: String?,
        input: Int64 = 1,
        isSidechain: Bool = false
    ) -> UsageEvent {
        UsageEvent(
            eventSeq: seq,
            observedAt: Date(timeIntervalSince1970: seconds),
            messageId: messageId,
            requestId: requestId,
            inputTokens: input,
            sourceOffset: Int64(seq),
            isSidechain: isSidechain
        )
    }

    func testKeepsEarliestOnExactKeyCollision() {
        let later = event(seq: 1, at: 200, messageId: "m1", requestId: "r1")
        let earlier = event(seq: 2, at: 100, messageId: "m1", requestId: "r1")

        let result = UsageEventDeduplicator.deduplicate([later, earlier])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].observedAt, Date(timeIntervalSince1970: 100))
    }

    func testDropsSidechainReplayOfSameMessageId() {
        // 同一条 message 被 sidechain 用新的 requestId 重放，必须丢弃重放副本
        let original = event(seq: 1, at: 100, messageId: "m1", requestId: "r1", isSidechain: false)
        let replay = event(seq: 2, at: 150, messageId: "m1", requestId: "r2", isSidechain: true)

        let result = UsageEventDeduplicator.deduplicate([original, replay])

        XCTAssertEqual(result.count, 1)
        XCTAssertFalse(result[0].isSidechain)
        XCTAssertEqual(result[0].requestId, "r1")
    }

    func testKeepsGenuineSidechainEventWithDistinctMessageId() {
        // 子 agent 自己的 API 响应是真实消耗，必须保留
        let parent = event(seq: 1, at: 100, messageId: "m1", requestId: "r1", isSidechain: false)
        let subagent = event(seq: 2, at: 150, messageId: "m2", requestId: "r2", isSidechain: true)

        let result = UsageEventDeduplicator.deduplicate([parent, subagent])

        XCTAssertEqual(result.count, 2)
    }

    func testKeepsAllEventsWithoutDedupeKey() {
        // Codex 没有 messageId，靠 sourceOffset 天然唯一，不参与去重
        let a = event(seq: 1, at: 100, messageId: nil, requestId: nil)
        let b = event(seq: 2, at: 200, messageId: nil, requestId: nil)

        XCTAssertEqual(UsageEventDeduplicator.deduplicate([a, b]).count, 2)
    }

    func testPreservesEventSeqOrder() {
        let a = event(seq: 3, at: 300, messageId: "m3", requestId: "r3")
        let b = event(seq: 1, at: 100, messageId: "m1", requestId: "r1")
        let c = event(seq: 2, at: 200, messageId: "m2", requestId: "r2")

        let result = UsageEventDeduplicator.deduplicate([a, b, c])

        XCTAssertEqual(result.map(\.eventSeq), [1, 2, 3])
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter UsageEventDeduplicatorTests`
Expected: 编译失败，`cannot find 'UsageEventDeduplicator' in scope`

- [ ] **Step 3: 实现**

`Sources/TokenMeterCore/UsageEventDeduplicator.swift`：

```swift
import Foundation

public enum UsageEventDeduplicator {
    /// 规则一：`(messageId, requestId)` 精确碰撞时保留 `observedAt` 更早的那条。
    ///   同一条 assistant 响应会因 resume / fork 出现在多个 session 文件里。
    ///
    /// 规则二：退化到只按 `messageId` 匹配时，若已存在非 sidechain 的条目，
    ///   丢弃 sidechain 副本。`/btw` 类 sidechain 会用新的 requestId 重放父消息，
    ///   规则一拦不住，会导致缓存 token 被重复计费。
    ///
    ///   这条是对 ccusage issue #913 的防御性移植，**不是本机观察到的问题**：
    ///   本机 5,492 个 session 文件、334,941 行中，零个 messageId 出现在多个
    ///   requestId 下。保留它是因为重复计费是静默错误，而代价只有几行。
    ///
    /// 没有 `dedupeKey` 的事件（如 Codex）原样保留。
    public static func deduplicate(_ events: [UsageEvent]) -> [UsageEvent] {
        var byExactKey: [String: UsageEvent] = [:]
        var passthrough: [UsageEvent] = []

        for event in events {
            guard let key = event.dedupeKey else {
                passthrough.append(event)
                continue
            }
            if let existing = byExactKey[key] {
                if event.observedAt < existing.observedAt {
                    byExactKey[key] = event
                }
            } else {
                byExactKey[key] = event
            }
        }

        var byMessageId: [String: UsageEvent] = [:]
        for event in byExactKey.values {
            guard let messageId = event.messageId else { continue }
            guard let existing = byMessageId[messageId] else {
                byMessageId[messageId] = event
                continue
            }
            if shouldReplace(existing, with: event) {
                byMessageId[messageId] = event
            }
        }

        return (Array(byMessageId.values) + passthrough).sorted { $0.eventSeq < $1.eventSeq }
    }

    private static func shouldReplace(_ existing: UsageEvent, with candidate: UsageEvent) -> Bool {
        // 非 sidechain 永远胜过 sidechain
        if existing.isSidechain != candidate.isSidechain {
            return existing.isSidechain && !candidate.isSidechain
        }
        return candidate.observedAt < existing.observedAt
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter UsageEventDeduplicatorTests`
Expected: `Executed 5 tests, with 0 failures`

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenMeterCore/UsageEventDeduplicator.swift Tests/TokenMeterCoreTests/UsageEventDeduplicatorTests.swift
git commit -m "feat: add usage event deduplicator with sidechain replay rule"
```

---

## Task 8: Codex adapter（语义归一 + 差分 + 畸形事件）

**本任务是全计划最容易出错的地方。** Codex 的 `input_tokens` **包含** `cached_input_tokens`，必须做减法。

**Files:**
- Create: `Sources/TokenMeterCore/CodexUsageEventParser.swift`（旧 `CodexSessionParser.swift` 不动）
- Test: `Tests/TokenMeterCoreTests/CodexUsageEventParserTests.swift`

- [ ] **Step 1: 写失败的测试**

替换 `Tests/TokenMeterCoreTests/CodexUsageEventParserTests.swift` 全文：

```swift
import XCTest
@testable import TokenMeterCore

final class CodexUsageEventParserTests: XCTestCase {
    private func line(_ text: String, offset: Int64) -> JSONLLine {
        JSONLLine(text: text, offset: offset, nextOffset: offset + 1)
    }

    private let meta = #"{"type":"session_meta","payload":{"id":"s1","timestamp":"2026-07-08T01:00:00Z","cwd":"/repo"}}"#
    private let turnContext = #"{"type":"turn_context","payload":{"model":"gpt-5.5"}}"#

    func testSubtractsCachedInputFromInput() throws {
        // Codex 的 input_tokens 已包含 cached_input_tokens
        let lines = [
            line(meta, offset: 0),
            line(turnContext, offset: 1),
            line(#"{"type":"event_msg","timestamp":"2026-07-08T01:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":900,"output_tokens":50,"reasoning_output_tokens":10,"total_tokens":1050}}}}"#, offset: 2)
        ]

        let (session, _) = try CodexUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/c.jsonl"), resuming: nil
        )

        XCTAssertEqual(session.events.count, 1)
        let event = session.events[0]
        XCTAssertEqual(event.inputTokens, 100, "input 必须减去 cached")
        XCTAssertEqual(event.cacheReadTokens, 900)
        XCTAssertEqual(event.outputTokens, 50)
        XCTAssertEqual(event.reasoningTokens, 10)
        // 900 不能算两遍
        XCTAssertEqual(event.totalTokens, 1050)
        XCTAssertEqual(event.modelName, "gpt-5.5")
    }

    func testPrefersLastTokenUsageOverCumulativeDiff() throws {
        let lines = [
            line(meta, offset: 0),
            line(#"{"type":"event_msg","timestamp":"2026-07-08T01:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":25,"cached_input_tokens":5,"output_tokens":5},"total_token_usage":{"input_tokens":125,"cached_input_tokens":30,"output_tokens":55}}}}"#, offset: 1)
        ]

        let (session, _) = try CodexUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/c.jsonl"), resuming: nil
        )

        XCTAssertEqual(session.events[0].inputTokens, 20)
        XCTAssertEqual(session.events[0].cacheReadTokens, 5)
        XCTAssertEqual(session.events[0].outputTokens, 5)
    }

    func testDiffsCumulativeTotalsWhenLastUsageMissing() throws {
        let lines = [
            line(meta, offset: 0),
            line(#"{"type":"event_msg","timestamp":"2026-07-08T01:05:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":20}}}}"#, offset: 1),
            line(#"{"type":"event_msg","timestamp":"2026-07-08T01:06:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":60,"output_tokens":30}}}}"#, offset: 2)
        ]

        let (session, state) = try CodexUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/c.jsonl"), resuming: nil
        )

        XCTAssertEqual(session.events.count, 2)
        // 第一条：input 100 - cached 40 = 60
        XCTAssertEqual(session.events[0].inputTokens, 60)
        XCTAssertEqual(session.events[0].cacheReadTokens, 40)
        // 第二条差分：input Δ50 - cached Δ20 = 30
        XCTAssertEqual(session.events[1].inputTokens, 30)
        XCTAssertEqual(session.events[1].cacheReadTokens, 20)
        XCTAssertEqual(session.events[1].outputTokens, 10)

        XCTAssertEqual(state.lastCumulative?.inputTokens, 150)
        XCTAssertEqual(state.lastCumulative?.cachedInputTokens, 60)
    }

    func testResumesCumulativeBaselineFromParserState() throws {
        let lines = [
            line(meta, offset: 0),
            line(#"{"type":"event_msg","timestamp":"2026-07-08T01:06:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":60,"output_tokens":30}}}}"#, offset: 900)
        ]

        let previous = ParserState(
            lastEventSeq: 4,
            lastCumulative: CumulativeTokenTotals(inputTokens: 100, cachedInputTokens: 40, outputTokens: 20, reasoningTokens: 0)
        )
        let (session, state) = try CodexUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/c.jsonl"), resuming: previous
        )

        XCTAssertEqual(session.events[0].eventSeq, 5)
        XCTAssertEqual(session.events[0].inputTokens, 30)
        XCTAssertEqual(session.events[0].cacheReadTokens, 20)
        XCTAssertEqual(state.lastEventSeq, 5)
    }

    func testTreatsCumulativeResetAsFreshBaseline() throws {
        // compacted 之后累计值会变小，此时新值本身就是增量
        let lines = [
            line(meta, offset: 0),
            line(#"{"type":"event_msg","timestamp":"2026-07-08T01:05:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500,"cached_input_tokens":100,"output_tokens":50}}}}"#, offset: 1),
            line(#"{"type":"event_msg","timestamp":"2026-07-08T01:06:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":80,"cached_input_tokens":20,"output_tokens":10}}}}"#, offset: 2)
        ]

        let (session, _) = try CodexUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/c.jsonl"), resuming: nil
        )

        XCTAssertEqual(session.events.count, 2)
        XCTAssertEqual(session.events[1].inputTokens, 60)   // 80 - 20，不是负数
        XCTAssertEqual(session.events[1].outputTokens, 10)
    }

    func testSkipsMalformedEventWithZeroInputAndOutput() throws {
        // 真实数据中出现过 input=output=0 但 total>0 的事件（600 条里 2 条）
        let lines = [
            line(meta, offset: 0),
            line(#"{"type":"event_msg","timestamp":"2026-07-08T01:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":14676}}}}"#, offset: 1)
        ]

        let (session, _) = try CodexUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/c.jsonl"), resuming: nil
        )

        XCTAssertTrue(session.events.isEmpty, "畸形事件必须跳过，不得把 total 当成 output")
    }

    func testCodexEventsHaveNoDedupeKey() throws {
        let lines = [
            line(meta, offset: 0),
            line(#"{"type":"event_msg","timestamp":"2026-07-08T01:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"output_tokens":1}}}}"#, offset: 1)
        ]

        let (session, _) = try CodexUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/c.jsonl"), resuming: nil
        )

        XCTAssertNil(session.events[0].dedupeKey)
        XCTAssertEqual(session.events[0].sourceOffset, 1)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter CodexUsageEventParserTests`
Expected: 编译失败，`extra argument 'resuming' in call`

- [ ] **Step 3: 实现**

`Sources/TokenMeterCore/CodexUsageEventParser.swift` 全文替换：

```swift
import Foundation

public final class CodexUsageEventParser: UsageEventParser {
    private var sessionKey: String?
    private var projectPath: String?
    private var modelName: String?
    private var startedAt: Date?
    private var updatedAt: Date?
    private var events: [UsageEvent] = []
    private var eventSeq: Int
    private var cumulative: CumulativeTokenTotals?
    private let dateFormatters = ClaudeCodeUsageEventParser.makeDateFormatters()

    public init(resuming state: ParserState?) {
        eventSeq = state?.lastEventSeq ?? 0
        cumulative = state?.lastCumulative
    }

    public func consume(_ line: JSONLLine) {
        guard let object = JSONDictionary.object(from: line.text) else { return }
        let payload = JSONDictionary.dictionary(object, "payload")

        if let timestamp = timestamp(in: object) {
            if startedAt == nil { startedAt = timestamp }
            updatedAt = timestamp
        }

        switch JSONDictionary.string(object, "type") {
        case "session_meta":
            sessionKey = payload.flatMap { JSONDictionary.string($0, "id") } ?? sessionKey
            projectPath = payload.flatMap { JSONDictionary.string($0, "cwd") } ?? projectPath
        case "turn_context":
            modelName = payload.flatMap { JSONDictionary.string($0, "model") } ?? modelName
            projectPath = payload.flatMap { JSONDictionary.string($0, "cwd") } ?? projectPath
        case "event_msg":
            guard let payload,
                  JSONDictionary.string(payload, "type") == "token_count",
                  let info = JSONDictionary.dictionary(payload, "info"),
                  let observedAt = timestamp(in: object) else {
                return
            }

            let delta: RawTokenTotals
            if let last = JSONDictionary.dictionary(info, "last_token_usage") {
                delta = RawTokenTotals(last)
                if let total = JSONDictionary.dictionary(info, "total_token_usage") {
                    cumulative = RawTokenTotals(total).asCumulative
                }
            } else if let total = JSONDictionary.dictionary(info, "total_token_usage") {
                let current = RawTokenTotals(total)
                delta = current.subtracting(cumulative)
                cumulative = current.asCumulative
            } else {
                return
            }

            // 真实数据里存在 input=output=0 但 total>0 的畸形事件，跳过。
            guard delta.inputTokens > 0 || delta.outputTokens > 0 else { return }

            eventSeq += 1
            events.append(
                UsageEvent(
                    eventSeq: eventSeq,
                    observedAt: observedAt,
                    modelName: modelName,
                    messageId: nil,
                    requestId: nil,
                    // Codex 的 input 含 cached，必须减掉，否则缓存 token 被计两遍
                    inputTokens: max(0, delta.inputTokens - delta.cachedInputTokens),
                    outputTokens: delta.outputTokens,
                    reasoningTokens: delta.reasoningTokens,
                    cacheReadTokens: delta.cachedInputTokens,
                    cacheWrite5mTokens: 0,
                    cacheWrite1hTokens: 0,
                    reportedCostUSDMicros: nil,
                    sourceOffset: line.offset,
                    isSidechain: false
                )
            )
        default:
            return
        }
    }

    public func finish(sourceURL: URL) throws -> (session: ParsedSession, state: ParserState) {
        guard let sessionKey else { throw LocalAgentParserError.missingSessionKey }

        let session = ParsedSession(
            sourceKind: .codexJSONL,
            sessionKey: sessionKey,
            projectPath: projectPath,
            cliVersion: nil,
            startedAt: startedAt,
            updatedAt: updatedAt,
            events: events,
            rawMeta: ["source": "codex"]
        )
        return (session, ParserState(lastEventSeq: eventSeq, lastCumulative: cumulative))
    }

    private func timestamp(in object: [String: Any]) -> Date? {
        if let value = JSONDictionary.string(object, "timestamp") {
            for formatter in dateFormatters {
                if let date = formatter.date(from: value) { return date }
            }
            if let seconds = Double(value) { return dateFromEpoch(seconds) }
        }
        if let numeric = JSONDictionary.double(object, "timestamp") {
            return dateFromEpoch(numeric)
        }
        return nil
    }

    /// Codex 有时写秒、有时写毫秒。用 10^11 作阈值区分（约公元 5138 年的秒数）。
    private func dateFromEpoch(_ value: Double) -> Date {
        value > 100_000_000_000 ? Date(timeIntervalSince1970: value / 1000) : Date(timeIntervalSince1970: value)
    }
}

/// Codex `token_count` 事件里的原始四元组。语义：`input` 含 `cached`，`output` 含 `reasoning`。
private struct RawTokenTotals {
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let outputTokens: Int64
    let reasoningTokens: Int64

    init(_ object: [String: Any]) {
        inputTokens = JSONDictionary.int64(object, "input_tokens") ?? 0
        cachedInputTokens = JSONDictionary.int64(object, "cached_input_tokens") ?? 0
        outputTokens = JSONDictionary.int64(object, "output_tokens") ?? 0
        reasoningTokens = JSONDictionary.int64(object, "reasoning_output_tokens") ?? 0
    }

    private init(inputTokens: Int64, cachedInputTokens: Int64, outputTokens: Int64, reasoningTokens: Int64) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
    }

    var asCumulative: CumulativeTokenTotals {
        CumulativeTokenTotals(
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens
        )
    }

    /// 累计值差分。若新值小于基线（compacted 导致的重置），把新值本身当作增量。
    func subtracting(_ baseline: CumulativeTokenTotals?) -> RawTokenTotals {
        guard let baseline, inputTokens >= baseline.inputTokens, outputTokens >= baseline.outputTokens else {
            return self
        }
        return RawTokenTotals(
            inputTokens: inputTokens - baseline.inputTokens,
            cachedInputTokens: max(0, cachedInputTokens - baseline.cachedInputTokens),
            outputTokens: outputTokens - baseline.outputTokens,
            reasoningTokens: max(0, reasoningTokens - baseline.reasoningTokens)
        )
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter CodexUsageEventParserTests`
Expected: `Executed 7 tests, with 0 failures`

若 `testSubtractsCachedInputFromInput` 得到 `inputTokens == 1000`，说明减法没做，Codex 的 token 会翻倍。

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenMeterCore/CodexUsageEventParser.swift Tests/TokenMeterCoreTests/CodexUsageEventParserTests.swift
git commit -m "feat: normalize codex token semantics and emit delta events"
```

---

## Task 9: omp adapter

omp 的 `input` **不含** cache（与 Codex 相反），`reasoningTokens ⊂ output`，且**自带成本** `message.usage.cost.total`。
它的消息行只有 `id`、没有 `requestId`，因此 `dedupeKey` 恒为 nil，唯一性靠 `(source_file_id, event_seq)`。

**Files:**
- Create: `Sources/TokenMeterCore/OmpUsageEventParser.swift`（旧 `OmpSessionParser.swift` 不动）
- Test: `Tests/TokenMeterCoreTests/OmpUsageEventParserTests.swift`

- [ ] **Step 1: 写失败的测试**

替换 `Tests/TokenMeterCoreTests/OmpUsageEventParserTests.swift` 全文：

```swift
import XCTest
@testable import TokenMeterCore

final class OmpUsageEventParserTests: XCTestCase {
    private func line(_ text: String, offset: Int64) -> JSONLLine {
        JSONLLine(text: text, offset: offset, nextOffset: offset + 1)
    }

    private let meta = #"{"type":"session_meta","id":"omp-1","timestamp":"2026-07-08T01:00:00Z"}"#

    func testDoesNotSubtractCacheFromInput() throws {
        // omp: total = input + output + cacheRead，cache 独立于 input
        let lines = [
            line(meta, offset: 0),
            line(#"{"type":"message","id":"m1","timestamp":"2026-07-08T01:05:00Z","message":{"role":"assistant","provider":"openai-codex","model":"gpt-5.5","usage":{"input":1000,"output":50,"cacheRead":900,"cacheWrite":0,"reasoningTokens":10,"totalTokens":1950,"cost":{"total":0.5}}}}"#, offset: 1)
        ]

        let (session, _) = try OmpUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/o.jsonl"), resuming: nil
        )

        XCTAssertEqual(session.events.count, 1)
        let event = session.events[0]
        XCTAssertEqual(event.inputTokens, 1000, "omp 的 input 不含 cache，不得做减法")
        XCTAssertEqual(event.cacheReadTokens, 900)
        XCTAssertEqual(event.outputTokens, 50)
        XCTAssertEqual(event.reasoningTokens, 10)
        XCTAssertEqual(event.totalTokens, 1950)
        XCTAssertNil(event.dedupeKey)
    }

    func testUsesReportedCostWhenPositive() throws {
        let lines = [
            line(meta, offset: 0),
            line(#"{"type":"message","id":"m1","timestamp":"2026-07-08T01:05:00Z","message":{"role":"assistant","model":"gpt-5.5","usage":{"input":10,"output":1,"cost":{"total":0.19055}}}}"#, offset: 1)
        ]

        let (session, _) = try OmpUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/o.jsonl"), resuming: nil
        )

        // 0.19055 USD -> 190550 micros
        XCTAssertEqual(session.events[0].reportedCostUSDMicros, 190_550)
    }

    func testZeroCostFallsThroughToComputed() throws {
        // cost == 0 说明 omp 不知道单价（套餐制），交给 CostCalculator 自算
        let lines = [
            line(meta, offset: 0),
            line(#"{"type":"message","id":"m1","timestamp":"2026-07-08T01:05:00Z","message":{"role":"assistant","model":"gpt-5.5","usage":{"input":10,"output":1,"cost":{"total":0}}}}"#, offset: 1)
        ]

        let (session, _) = try OmpUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/o.jsonl"), resuming: nil
        )

        XCTAssertNil(session.events[0].reportedCostUSDMicros)
    }

    func testCacheWriteGoesToFiveMinuteTier() throws {
        let lines = [
            line(meta, offset: 0),
            line(#"{"type":"message","id":"m1","timestamp":"2026-07-08T01:05:00Z","message":{"role":"assistant","model":"m","usage":{"input":1,"cacheWrite":300}}}"#, offset: 1)
        ]

        let (session, _) = try OmpUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/o.jsonl"), resuming: nil
        )

        XCTAssertEqual(session.events[0].cacheWrite5mTokens, 300)
        XCTAssertEqual(session.events[0].cacheWrite1hTokens, 0)
    }

    func testFallsBackToFileNameForSessionKey() throws {
        let lines = [
            line(#"{"type":"message","id":"m1","timestamp":"2026-07-08T01:05:00Z","message":{"role":"assistant","model":"m","usage":{"input":1}}}"#, offset: 0)
        ]

        let (session, _) = try OmpUsageEventParser.parse(
            lines: lines,
            sourceURL: URL(fileURLWithPath: "/tmp/2026-07-01T11-20-18-498Z_019f1d68.jsonl"),
            resuming: nil
        )

        XCTAssertEqual(session.sessionKey, "2026-07-01T11-20-18-498Z_019f1d68")
    }

    func testResumingContinuesEventSeq() throws {
        let lines = [
            line(meta, offset: 0),
            line(#"{"type":"message","id":"m1","timestamp":"2026-07-08T01:05:00Z","message":{"role":"assistant","model":"m","usage":{"input":1}}}"#, offset: 42)
        ]

        let (session, state) = try OmpUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/o.jsonl"), resuming: ParserState(lastEventSeq: 3)
        )

        XCTAssertEqual(session.events[0].eventSeq, 4)
        XCTAssertEqual(session.events[0].sourceOffset, 42)
        XCTAssertEqual(state.lastEventSeq, 4)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter OmpUsageEventParserTests`
Expected: 编译失败，`extra argument 'resuming' in call`

- [ ] **Step 3: 实现**

`Sources/TokenMeterCore/OmpUsageEventParser.swift` 全文替换：

```swift
import Foundation

public final class OmpUsageEventParser: UsageEventParser {
    private var sessionKey: String?
    private var projectPath: String?
    private var modelName: String?
    private var startedAt: Date?
    private var updatedAt: Date?
    private var events: [UsageEvent] = []
    private var eventSeq: Int
    private let dateFormatters = ClaudeCodeUsageEventParser.makeDateFormatters()

    public init(resuming state: ParserState?) {
        eventSeq = state?.lastEventSeq ?? 0
    }

    public func consume(_ line: JSONLLine) {
        guard let object = JSONDictionary.object(from: line.text) else { return }

        let timestamp = timestamp(in: object)
        if let timestamp {
            if startedAt == nil { startedAt = timestamp }
            updatedAt = timestamp
        }

        switch JSONDictionary.string(object, "type") {
        case "session_meta":
            sessionKey = firstString(in: object, keys: ["id", "sessionId", "session_id"]) ?? sessionKey
            projectPath = firstString(in: object, keys: ["cwd", "directory"]) ?? projectPath
            modelName = firstString(in: object, keys: ["model", "modelName"]) ?? modelName
        case "model_change", "modelChange":
            modelName = firstString(in: object, keys: ["model", "modelName"]) ?? modelName
        case "message":
            guard let message = JSONDictionary.dictionary(object, "message"),
                  let usage = JSONDictionary.dictionary(message, "usage"),
                  let observedAt = timestamp else {
                return
            }
            modelName = firstString(in: message, keys: ["model", "modelName"]) ?? modelName

            // omp 的 input 不含 cache，原样取值
            let inputTokens = JSONDictionary.int64(usage, "input") ?? 0
            let outputTokens = JSONDictionary.int64(usage, "output") ?? 0
            let cacheReadTokens = JSONDictionary.int64(usage, "cacheRead") ?? 0
            let cacheWriteTokens = JSONDictionary.int64(usage, "cacheWrite") ?? 0
            let reasoningTokens = JSONDictionary.int64(usage, "reasoningTokens") ?? 0

            guard inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens > 0 else { return }

            eventSeq += 1
            events.append(
                UsageEvent(
                    eventSeq: eventSeq,
                    observedAt: observedAt,
                    modelName: modelName,
                    messageId: nil,
                    requestId: nil,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    reasoningTokens: reasoningTokens,
                    cacheReadTokens: cacheReadTokens,
                    // omp 不区分缓存写入档位，整笔归 5m
                    cacheWrite5mTokens: cacheWriteTokens,
                    cacheWrite1hTokens: 0,
                    reportedCostUSDMicros: reportedCost(in: usage),
                    sourceOffset: line.offset,
                    isSidechain: false
                )
            )
        default:
            return
        }
    }

    public func finish(sourceURL: URL) throws -> (session: ParsedSession, state: ParserState) {
        let resolvedSessionKey = sessionKey ?? sourceURL.deletingPathExtension().lastPathComponent
        guard !resolvedSessionKey.isEmpty else { throw LocalAgentParserError.missingSessionKey }

        let session = ParsedSession(
            sourceKind: .ompJSONL,
            sessionKey: resolvedSessionKey,
            projectPath: projectPath,
            cliVersion: nil,
            startedAt: startedAt,
            updatedAt: updatedAt,
            events: events,
            rawMeta: ["source": "omp"]
        )
        return (session, ParserState(lastEventSeq: eventSeq, lastCumulative: nil))
    }

    /// cost == 0 表示 omp 不知道单价（套餐制），交给 CostCalculator 自算，而不是记 0。
    private func reportedCost(in usage: [String: Any]) -> Int64? {
        guard let cost = JSONDictionary.dictionary(usage, "cost"),
              let total = JSONDictionary.double(cost, "total"),
              total > 0 else {
            return nil
        }
        return Int64((total * 1_000_000).rounded())
    }

    private func timestamp(in object: [String: Any]) -> Date? {
        guard let value = firstString(in: object, keys: ["timestamp", "created_at", "createdAt"]) else { return nil }
        for formatter in dateFormatters {
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = JSONDictionary.string(object, key), !value.isEmpty { return value }
        }
        return nil
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter OmpUsageEventParserTests`
Expected: `Executed 6 tests, with 0 failures`

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenMeterCore/OmpUsageEventParser.swift Tests/TokenMeterCoreTests/OmpUsageEventParserTests.swift
git commit -m "feat: emit message-level events from omp parser"
```

---

## Task 10: OpenCode adapter

旧的 `OpenCodeSessionAdapter.parseMessageRow` 本来就是逐消息解析的，只是 `mergeMessageSession` / `mergeUsage` 又把它们合并了回去。新适配器照抄它的 SQL 与 JSON 解析，但**不做任何合并**：每条消息产出一个 `UsageEvent`。旧文件一行不动。

OpenCode 的 `tokens` 与 omp 同侧：cache 独立于 input。

**Files:**
- Create: `Sources/TokenMeterCore/OpenCodeUsageEventAdapter.swift`（旧 `OpenCodeSessionAdapter.swift` 不动）
- Test: `Tests/TokenMeterCoreTests/OpenCodeUsageEventAdapterTests.swift`

- [ ] **Step 1: 写失败的测试**

替换 `Tests/TokenMeterCoreTests/OpenCodeUsageEventAdapterTests.swift` 全文：

```swift
import XCTest
@testable import TokenMeterCore

final class OpenCodeUsageEventAdapterTests: XCTestCase {
    private func makeDatabase() throws -> SQLiteDatabase {
        let database = try SQLiteDatabase(path: ":memory:")
        try database.execute(
            """
            CREATE TABLE message (
              id TEXT PRIMARY KEY,
              session_id TEXT NOT NULL,
              time_created INTEGER NOT NULL,
              time_updated INTEGER NOT NULL,
              data TEXT NOT NULL
            )
            """
        )
        return database
    }

    private func insert(_ database: SQLiteDatabase, id: String, sessionId: String, createdMs: Int64, data: String) throws {
        try database.execute(
            "INSERT INTO message(id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?)",
            [.text(id), .text(sessionId), .int(createdMs), .int(createdMs), .text(data)]
        )
    }

    func testEmitsOneEventPerMessageInsteadOfMerging() throws {
        let database = try makeDatabase()
        try insert(database, id: "m1", sessionId: "s1", createdMs: 1_000,
            data: #"{"id":"m1","sessionID":"s1","role":"assistant","modelID":"glm-4.6","providerID":"zhipuai-coding-plan","cost":0,"time":{"created":1000},"tokens":{"input":100,"output":10,"reasoning":0,"cache":{"read":900,"write":0}}}"#)
        try insert(database, id: "m2", sessionId: "s1", createdMs: 2_000,
            data: #"{"id":"m2","sessionID":"s1","role":"assistant","modelID":"glm-4.6","cost":0.5,"time":{"created":2000},"tokens":{"input":200,"output":20,"reasoning":5,"cache":{"read":0,"write":300}}}"#)

        let sessions = try OpenCodeUsageEventAdapter(sourceDatabase: database).changedSessions(after: nil)

        XCTAssertEqual(sessions.count, 1)
        let session = sessions[0]
        XCTAssertEqual(session.sessionKey, "s1")
        XCTAssertEqual(session.events.count, 2, "两条消息必须是两个事件，不能合并成一条")

        XCTAssertEqual(session.events[0].inputTokens, 100, "cache 独立于 input，不做减法")
        XCTAssertEqual(session.events[0].cacheReadTokens, 900)
        XCTAssertEqual(session.events[0].totalTokens, 1010)

        XCTAssertEqual(session.events[1].cacheWrite5mTokens, 300)
        XCTAssertEqual(session.events[1].reasoningTokens, 5)
        XCTAssertEqual(session.events[1].totalTokens, 520)
    }

    func testZeroCostFallsThroughToComputed() throws {
        let database = try makeDatabase()
        try insert(database, id: "m1", sessionId: "s1", createdMs: 1_000,
            data: #"{"id":"m1","sessionID":"s1","role":"assistant","modelID":"glm-4.6","cost":0,"time":{"created":1000},"tokens":{"input":100,"output":10,"cache":{"read":0,"write":0}}}"#)

        let sessions = try OpenCodeUsageEventAdapter(sourceDatabase: database).changedSessions(after: nil)

        XCTAssertNil(sessions[0].events[0].reportedCostUSDMicros)
    }

    func testPositiveCostIsReported() throws {
        let database = try makeDatabase()
        try insert(database, id: "m1", sessionId: "s1", createdMs: 1_000,
            data: #"{"id":"m1","sessionID":"s1","role":"assistant","modelID":"glm-4.6","cost":0.25,"time":{"created":1000},"tokens":{"input":100,"output":10,"cache":{"read":0,"write":0}}}"#)

        let sessions = try OpenCodeUsageEventAdapter(sourceDatabase: database).changedSessions(after: nil)

        XCTAssertEqual(sessions[0].events[0].reportedCostUSDMicros, 250_000)
    }

    func testEventTimestampsComeFromMessageCreatedTime() throws {
        let database = try makeDatabase()
        try insert(database, id: "m1", sessionId: "s1", createdMs: 1_765_980_154_045,
            data: #"{"id":"m1","sessionID":"s1","role":"assistant","modelID":"glm-4.6","cost":0,"time":{"created":1765980154045},"tokens":{"input":1,"output":1,"cache":{"read":0,"write":0}}}"#)

        let sessions = try OpenCodeUsageEventAdapter(sourceDatabase: database).changedSessions(after: nil)

        XCTAssertEqual(sessions[0].events[0].observedEpochMilliseconds, 1_765_980_154_045)
    }

    func testSkipsMessagesWithoutTokens() throws {
        let database = try makeDatabase()
        try insert(database, id: "m1", sessionId: "s1", createdMs: 1_000,
            data: #"{"id":"m1","sessionID":"s1","role":"user","time":{"created":1000}}"#)

        let sessions = try OpenCodeUsageEventAdapter(sourceDatabase: database).changedSessions(after: nil)

        XCTAssertTrue(sessions.isEmpty)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter OpenCodeUsageEventAdapterTests`
Expected: FAIL，`value of type 'ParsedAgentSession' has no member 'events'`

- [ ] **Step 3: 实现**

改造 `Sources/TokenMeterCore/OpenCodeUsageEventAdapter.swift`：

1. `changedSessions(after:)` 返回类型改为 `[ParsedSession]`。
2. 不实现 `mergeMessageSession` / `mergeUsage` / `sum` / `isLater` —— 新适配器根本不合并。
3. `parseMessageRow` 改为返回 `(sessionKey: String, event: UsageEvent, model: String?, provider: String?, createdAt: Date)`。
4. 按 `sessionKey` 分组，组内按 `createdAt` 升序编号 `eventSeq`。

关键代码：

```swift
    /// OpenCode 每条 message 就是一次 API 响应，逐条产出事件，不做任何合并。
    public func changedSessions(after highWaterMark: String?) throws -> [ParsedSession] {
        let hasUpdatedColumn = try tableExists("message") && (try columnExists("message", "time_updated"))
        let rows = try changedMessageRows(after: highWaterMark, hasUpdatedColumn: hasUpdatedColumn)

        var grouped: [String: [ParsedOpenCodeMessage]] = [:]
        for row in rows {
            guard let data = row.string("data"), let parsed = parseMessageRow(row: row, data: data) else { continue }
            grouped[parsed.sessionKey, default: []].append(parsed)
        }

        return grouped.keys.sorted().map { sessionKey in
            let messages = grouped[sessionKey]!.sorted { $0.createdAt < $1.createdAt }
            let events = messages.enumerated().map { index, message in
                UsageEvent(
                    eventSeq: index + 1,
                    observedAt: message.createdAt,
                    modelName: message.model,
                    messageId: nil,
                    requestId: nil,
                    inputTokens: message.inputTokens,
                    outputTokens: message.outputTokens,
                    reasoningTokens: message.reasoningTokens,
                    cacheReadTokens: message.cacheReadTokens,
                    cacheWrite5mTokens: message.cacheWriteTokens,
                    cacheWrite1hTokens: 0,
                    reportedCostUSDMicros: message.reportedCostUSDMicros,
                    sourceOffset: Int64(index + 1),
                    isSidechain: false
                )
            }
            return ParsedSession(
                sourceKind: .opencodeSQLite,
                sessionKey: sessionKey,
                projectPath: nil,
                cliVersion: nil,
                startedAt: messages.first?.createdAt,
                updatedAt: messages.last?.createdAt,
                events: events,
                rawMeta: rawMeta(provider: messages.last?.provider, agent: "opencode")
            )
        }
    }

    private func parseMessageRow(row: SQLiteRow, data: String) -> ParsedOpenCodeMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)),
              let dictionary = object as? [String: Any] else { return nil }

        guard let messageId = stringValue(dictionary["id"]) ?? row.string("id") else { return nil }
        let sessionKey = stringValue(dictionary["sessionID"]) ?? row.string("session_id") ?? messageId

        let tokens = dictionary["tokens"] as? [String: Any]
        let cache = tokens?["cache"] as? [String: Any]
        let inputTokens = intValue(tokens?["input"]) ?? 0
        let outputTokens = intValue(tokens?["output"]) ?? 0
        let reasoningTokens = intValue(tokens?["reasoning"]) ?? 0
        let cacheReadTokens = intValue(cache?["read"]) ?? 0
        let cacheWriteTokens = intValue(cache?["write"]) ?? 0

        guard inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens > 0 else { return nil }
        guard let createdMs = doubleValue((dictionary["time"] as? [String: Any])?["created"]) else { return nil }

        // cost == 0 表示 OpenCode 不知道单价（套餐制），交给 CostCalculator 自算
        let reportedCost = doubleValue(dictionary["cost"]).flatMap { $0 > 0 ? Int64(($0 * 1_000_000).rounded()) : nil }

        return ParsedOpenCodeMessage(
            sessionKey: sessionKey,
            createdAt: Date(timeIntervalSince1970: createdMs / 1000),
            model: stringValue(dictionary["modelID"]),
            provider: stringValue(dictionary["providerID"]),
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            reportedCostUSDMicros: reportedCost
        )
    }
```

在文件末尾追加：

```swift
private struct ParsedOpenCodeMessage {
    let sessionKey: String
    let createdAt: Date
    let model: String?
    let provider: String?
    let inputTokens: Int64
    let outputTokens: Int64
    let reasoningTokens: Int64
    let cacheReadTokens: Int64
    let cacheWriteTokens: Int64
    let reportedCostUSDMicros: Int64?
}
```

同时删除 `ParsedMessageSession` 结构体。

- [ ] **Step 4: 运行测试并确认整个包能编译**

Run: `swift test --filter OpenCodeUsageEventAdapterTests`
Expected: `Executed 5 tests, with 0 failures`

Run: `swift build`
Expected: **全绿。** 新适配器是新文件，旧 `OpenCodeSessionAdapter` 与 `LocalAgentUsageRepository` 一行未动。

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenMeterCore/OpenCodeUsageEventAdapter.swift Tests/TokenMeterCoreTests/OpenCodeUsageEventAdapterTests.swift
git commit -m "feat: emit message-level events from opencode adapter"
```

---

## Task 11: UsageEventWriter（新增）

新建一个只写 `usage_events` 的写入器。`LocalAgentUsageRepository` 一行不动——它还在给 scanner 供货，Task 14 切换、Task 18 删除。

**「保留时间戳更早的那条」靠唯一索引实现不了**：`INSERT OR IGNORE` 保留的是先写入的那条，而扫描顺序不保证时间顺序。必须先查后比。

**Files:**
- Create: `Sources/TokenMeterCore/UsageEventWriter.swift`
- Test: `Tests/TokenMeterCoreTests/UsageEventWriterTests.swift`

`LocalAgentUsageRepository.swift` 与 `LocalAgentModels.swift` **一行都不动**。

- [ ] **Step 1: 写失败的测试**

```swift
import XCTest
@testable import TokenMeterCore

final class UsageEventWriterTests: XCTestCase {
    private func makeDatabase() throws -> SQLiteDatabase {
        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)
        try database.execute(
            "INSERT INTO scan_roots(id, kind, root_path, display_name, stable_source_key) VALUES (1, 'claude_jsonl', '/tmp/c', 'C', 'c')"
        )
        try database.execute(
            """
            INSERT INTO source_files(id, scan_root_id, relative_path, canonical_path, file_type, size_bytes, mtime_ns)
            VALUES (1, 1, 'a.jsonl', '/tmp/c/a.jsonl', 'jsonl_session', 1, 1),
                   (2, 1, 'subagents/b.jsonl', '/tmp/c/subagents/b.jsonl', 'jsonl_session', 1, 1)
            """
        )
        return database
    }

    private func calculator() -> CostCalculator {
        CostCalculator(snapshot: PricingSnapshot(
            snapshotVersion: "test",
            source: "litellm",
            models: ["claude-fable-5": ModelPricing(
                inputPerMTok: 10, outputPerMTok: 100, cacheReadPerMTok: 1,
                cacheWrite5mPerMTok: 12.5, cacheWrite1hPerMTok: 20
            )]
        ))
    }

    private func session(_ events: [UsageEvent]) -> ParsedSession {
        ParsedSession(
            sourceKind: .claudeJSONL,
            sessionKey: "s1",
            projectPath: "/repo",
            cliVersion: "1.0",
            startedAt: events.first?.observedAt,
            updatedAt: events.last?.observedAt,
            events: events,
            rawMeta: ["source": "claude-code"]
        )
    }

    private func event(seq: Int, at seconds: TimeInterval, input: Int64 = 1_000_000, model: String? = "claude-fable-5") -> UsageEvent {
        UsageEvent(
            eventSeq: seq,
            observedAt: Date(timeIntervalSince1970: seconds),
            modelName: model,
            inputTokens: input,
            sourceOffset: Int64(seq * 100)
        )
    }

    func testWritesOneRowPerEventAndComputesCost() throws {
        let database = try makeDatabase()
        let writer = UsageEventWriter(database: database, costCalculator: calculator())

        try writer.write(session(([1, 2].map { event(seq: $0, at: TimeInterval($0)) })), scanRootId: 1, sourceFileId: 1, runId: nil)

        let rows = try database.query("SELECT event_seq, cost_usd_micros, cost_source, model_canonical FROM usage_events ORDER BY event_seq")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].int("cost_usd_micros"), 10_000_000)
        XCTAssertEqual(rows[0].string("cost_source"), "computed")
        XCTAssertEqual(rows[0].string("model_canonical"), "claude-fable-5")
    }

    func testUnknownModelStoresNullCostNotZero() throws {
        let database = try makeDatabase()
        let writer = UsageEventWriter(database: database, costCalculator: calculator())

        try writer.write(session([event(seq: 1, at: 1, model: "totally-unlisted")]), scanRootId: 1, sourceFileId: 1, runId: nil)

        let rows = try database.query("SELECT cost_usd_micros, cost_source FROM usage_events")
        XCTAssertNil(rows[0].int("cost_usd_micros"))
        XCTAssertEqual(rows[0].string("cost_source"), "unknown")
    }

    func testSameSessionAcrossTwoSourceFilesKeepsBothEventSeqNamespaces() throws {
        let database = try makeDatabase()
        let writer = UsageEventWriter(database: database, costCalculator: calculator())

        // 父文件与 subagent 文件的 sessionId 相同，event_seq 各自从 1 开始
        try writer.write(session([event(seq: 1, at: 1)]), scanRootId: 1, sourceFileId: 1, runId: nil)
        try writer.write(session([event(seq: 1, at: 2)]), scanRootId: 1, sourceFileId: 2, runId: nil)

        let count = try database.query("SELECT count(*) AS n FROM usage_events")[0].int("n")
        XCTAssertEqual(count, 2, "UNIQUE(source_file_id, event_seq) 而非 UNIQUE(session_id, event_seq)")

        let sessions = try database.query("SELECT count(*) AS n FROM agent_sessions")[0].int("n")
        XCTAssertEqual(sessions, 1)
    }

    func testDedupeKeyCollisionKeepsEarliestObservedAt() throws {
        let database = try makeDatabase()
        let writer = UsageEventWriter(database: database, costCalculator: calculator())

        let later = UsageEvent(eventSeq: 1, observedAt: Date(timeIntervalSince1970: 200), modelName: "claude-fable-5",
                               messageId: "m1", requestId: "r1", inputTokens: 1, sourceOffset: 10)
        let earlier = UsageEvent(eventSeq: 1, observedAt: Date(timeIntervalSince1970: 100), modelName: "claude-fable-5",
                                 messageId: "m1", requestId: "r1", inputTokens: 1, sourceOffset: 20)

        // 先写晚的，再写早的：必须被早的替换，而不是 INSERT OR IGNORE 保留先来的
        try writer.write(session([later]), scanRootId: 1, sourceFileId: 1, runId: nil)
        try writer.write(session([earlier]), scanRootId: 1, sourceFileId: 2, runId: nil)

        let rows = try database.query("SELECT observed_epoch_ms FROM usage_events")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].int("observed_epoch_ms"), 100_000)
    }

    func testResumeOffsetIsPerSourceFile() throws {
        let database = try makeDatabase()
        let writer = UsageEventWriter(database: database, costCalculator: calculator())

        try writer.write(session([event(seq: 1, at: 1)]), scanRootId: 1, sourceFileId: 1, runId: nil)   // offset 100
        try writer.write(session([event(seq: 3, at: 3)]), scanRootId: 1, sourceFileId: 2, runId: nil)   // offset 300

        XCTAssertEqual(try writer.lastSourceOffset(sourceFileId: 1), 100)
        XCTAssertEqual(try writer.lastSourceOffset(sourceFileId: 2), 300)
        XCTAssertNil(try writer.lastSourceOffset(sourceFileId: 99))
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter UsageEventWriterTests`
Expected: 编译失败，`cannot find 'UsageEventWriter' in scope`

- [ ] **Step 3: 实现**

`Sources/TokenMeterCore/UsageEventWriter.swift`：

```swift
import Foundation

public final class UsageEventWriter {
    private let database: SQLiteDatabase
    private let costCalculator: CostCalculator
    private let formatter = ISO8601DateFormatter()

    public init(database: SQLiteDatabase, costCalculator: CostCalculator) {
        self.database = database
        self.costCalculator = costCalculator
        formatter.formatOptions = [.withInternetDateTime]
    }

    public func write(_ session: ParsedSession, scanRootId: Int64, sourceFileId: Int64, runId: Int64?) throws {
        try database.execute("BEGIN IMMEDIATE")
        do {
            let projectId = try upsertProject(session.projectPath)
            try upsertSession(session, scanRootId: scanRootId, projectId: projectId, runId: runId)
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

    /// 断点续读的位置按**文件**取。一个 session 横跨父 jsonl 与多个 subagent jsonl，
    /// 各文件的偏移互不相干。
    public func lastSourceOffset(sourceFileId: Int64) throws -> Int64? {
        let rows = try database.query(
            "SELECT max(source_offset) AS offset FROM usage_events WHERE source_file_id = ?",
            [.int(sourceFileId)]
        )
        return rows.first?.int("offset")
    }

    private func writeEvent(_ event: UsageEvent, sessionId: Int64, sourceFileId: Int64) throws {
        let (micros, source) = costCalculator.cost(for: event)

        // 唯一索引只能拦住重复插入。「保留时间戳更早的那条」必须先查后比，
        // 因为扫描顺序不保证时间顺序，INSERT OR IGNORE 会保留先写入的那条。
        if let dedupeKey = event.dedupeKey {
            let existing = try database.query(
                "SELECT id, observed_epoch_ms FROM usage_events WHERE session_id = ? AND dedupe_key = ?",
                [.int(sessionId), .text(dedupeKey)]
            )
            if let row = existing.first {
                guard let existingMs = row.int("observed_epoch_ms"), event.observedEpochMilliseconds < existingMs else {
                    return
                }
                try database.execute("DELETE FROM usage_events WHERE id = ?", [.int(row.int("id") ?? 0)])
            }
        }

        try database.execute(
            """
            INSERT INTO usage_events(
                session_id, source_file_id, event_seq, observed_epoch_ms,
                model_name, model_canonical,
                tokens_input, tokens_output, tokens_reasoning,
                tokens_cache_read, tokens_cache_write_5m, tokens_cache_write_1h,
                cost_usd_micros, cost_source, dedupe_key, source_offset, is_sidechain
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_file_id, event_seq) DO UPDATE SET
                observed_epoch_ms = excluded.observed_epoch_ms,
                model_name = excluded.model_name,
                model_canonical = excluded.model_canonical,
                tokens_input = excluded.tokens_input,
                tokens_output = excluded.tokens_output,
                tokens_reasoning = excluded.tokens_reasoning,
                tokens_cache_read = excluded.tokens_cache_read,
                tokens_cache_write_5m = excluded.tokens_cache_write_5m,
                tokens_cache_write_1h = excluded.tokens_cache_write_1h,
                cost_usd_micros = excluded.cost_usd_micros,
                cost_source = excluded.cost_source,
                dedupe_key = excluded.dedupe_key,
                source_offset = excluded.source_offset,
                is_sidechain = excluded.is_sidechain
            """,
            [
                .int(sessionId),
                .int(sourceFileId),
                .int(Int64(event.eventSeq)),
                .int(event.observedEpochMilliseconds),
                event.modelName.map { SQLiteValue.text($0) } ?? .null,
                .text(ModelNameNormalizer.canonical(event.modelName)),
                .int(event.inputTokens),
                .int(event.outputTokens),
                .int(event.reasoningTokens),
                .int(event.cacheReadTokens),
                .int(event.cacheWrite5mTokens),
                .int(event.cacheWrite1hTokens),
                micros.map { SQLiteValue.int($0) } ?? .null,
                .text(source.rawValue),
                event.dedupeKey.map { SQLiteValue.text($0) } ?? .null,
                .int(event.sourceOffset),
                .int(event.isSidechain ? 1 : 0)
            ]
        )
    }

    private func upsertSession(_ session: ParsedSession, scanRootId: Int64, projectId: Int64?, runId: Int64?) throws {
        try database.execute(
            """
            INSERT INTO agent_sessions(
                source_kind, source_session_key, scan_root_id, project_id, provider_id,
                cli_version, session_started_at, session_updated_at, cwd_path,
                status, source_revision, first_seen_run_id, last_seen_run_id, last_indexed_run_id, raw_meta_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, ?, ?, ?, ?)
            ON CONFLICT(source_kind, source_session_key) DO UPDATE SET
                scan_root_id = excluded.scan_root_id,
                project_id = coalesce(excluded.project_id, agent_sessions.project_id),
                provider_id = excluded.provider_id,
                cli_version = coalesce(excluded.cli_version, agent_sessions.cli_version),
                session_started_at = min(coalesce(agent_sessions.session_started_at, excluded.session_started_at), coalesce(excluded.session_started_at, agent_sessions.session_started_at)),
                session_updated_at = max(coalesce(agent_sessions.session_updated_at, excluded.session_updated_at), coalesce(excluded.session_updated_at, agent_sessions.session_updated_at)),
                cwd_path = coalesce(excluded.cwd_path, agent_sessions.cwd_path),
                status = 'active',
                source_revision = excluded.source_revision,
                last_seen_run_id = excluded.last_seen_run_id,
                last_indexed_run_id = excluded.last_indexed_run_id,
                raw_meta_json = excluded.raw_meta_json
            """,
            [
                .text(session.sourceKind.rawValue),
                .text(session.sessionKey),
                .int(scanRootId),
                projectId.map { SQLiteValue.int($0) } ?? .null,
                .text(providerId(for: session.sourceKind)),
                session.cliVersion.map { SQLiteValue.text($0) } ?? .null,
                session.startedAt.map { SQLiteValue.text(formatter.string(from: $0)) } ?? .null,
                session.updatedAt.map { SQLiteValue.text(formatter.string(from: $0)) } ?? .null,
                session.projectPath.map { SQLiteValue.text($0) } ?? .null,
                .text(sourceRevision(for: session)),
                runId.map { SQLiteValue.int($0) } ?? .null,
                runId.map { SQLiteValue.int($0) } ?? .null,
                runId.map { SQLiteValue.int($0) } ?? .null,
                .text(rawMetaJSON(session.rawMeta))
            ]
        )
    }

    private func lookupSessionId(sourceKind: SourceKind, sessionKey: String) throws -> Int64 {
        let rows = try database.query(
            "SELECT id FROM agent_sessions WHERE source_kind = ? AND source_session_key = ?",
            [.text(sourceKind.rawValue), .text(sessionKey)]
        )
        guard let id = rows.first?.int("id") else { throw LocalAgentParserError.missingSessionKey }
        return id
    }

    private func upsertProject(_ path: String?) throws -> Int64? {
        guard let path, !path.isEmpty else { return nil }
        let displayName = URL(fileURLWithPath: path).lastPathComponent
        let now = formatter.string(from: Date())
        try database.execute(
            """
            INSERT INTO projects(project_key, canonical_path, display_name, first_seen_at, last_seen_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(project_key) DO UPDATE SET last_seen_at = excluded.last_seen_at
            """,
            [.text(path), .text(path), .text(displayName.isEmpty ? path : displayName), .text(now), .text(now)]
        )
        return try database.query("SELECT id FROM projects WHERE project_key = ?", [.text(path)]).first?.int("id")
    }

    private func providerId(for sourceKind: SourceKind) -> String {
        switch sourceKind {
        case .claudeJSONL: return "claude-code"
        case .codexJSONL: return "codex"
        case .ompJSONL: return "omp"
        case .opencodeSQLite: return "opencode"
        }
    }

    private func sourceRevision(for session: ParsedSession) -> String {
        "\(session.sourceKind.rawValue):\(session.events.count)"
    }

    private func rawMetaJSON(_ rawMeta: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: rawMeta, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
```

不要碰 `LocalAgentUsageRepository`。它仍在把旧的 `ParsedAgentSession` 写进 v1 表，scanner 仍在调它。两条写入路径并存到 Task 14。

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter UsageEventWriterTests`
Expected: `Executed 5 tests, with 0 failures`

Run: `swift test`
Expected: **全绿。** 新写入器是新文件，旧 repository 与 scanner 一行未动。

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenMeterCore/UsageEventWriter.swift Tests/TokenMeterCoreTests/UsageEventWriterTests.swift
git commit -m "feat: write message-level usage events with cost"
```

---

## Task 12: RollupBuilder

`usage_date` 必须是**本地日期**。这修掉一个现存 bug：旧实现用 `substr(observed_at, 1, 10)` 取的是 UTC 日期，在东八区会把每天 00:00–08:00 的活动记入前一天。

**Files:**
- Create: `Sources/TokenMeterCore/RollupBuilder.swift`
- Test: `Tests/TokenMeterCoreTests/RollupBuilderTests.swift`

- [ ] **Step 1: 写失败的测试**

```swift
import XCTest
@testable import TokenMeterCore

final class RollupBuilderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        setenv("TZ", "Asia/Shanghai", 1)
        tzset()
    }

    override func tearDown() {
        unsetenv("TZ")
        tzset()
        super.tearDown()
    }

    private func makeDatabase() throws -> SQLiteDatabase {
        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)
        try database.execute("INSERT INTO scan_roots(id, kind, root_path, display_name, stable_source_key) VALUES (1,'claude_jsonl','/tmp/c','C','c')")
        try database.execute("INSERT INTO source_files(id, scan_root_id, relative_path, canonical_path, file_type, size_bytes, mtime_ns) VALUES (1,1,'a.jsonl','/tmp/c/a.jsonl','jsonl_session',1,1)")
        try database.execute("INSERT INTO projects(id, project_key, canonical_path, display_name, first_seen_at, last_seen_at) VALUES (1,'/repo','/repo','repo','x','x')")
        try database.execute("INSERT INTO agent_sessions(id, source_kind, source_session_key, scan_root_id, project_id, provider_id, source_revision) VALUES (1,'claude_jsonl','s1',1,1,'claude-code','r')")
        return database
    }

    private func insertEvent(_ database: SQLiteDatabase, seq: Int, iso: String, model: String, input: Int64, cost: Int64?) throws {
        let ms = Int64(ISO8601DateFormatter().date(from: iso)!.timeIntervalSince1970 * 1000)
        try database.execute(
            """
            INSERT INTO usage_events(session_id, source_file_id, event_seq, observed_epoch_ms, model_canonical,
                                     tokens_input, cost_usd_micros, cost_source, source_offset)
            VALUES (1, 1, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.int(Int64(seq)), .int(ms), .text(model), .int(input),
             cost.map { SQLiteValue.int($0) } ?? .null, .text(cost == nil ? "unknown" : "computed"), .int(Int64(seq))]
        )
    }

    func testUsesLocalDateNotUTCDate() throws {
        let database = try makeDatabase()
        // UTC 2026-07-08T16:30:00Z 在东八区是 2026-07-09 00:30
        try insertEvent(database, seq: 1, iso: "2026-07-08T16:30:00Z", model: "m", input: 10, cost: 100)

        try RollupBuilder(database: database).rebuildAll()

        let rows = try database.query("SELECT usage_date FROM daily_rollup")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].string("usage_date"), "2026-07-09", "旧实现的 substr(observed_at,1,10) 会给出 2026-07-08")
    }

    func testSplitsCrossDaySessionAcrossDays() throws {
        let database = try makeDatabase()
        try insertEvent(database, seq: 1, iso: "2026-07-07T05:00:00Z", model: "m", input: 10, cost: 100)
        try insertEvent(database, seq: 2, iso: "2026-07-08T05:00:00Z", model: "m", input: 20, cost: 200)

        try RollupBuilder(database: database).rebuildAll()

        let rows = try database.query("SELECT usage_date, tokens_input FROM daily_rollup ORDER BY usage_date")
        XCTAssertEqual(rows.count, 2, "跨天会话不能全部记在最后一天")
        XCTAssertEqual(rows[0].int("tokens_input"), 10)
        XCTAssertEqual(rows[1].int("tokens_input"), 20)
    }

    func testSplitsByModelWithinOneDay() throws {
        let database = try makeDatabase()
        try insertEvent(database, seq: 1, iso: "2026-07-08T05:00:00Z", model: "claude-fable-5", input: 10, cost: 100)
        try insertEvent(database, seq: 2, iso: "2026-07-08T06:00:00Z", model: "claude-opus-4-8", input: 20, cost: 200)

        try RollupBuilder(database: database).rebuildAll()

        let rows = try database.query("SELECT model_canonical, tokens_input FROM daily_rollup ORDER BY model_canonical")
        XCTAssertEqual(rows.count, 2, "会话内换模型必须各归各的")
        XCTAssertEqual(rows[0].string("model_canonical"), "claude-fable-5")
        XCTAssertEqual(rows[1].string("model_canonical"), "claude-opus-4-8")
    }

    func testCountsUnknownCostEventsSeparately() throws {
        let database = try makeDatabase()
        try insertEvent(database, seq: 1, iso: "2026-07-08T05:00:00Z", model: "m", input: 10, cost: nil)
        try insertEvent(database, seq: 2, iso: "2026-07-08T06:00:00Z", model: "m", input: 20, cost: 200)

        try RollupBuilder(database: database).rebuildAll()

        let row = try database.query("SELECT cost_usd_micros, cost_unknown_events FROM daily_rollup")[0]
        XCTAssertEqual(row.int("cost_usd_micros"), 200, "未知成本按 NULL 处理，不静默累加为 0")
        XCTAssertEqual(row.int("cost_unknown_events"), 1)
    }

    func testBuildsSessionRollupWithPrimaryModel() throws {
        let database = try makeDatabase()
        try insertEvent(database, seq: 1, iso: "2026-07-08T05:00:00Z", model: "claude-fable-5", input: 1000, cost: 100)
        try insertEvent(database, seq: 2, iso: "2026-07-08T06:00:00Z", model: "claude-opus-4-8", input: 10, cost: 200)

        try RollupBuilder(database: database).rebuildAll()

        let row = try database.query("SELECT events_count, tokens_total, cost_usd_micros, primary_model, first_event_epoch_ms, last_event_epoch_ms FROM session_rollup")[0]
        XCTAssertEqual(row.int("events_count"), 2)
        XCTAssertEqual(row.int("tokens_total"), 1010)
        XCTAssertEqual(row.int("cost_usd_micros"), 300)
        XCTAssertEqual(row.string("primary_model"), "claude-fable-5", "token 最多的模型")
        XCTAssertLessThan(row.int("first_event_epoch_ms")!, row.int("last_event_epoch_ms")!)
    }

    func testSessionRollupCountsUnknownCostEvents() throws {
        let database = try makeDatabase()
        // 会话中途换到未定价的模型。sum() 静默跳过 NULL 行，
        // 金额会偏低却看起来精确——这比缺失更有害，UI 必须能察觉。
        try insertEvent(database, seq: 1, iso: "2026-07-08T05:00:00Z", model: "claude-fable-5", input: 1000, cost: 100)
        try insertEvent(database, seq: 2, iso: "2026-07-08T06:00:00Z", model: "unlisted-model", input: 500, cost: nil)

        try RollupBuilder(database: database).rebuildAll()

        let row = try database.query("SELECT cost_usd_micros, cost_unknown_events FROM session_rollup")[0]
        XCTAssertEqual(row.int("cost_usd_micros"), 100, "只累加已知成本")
        XCTAssertEqual(row.int("cost_unknown_events"), 1, "但必须记下有 1 条未计入")
    }

    func testRebuildIsIdempotent() throws {
        let database = try makeDatabase()
        try insertEvent(database, seq: 1, iso: "2026-07-08T05:00:00Z", model: "m", input: 10, cost: 100)

        let builder = RollupBuilder(database: database)
        try builder.rebuildAll()
        try builder.rebuildAll()

        XCTAssertEqual(try database.query("SELECT count(*) AS n FROM daily_rollup")[0].int("n"), 1)
        XCTAssertEqual(try database.query("SELECT count(*) AS n FROM session_rollup")[0].int("n"), 1)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter RollupBuilderTests`
Expected: 编译失败，`cannot find 'RollupBuilder' in scope`

- [ ] **Step 3: 实现**

`Sources/TokenMeterCore/RollupBuilder.swift`：

```swift
import Foundation

/// 两张汇总表都是 `usage_events` 的纯函数投影，随时可以整体重建。
/// 时区变更后重建即可，不必重扫源文件。
public final class RollupBuilder {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    public func rebuildAll() throws {
        try database.execute("BEGIN IMMEDIATE")
        do {
            try rebuildDailyRollup()
            try rebuildSessionRollup()
            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
    }

    private func rebuildDailyRollup() throws {
        try database.execute("DELETE FROM daily_rollup")
        // 'localtime' 用进程时区把 UTC 毫秒转成本地日期。
        // 这是 usage_date 唯一正确的来源：直接 substr(ISO 字符串) 拿到的是 UTC 日期。
        try database.execute(
            """
            INSERT INTO daily_rollup(
                usage_date, provider_id, source_kind, project_id, model_canonical,
                sessions_count, events_count,
                tokens_input, tokens_output, tokens_reasoning,
                tokens_cache_read, tokens_cache_write_5m, tokens_cache_write_1h,
                cost_usd_micros, cost_unknown_events
            )
            SELECT
                date(e.observed_epoch_ms / 1000, 'unixepoch', 'localtime') AS usage_date,
                coalesce(s.provider_id, 'unknown'),
                s.source_kind,
                s.project_id,
                coalesce(e.model_canonical, 'unknown'),
                count(DISTINCT e.session_id),
                count(*),
                coalesce(sum(e.tokens_input), 0),
                coalesce(sum(e.tokens_output), 0),
                coalesce(sum(e.tokens_reasoning), 0),
                coalesce(sum(e.tokens_cache_read), 0),
                coalesce(sum(e.tokens_cache_write_5m), 0),
                coalesce(sum(e.tokens_cache_write_1h), 0),
                coalesce(sum(e.cost_usd_micros), 0),
                sum(CASE WHEN e.cost_source = 'unknown' THEN 1 ELSE 0 END)
            FROM usage_events e
            JOIN agent_sessions s ON s.id = e.session_id
            WHERE s.status != 'deleted'
            GROUP BY usage_date, s.provider_id, s.source_kind, s.project_id, e.model_canonical
            """
        )
    }

    private func rebuildSessionRollup() throws {
        try database.execute("DELETE FROM session_rollup")
        try database.execute(
            """
            INSERT INTO session_rollup(
                session_id, first_event_epoch_ms, last_event_epoch_ms,
                events_count, tokens_total, cost_usd_micros, cost_unknown_events, primary_model
            )
            SELECT
                e.session_id,
                min(e.observed_epoch_ms),
                max(e.observed_epoch_ms),
                count(*),
                coalesce(sum(e.tokens_total), 0),
                coalesce(sum(e.cost_usd_micros), 0),
                sum(CASE WHEN e.cost_source = 'unknown' THEN 1 ELSE 0 END),
                (
                    SELECT x.model_canonical
                    FROM usage_events x
                    WHERE x.session_id = e.session_id AND x.model_canonical IS NOT NULL
                    GROUP BY x.model_canonical
                    ORDER BY sum(x.tokens_total) DESC, x.model_canonical ASC
                    LIMIT 1
                )
            FROM usage_events e
            GROUP BY e.session_id
            """
        )
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter RollupBuilderTests`
Expected: `Executed 6 tests, with 0 failures`

若 `testUsesLocalDateNotUTCDate` 得到 `2026-07-08`，说明 `'localtime'` modifier 没生效，检查测试是否正确设置了 `TZ`。

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenMeterCore/RollupBuilder.swift Tests/TokenMeterCoreTests/RollupBuilderTests.swift
git commit -m "fix: build rollups from local dates instead of UTC"
```

---

## Task 13: JSONLStreamReader 性能重写与字节预筛

`readLines` 现在的内层循环是 `for byte in chunk { currentLine.append(byte) }`——**逐字节 append**。对那个 3.28 GB 的 Codex 文件，这是 33 亿次单字节 append。

预筛只对 **Codex** 启用：它的大文件里 `function_call` / `function_call_output` 占了 25 万行中的 10 万行，都不含 `token_count` / `session_meta` / `turn_context` 任一标记。
Claude 与 omp **不预筛**——它们的 `sessionId`、`cwd`、`version` 分散在各类行里，滤掉会丢元信息，且单文件都不大。

**Files:**
- Modify: `Sources/TokenMeterCore/JSONLStreamReader.swift`
- Test: `Tests/TokenMeterCoreTests/JSONLStreamReaderTests.swift`

- [ ] **Step 1: 写失败的测试**

追加到 `Tests/TokenMeterCoreTests/JSONLStreamReaderTests.swift`：

```swift
    func testSkipsLinesWithoutAnyMarker() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("marker-\(UUID().uuidString).jsonl")
        let content = """
        {"type":"response_item","payload":{"type":"function_call"}}
        {"type":"event_msg","payload":{"type":"token_count"}}
        {"type":"response_item","payload":{"type":"function_call_output"}}
        {"type":"turn_context","payload":{"model":"gpt-5.5"}}

        """
        try content.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try JSONLStreamReader.readLines(
            from: url,
            startingAt: 0,
            markers: ["token_count", "turn_context"]
        )

        XCTAssertEqual(result.lines.count, 2)
        XCTAssertTrue(result.lines[0].text.contains("token_count"))
        XCTAssertTrue(result.lines[1].text.contains("turn_context"))
    }

    func testMarkerFilteringPreservesTrueByteOffsets() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("offset-\(UUID().uuidString).jsonl")
        let first = #"{"skip":1}"#
        let second = #"{"keep":"token_count"}"#
        try "\(first)\n\(second)\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try JSONLStreamReader.readLines(from: url, startingAt: 0, markers: ["token_count"])

        XCTAssertEqual(result.lines.count, 1)
        // 被跳过的行仍然要把 offset 推进，否则续读会错位
        XCTAssertEqual(result.lines[0].offset, Int64(first.utf8.count + 1))
    }

    func testNilMarkersKeepsEveryLine() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("all-\(UUID().uuidString).jsonl")
        try "{\"a\":1}\n{\"b\":2}\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try JSONLStreamReader.readLines(from: url, startingAt: 0, markers: nil)

        XCTAssertEqual(result.lines.count, 2)
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter JSONLStreamReaderTests`
Expected: 编译失败，`extra argument 'markers' in call`

- [ ] **Step 3: 实现**

`Sources/TokenMeterCore/JSONLStreamReader.swift` 的 `readLines` 私有实现替换为：

```swift
    /// 把所有行读进数组。**仅供测试与小文件使用。**
    /// 生产扫描路径必须用下面的 onLine 回调版本：3.28 GB 的 Codex session 文件
    /// 有 257,115 行，全部 materialize 会吃掉数 GB 内存。
    public static func readLines(
        from url: URL,
        startingAt offset: Int64,
        markers: [String]? = nil
    ) throws -> JSONLReadResult {
        try readLines(from: url, startingAt: offset, chunkSize: 256 * 1024, markers: markers, retainingLines: true, onLine: nil)
    }

    /// 流式版本：逐行回调，不保留任何行。生产路径走这里。
    public static func readLines(
        from url: URL,
        startingAt offset: Int64,
        markers: [String]? = nil,
        onLine: @escaping (JSONLLine) throws -> Void
    ) throws -> JSONLReadResult {
        try readLines(from: url, startingAt: offset, chunkSize: 256 * 1024, markers: markers, retainingLines: false, onLine: onLine)
    }

    private static func readLines(
        from url: URL,
        startingAt offset: Int64,
        chunkSize: Int,
        markers: [String]?,
        retainingLines: Bool,
        onLine: ((JSONLLine) throws -> Void)?
    ) throws -> JSONLReadResult {
        precondition(offset >= 0, "JSONL offset must be non-negative")
        precondition(chunkSize > 0, "JSONL chunk size must be positive")

        let markerBytes = markers?.map { Data($0.utf8) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))

        var lines: [JSONLLine] = []
        var currentLine = Data()
        var currentLineOffset = offset
        var consumed = offset

        func flush(_ lineEndOffset: Int64) throws {
            defer {
                currentLine.removeAll(keepingCapacity: true)
                currentLineOffset = lineEndOffset
            }
            guard !currentLine.isEmpty else { return }
            // 预筛：字节层面判断，命中才付出 JSON 解析的代价
            if let markerBytes, !markerBytes.contains(where: { currentLine.range(of: $0) != nil }) {
                return
            }
            let line = JSONLLine(
                text: String(decoding: currentLine, as: UTF8.self),
                offset: currentLineOffset,
                nextOffset: lineEndOffset
            )
            if retainingLines { lines.append(line) } else { try onLine?(line) }
        }

        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            var cursor = chunk.startIndex
            // 按换行切片，而不是逐字节 append
            while let newline = chunk[cursor...].firstIndex(of: newlineByte) {
                currentLine.append(contentsOf: chunk[cursor..<newline])
                consumed += Int64(chunk.distance(from: cursor, to: newline)) + 1
                try flush(consumed)
                cursor = chunk.index(after: newline)
            }
            if cursor < chunk.endIndex {
                currentLine.append(contentsOf: chunk[cursor...])
                consumed += Int64(chunk.distance(from: cursor, to: chunk.endIndex))
            }
        }

        let residual = currentLine.isEmpty ? nil : String(decoding: currentLine, as: UTF8.self)
        return JSONLReadResult(lines: lines, nextOffset: currentLineOffset, residual: residual)
    }
```

- [ ] **Step 4: 运行全部 reader 测试**

Run: `swift test --filter JSONLStreamReaderTests`
Expected: 原有测试 + 3 个新测试全部通过。

用真实大文件验证吞吐（可选但强烈建议）：

```bash
swift run -c release TokenMeterApp --benchmark-jsonl ~/.codex/sessions/2026/06/22/rollout-2026-06-22T18-24-18-019eeedc-0b47-7a63-867b-3d2fde8ef856.jsonl
```

若尚未有该 CLI 入口，用一个一次性的 XCTest performance test 代替，断言 3.28 GB 文件在 60 秒内读完。

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenMeterCore/JSONLStreamReader.swift Tests/TokenMeterCoreTests/JSONLStreamReaderTests.swift
git commit -m "perf: chunk-slice jsonl reader and add byte-level marker prefilter"
```

---

## Task 14: LocalAgentScanner 断点续读

**Files:**
- Modify: `Sources/TokenMeterCore/LocalAgentScanner.swift`
- Test: `Tests/TokenMeterCoreTests/LocalAgentScannerTests.swift`

- [ ] **Step 1: 写失败的测试**

追加到 `Tests/TokenMeterCoreTests/LocalAgentScannerTests.swift`：

```swift
    func testResumesFromLastSourceOffsetPerFile() throws {
        let (database, rootURL) = try makeScannerFixture(kind: .claudeJSONL)
        let file = rootURL.appendingPathComponent("a.jsonl")

        let first = #"{"type":"assistant","timestamp":"2026-07-08T01:00:00Z","sessionId":"s1","requestId":"r1","message":{"id":"m1","role":"assistant","model":"claude-fable-5","usage":{"input_tokens":10}}}"#
        try "\(first)\n".write(to: file, atomically: true, encoding: .utf8)
        try makeScanner(database).scanAll()

        XCTAssertEqual(try database.query("SELECT count(*) AS n FROM usage_events")[0].int("n"), 1)

        // 追加一行，再扫一次：只应新增一条，不应重解析第一行
        let second = #"{"type":"assistant","timestamp":"2026-07-08T02:00:00Z","sessionId":"s1","requestId":"r2","message":{"id":"m2","role":"assistant","model":"claude-fable-5","usage":{"input_tokens":20}}}"#
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\(second)\n".utf8))
        try handle.close()

        try makeScanner(database).scanAll()

        let rows = try database.query("SELECT event_seq, tokens_input FROM usage_events ORDER BY event_seq")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1].int("event_seq"), 2, "event_seq 必须从 parser_state 续上，不能重置为 1")
        XCTAssertEqual(rows[1].int("tokens_input"), 20)
    }

    func testSubagentFileGetsItsOwnEventSeqNamespace() throws {
        let (database, rootURL) = try makeScannerFixture(kind: .claudeJSONL)
        let sessionDir = rootURL.appendingPathComponent("proj/sess-1")
        let subagentDir = sessionDir.appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: subagentDir, withIntermediateDirectories: true)

        // subagent 文件的 sessionId 与父 session 相同
        let parent = #"{"type":"assistant","timestamp":"2026-07-08T01:00:00Z","sessionId":"sess-1","cwd":"/repo","requestId":"r1","message":{"id":"m1","role":"assistant","model":"m","usage":{"input_tokens":10}}}"#
        let child = #"{"type":"assistant","timestamp":"2026-07-08T01:01:00Z","sessionId":"sess-1","isSidechain":true,"requestId":"r2","message":{"id":"m2","role":"assistant","model":"m","usage":{"input_tokens":5}}}"#
        try "\(parent)\n".write(to: sessionDir.appendingPathComponent("main.jsonl"), atomically: true, encoding: .utf8)
        try "\(child)\n".write(to: subagentDir.appendingPathComponent("agent-1.jsonl"), atomically: true, encoding: .utf8)

        try makeScanner(database).scanAll()

        XCTAssertEqual(try database.query("SELECT count(*) AS n FROM agent_sessions")[0].int("n"), 1, "同一 sessionId 只有一个 session")
        XCTAssertEqual(try database.query("SELECT count(*) AS n FROM usage_events")[0].int("n"), 2)
        XCTAssertEqual(try database.query("SELECT count(DISTINCT source_file_id) AS n FROM usage_events")[0].int("n"), 2)
        XCTAssertEqual(try database.query("SELECT count(*) AS n FROM usage_events WHERE is_sidechain = 1")[0].int("n"), 1)
    }
```

`makeScannerFixture` 与 `makeScanner` 是该测试文件中已有的辅助函数；若不存在，按现有测试的建库方式补一个：建内存库 + `TokenMeterDatabaseMigrator.migrate` + 插入一条 `scan_roots`，并返回临时目录 URL。

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter LocalAgentScannerTests`
Expected: FAIL，`no such table: usage_events` 或 event_seq 重置为 1

- [ ] **Step 3: 实现**

在 `LocalAgentScanner` 里，把解析单个 JSONL 文件的那段（原 `:225` 附近调用 `repository.upsert`）改为：

```swift
    private func parseJSONLFile(
        _ fileURL: URL,
        fileId: Int64,
        root: ScanRoot,
        runId: Int64
    ) throws {
        // 续读位置按文件取：一个 session 横跨父 jsonl 与多个 subagent jsonl
        let startOffset = try writer.lastSourceOffset(sourceFileId: fileId).map { $0 + 1 } ?? 0
        let state = try loadParserState(fileId: fileId)
        guard let parser = streamingParser(for: root.kind, resuming: state) else { return }

        // 流式：逐行喂给 parser，不保留 [JSONLLine]
        var sawLine = false
        _ = try JSONLStreamReader.readLines(
            from: fileURL,
            startingAt: startOffset,
            markers: markers(for: root.kind)
        ) { line in
            sawLine = true
            parser.consume(line)
        }
        guard sawLine else { return }

        let (session, nextState) = try parser.finish(sourceURL: fileURL)
        try writer.write(session, scanRootId: root.id, sourceFileId: fileId, runId: runId)
        try saveParserState(nextState, fileId: fileId)
    }

    private func streamingParser(for kind: SourceKind, resuming state: ParserState?) -> UsageEventParser? {
        switch kind {
        case .claudeJSONL: return ClaudeCodeUsageEventParser(resuming: state)
        case .codexJSONL: return CodexUsageEventParser(resuming: state)
        case .ompJSONL: return OmpUsageEventParser(resuming: state)
        case .opencodeSQLite: return nil   // SQLite 走 OpenCodeUsageEventAdapter
        }
    }

    /// 只有 Codex 预筛。它的大文件里 function_call 占多数且不含任一标记。
    /// Claude / omp 的 sessionId、cwd、version 分散在各类行里，滤掉会丢元信息。
    private func markers(for kind: SourceKind) -> [String]? {
        switch kind {
        case .codexJSONL: return ["token_count", "session_meta", "turn_context"]
        case .claudeJSONL, .ompJSONL, .opencodeSQLite: return nil
        }
    }

    private func loadParserState(fileId: Int64) throws -> ParserState? {
        let rows = try database.query("SELECT parser_state FROM source_files WHERE id = ?", [.int(fileId)])
        guard let json = rows.first?.string("parser_state"), let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ParserState.self, from: data)
    }

    private func saveParserState(_ state: ParserState, fileId: Int64) throws {
        let data = try JSONEncoder().encode(state)
        try database.execute(
            "UPDATE source_files SET parser_state = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
            [.text(String(decoding: data, as: UTF8.self)), .int(fileId)]
        )
    }
```

扫描完一个 root 之后调用 `RollupBuilder(database: database).rebuildAll()`。

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter LocalAgentScannerTests`
Expected: 全部通过

Run: `swift test`
Expected: 整个包的测试全绿。这是 Task 6-14 的汇合点。

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenMeterCore/LocalAgentScanner.swift Tests/TokenMeterCoreTests/LocalAgentScannerTests.swift
git commit -m "feat: resume jsonl parsing per source file"
```

---

## Task 15: 全量重扫与进度事件

**Files:**
- Modify: `Sources/TokenMeterCore/LocalAgentScanner.swift`
- Modify: `Sources/TokenMeterApp/TokenMeterIPCServer.swift`
- Modify: `Electron/src/main/tokenMeterSocketClient.ts`
- Test: `Tests/TokenMeterAppTests/TokenMeterIPCServerTests.swift`

- [ ] **Step 1: 写失败的测试**

追加到 `Tests/TokenMeterAppTests/TokenMeterIPCServerTests.swift`：

```swift
    func testFullRescanRequestClearsUsageEventsAndEmitsProgress() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)

        var progressEvents: [ScanProgressEvent] = []
        let scanner = makeScanner(database) { progressEvents.append($0) }

        try scanner.fullRescan()

        XCTAssertEqual(try database.query("SELECT count(*) AS n FROM usage_events")[0].int("n"), 0)
        XCTAssertFalse(progressEvents.isEmpty)
        XCTAssertEqual(progressEvents.last?.filesDone, progressEvents.last?.filesTotal)
    }

    func testFullRescanResetsParserStateAndOffsets() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)
        try database.execute("INSERT INTO scan_roots(id, kind, root_path, display_name, stable_source_key) VALUES (1,'claude_jsonl','/tmp/c','C','c')")
        try database.execute(
            """
            INSERT INTO source_files(id, scan_root_id, relative_path, canonical_path, file_type, size_bytes, mtime_ns, parser_state)
            VALUES (1, 1, 'a.jsonl', '/tmp/c/a.jsonl', 'jsonl_session', 1, 1, '{"lastEventSeq":42}')
            """
        )

        try makeScanner(database) { _ in }.fullRescan()

        let state = try database.query("SELECT parser_state FROM source_files WHERE id = 1")[0].string("parser_state")
        XCTAssertNil(state, "全量重扫必须清空 parser_state，否则 event_seq 会从 42 续下去")
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter TokenMeterIPCServerTests`
Expected: 编译失败，`value of type 'LocalAgentScanner' has no member 'fullRescan'`

- [ ] **Step 3: 实现**

在 `LocalAgentScanner` 增加：

```swift
public struct ScanProgressEvent: Equatable, Codable {
    public let filesTotal: Int
    public let filesDone: Int
    public let bytesTotal: Int64
    public let bytesDone: Int64
    public let currentRoot: String
}

extension LocalAgentScanner {
    /// 用户显式触发。清空明细与解析状态，重新读全部源文件。
    /// 不清 scan_roots（配置）与 settings。
    public func fullRescan() throws {
        try database.execute("DELETE FROM usage_events")
        try database.execute("DELETE FROM daily_rollup")
        try database.execute("DELETE FROM session_rollup")
        try database.execute("UPDATE source_files SET parser_state = NULL, parse_status = 'pending'")
        try database.execute("UPDATE scan_roots SET last_successful_cursor = NULL")
        try scanAll(runKind: .full)
        try RollupBuilder(database: database).rebuildAll()
    }
}
```

`scanAll` 在每处理完一个文件时调用 `progressHandler(ScanProgressEvent(...))`。

`TokenMeterIPCServer` 增加两条消息：

- 收：`{"kind":"scan.requestFull"}` → 在后台队列调用 `scanner.fullRescan()`
- 发：`{"kind":"scan.progress","filesTotal":N,"filesDone":M,"bytesTotal":X,"bytesDone":Y,"currentRoot":"..."}`
- 发：`{"kind":"scan.finished","status":"ok"}`

`Electron/src/main/tokenMeterSocketClient.ts` 增加 `onScanProgress(cb)` 与 `requestFullRescan()`，并在 `scan.finished` 时通过 `webContents.send('dashboard:invalidate')` 通知 renderer 重新查询。

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter TokenMeterIPCServerTests`
Expected: `Executed 2 tests, with 0 failures`

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenMeterCore/LocalAgentScanner.swift Sources/TokenMeterApp/TokenMeterIPCServer.swift Electron/src/main/tokenMeterSocketClient.ts Tests/TokenMeterAppTests/TokenMeterIPCServerTests.swift
git commit -m "feat: add full rescan with progress events"
```

---

## Task 16: Electron repository 适配 v2

Phase 1 结束时应用必须仍能启动、旧 UI 仍能显示。UI **组件不改**，只把底下的 SQL 换到新表。

**Files:**
- Modify: `Electron/src/main/dashboardRepository.ts`
- Modify: `Electron/src/main/sessionsRepository.ts`
- Test: `Electron/src/main/dashboardRepository.test.ts`
- Test: `Electron/src/main/sessionsRepository.test.ts`

- [ ] **Step 1: 写失败的测试**

在 `Electron/src/main/dashboardRepository.test.ts` 中，把建表 fixture 换成 v2 结构，并追加：

```typescript
it('sums tokens per day from daily_rollup, not from session-level rows', () => {
  db.exec(`
    INSERT INTO daily_rollup(usage_date, provider_id, source_kind, project_id, model_canonical,
                             sessions_count, events_count, tokens_input, tokens_output,
                             tokens_cache_read, cost_usd_micros, cost_unknown_events)
    VALUES ('2026-07-07', 'claude-code', 'claude_jsonl', NULL, 'claude-fable-5', 1, 3, 100, 10, 900, 500, 0),
           ('2026-07-08', 'claude-code', 'claude_jsonl', NULL, 'claude-fable-5', 1, 2, 200, 20, 0, 700, 0);
  `);

  const overview = new DashboardRepository(db).overview();

  expect(overview.dailyTrend).toEqual([
    { usageDate: '2026-07-07', tokensTotal: 1010, sessionsCount: 1 },
    { usageDate: '2026-07-08', tokensTotal: 220, sessionsCount: 1 }
  ]);
});

it('counts distinct sessions instead of summing daily_rollup.sessions_count', () => {
  // 同一个 session 当天用了两个模型，会在 daily_rollup 里占两行
  db.exec(`
    INSERT INTO agent_sessions(id, source_kind, source_session_key, scan_root_id, source_revision)
    VALUES (1, 'claude_jsonl', 's1', 1, 'r');
    INSERT INTO session_rollup(session_id, first_event_epoch_ms, last_event_epoch_ms, events_count, tokens_total, cost_usd_micros, primary_model)
    VALUES (1, 1000, 2000, 2, 300, 100, 'claude-fable-5');
    INSERT INTO daily_rollup(usage_date, provider_id, source_kind, project_id, model_canonical,
                             sessions_count, events_count, tokens_input, cost_usd_micros, cost_unknown_events)
    VALUES ('2026-07-08', 'claude-code', 'claude_jsonl', NULL, 'claude-fable-5', 1, 1, 100, 50, 0),
           ('2026-07-08', 'claude-code', 'claude_jsonl', NULL, 'claude-opus-4-8', 1, 1, 200, 50, 0);
  `);

  const overview = new DashboardRepository(db).overview();

  expect(overview.sessionCount).toBe(1);
  expect(overview.activeModelCount).toBe(2);
});

it('reports unknown-cost events so the UI does not silently treat them as zero', () => {
  db.exec(`
    INSERT INTO daily_rollup(usage_date, provider_id, source_kind, project_id, model_canonical,
                             sessions_count, events_count, tokens_input, cost_usd_micros, cost_unknown_events)
    VALUES ('2026-07-08', 'codex', 'codex_jsonl', NULL, 'gpt-5.5', 1, 5, 100, 0, 5);
  `);

  const overview = new DashboardRepository(db).overview();

  expect(overview.costUnknownEvents).toBe(5);
});
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd Electron && npx vitest run src/main/dashboardRepository.test.ts`
Expected: FAIL，`SqliteError: no such table: daily_rollup`

- [ ] **Step 3: 实现**

`Electron/src/main/dashboardRepository.ts` 的 `overview()` 改为：

```typescript
  overview(): DashboardOverview {
    const totals = this.db
      .prepare(
        `SELECT (SELECT count(*) FROM session_rollup) AS sessionCount,
                coalesce((SELECT sum(tokens_total) FROM session_rollup), 0) AS totalTokens,
                (SELECT count(DISTINCT model_canonical) FROM daily_rollup) AS activeModelCount,
                coalesce((SELECT sum(cost_usd_micros) FROM session_rollup), 0) AS totalCostUsdMicros,
                coalesce((SELECT sum(cost_unknown_events) FROM daily_rollup), 0) AS costUnknownEvents`
      )
      .get() as OverviewTotalsRow;

    const modelBreakdown = this.db
      .prepare(
        `SELECT model_canonical AS modelName,
                sum(sessions_count) AS sessionsCount,
                sum(tokens_input + tokens_output + tokens_cache_read + tokens_cache_write_5m + tokens_cache_write_1h) AS tokensTotal,
                sum(cost_usd_micros) AS costUsdMicros
         FROM daily_rollup
         GROUP BY model_canonical
         ORDER BY tokensTotal DESC, modelName ASC
         LIMIT 8`
      )
      .all() as DashboardModelBreakdownRow[];

    const providerBreakdown = this.db
      .prepare(
        `SELECT provider_id AS providerId,
                sum(sessions_count) AS sessionsCount,
                sum(tokens_input + tokens_output + tokens_cache_read + tokens_cache_write_5m + tokens_cache_write_1h) AS tokensTotal
         FROM daily_rollup
         GROUP BY provider_id
         ORDER BY tokensTotal DESC, providerId ASC`
      )
      .all() as DashboardProviderBreakdownRow[];

    const dailyTrend = this.db
      .prepare(
        `SELECT usage_date AS usageDate,
                sum(tokens_input + tokens_output + tokens_cache_read + tokens_cache_write_5m + tokens_cache_write_1h) AS tokensTotal,
                count(DISTINCT model_canonical) AS modelCount,
                max(sessions_count) AS sessionsCount
         FROM daily_rollup
         GROUP BY usage_date
         ORDER BY usage_date ASC
         LIMIT 30`
      )
      .all() as DashboardDailyTrendRow[];

    return { ...totals, modelBreakdown, providerBreakdown, dailyTrend };
  }
```

注意 `modelBreakdown.sessionsCount` 用 `sum` 是**近似值**（跨模型分组会重复计数）；`totals.sessionCount` 必须走 `session_rollup`。在 `DashboardOverview` 接口上加 `costUnknownEvents: number`。

`sessionsRepository.ts` 的 `query()` 把 `session_usage_latest` / `session_usage` 的 join 换成 `session_rollup`，`modelName` 取 `session_rollup.primary_model`。

- [ ] **Step 4: 运行测试确认通过**

Run: `cd Electron && npx vitest run`
Expected: 全部通过

Run: `cd Electron && npm run typecheck`
Expected: 无错误

- [ ] **Step 5: 提交**

```bash
git add Electron/src/main/dashboardRepository.ts Electron/src/main/sessionsRepository.ts Electron/src/main/dashboardRepository.test.ts Electron/src/main/sessionsRepository.test.ts Electron/src/renderer/api.ts
git commit -m "feat: query rollup tables from electron"
```

---

## Task 17: 与 ccusage 对账

最强的正确性验证：一个成熟的独立实现作为参照。两者定价表同源（LiteLLM）、去重键同构（`messageId::requestId`），数字应当吻合。

对账范围限于 ccusage 也支持的源：**Claude Code、Codex、OpenCode**。ccusage 不支持 omp。

**Files:**
- Create: `scripts/reconcile-with-ccusage.sh`

- [ ] **Step 1: 跑一次真实的全量重扫**

```bash
swift run -c release TokenMeterApp --full-rescan
```

Expected: 进度输出至完成。首次处理约 12.8 GB，耗时以分钟计。

- [ ] **Step 2: 写对账脚本**

`scripts/reconcile-with-ccusage.sh`：

```bash
#!/usr/bin/env bash
# 用 ccusage 作为 oracle 校验 daily_rollup 的 token 与成本。
# 用法: scripts/reconcile-with-ccusage.sh 20260601 20260630
set -euo pipefail

SINCE="${1:?usage: $0 <YYYYMMDD> <YYYYMMDD>}"
UNTIL="${2:?usage: $0 <YYYYMMDD> <YYYYMMDD>}"
DB="${TOKENMETER_DB:-$HOME/.token-meter/token-meter.db}"

command -v ccusage >/dev/null || { echo "ccusage not installed: npm i -g ccusage"; exit 1; }

echo "== ccusage (claude) =="
ccusage daily --json --since "$SINCE" --until "$UNTIL" \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
for row in d.get('daily', []):
    tok = row['inputTokens']+row['outputTokens']+row['cacheCreationTokens']+row['cacheReadTokens']
    print(f\"{row['date']}\t{tok}\t{row['totalCost']:.4f}\")
" | sort > /tmp/ccusage-daily.tsv

echo "== token-meter (claude-code) =="
sqlite3 -separator $'\t' "$DB" "
  SELECT usage_date,
         sum(tokens_input + tokens_output + tokens_cache_read + tokens_cache_write_5m + tokens_cache_write_1h),
         printf('%.4f', sum(cost_usd_micros) / 1000000.0)
  FROM daily_rollup
  WHERE provider_id = 'claude-code'
    AND replace(usage_date, '-', '') BETWEEN '$SINCE' AND '$UNTIL'
  GROUP BY usage_date
  ORDER BY usage_date;
" > /tmp/tokenmeter-daily.tsv

echo
echo "== diff（空输出 = 完全一致） =="
diff /tmp/ccusage-daily.tsv /tmp/tokenmeter-daily.tsv && echo "  ✅ 对账通过"
```

- [ ] **Step 3: 运行对账**

```bash
chmod +x scripts/reconcile-with-ccusage.sh
./scripts/reconcile-with-ccusage.sh 20260601 20260630
```

Expected: `✅ 对账通过`

**若有差异，按此顺序排查：**

1. **日期整体偏移一天** → 时区问题。ccusage 默认用系统本地时区，检查 `RollupBuilder` 的 `'localtime'` 是否生效。
2. **token 数偏大约 2 倍（仅 Codex）** → `inputTokens = input_tokens - cached_input_tokens` 这个减法没做（Task 8）。
3. **token 数偏大且含 reasoning** → `tokens_total` 生成列错误地加了 `tokens_reasoning`（Task 3）。
4. **成本偏低** → cache 分档计价缺失，或 `cost_source = 'unknown'` 的事件被当成 0（检查 `cost_unknown_events`）。
5. **token 数偏大且集中在少数会话** → sidechain 重放未被去重（Task 7 规则二）。

- [ ] **Step 4: 记录基线**

把对账结果与首次全量扫描耗时写入 `docs/superpowers/plans/2026-07-09-phase1-data-layer.md` 末尾的「实测记录」小节。

- [ ] **Step 5: 提交**

```bash
git add scripts/reconcile-with-ccusage.sh docs/superpowers/plans/2026-07-09-phase1-data-layer.md
git commit -m "test: add ccusage reconciliation script"
```

---

## Task 18: 清理 v1 遗留（schema v3 + 旧 parser）

到这一步为止：Task 11 让 writer 只写 `usage_events`，Task 14 让 scanner 只调新 parser 与 writer，Task 16 让 Electron 只查 rollup 表。三张 v1 用量表和一整套旧 parser 已经**无人读、无人写**。现在才能安全删掉。

除了下面的 schema v3，本任务还要删除这些死代码及其测试：

- `Sources/TokenMeterCore/LocalAgentSessionParsers.swift` 里的 `LocalAgentSessionParser`、`LocalAgentSessionStreamingParser`（`JSONDictionary` 与 `LocalAgentParserError` 保留，新 parser 仍在用）
- `ClaudeCodeSessionParser.swift`、`CodexSessionParser.swift`、`OmpSessionParser.swift`、`OpenCodeSessionAdapter.swift` 四个文件整体
- `LocalAgentModels.swift` 里的 `ParsedAgentSession`、`ParsedSessionUsage`、`ParsedSessionUsageKind`（`SourceKind`、`SourceFileFingerprint` 保留）
- `LocalAgentUsageRepository.swift` 整体（职责已由 `UsageEventWriter` 接管）
- 对应的旧测试文件

删完跑 `swift test`，只应剩下新 parser 的测试。

排在 Task 16 之后不是随意的：在此之前 `dashboardRepository.ts` 仍在查 `provider_daily_usage`，提前删表会让 Electron 测试全红。

**升级路径说明：** v1 用户迁移到 v2/v3 后 `usage_events` 是空表。不在迁移里自动重扫——12.8 GB 要跑几分钟，不该在应用启动时静默发生。由 Task 15 的「全量重扫」按钮显式触发。

**Files:**
- Modify: `Sources/TokenMeterCore/TokenMeterDatabaseSchema.swift`
- Modify: `Sources/TokenMeterCore/TokenMeterDatabaseMigrator.swift`
- Test: `Tests/TokenMeterCoreTests/TokenMeterDatabaseMigratorTests.swift`

- [ ] **Step 1: 写失败的测试**

```swift
    func testMigrationToV3DropsLegacyUsageTables() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)

        XCTAssertEqual(try database.query("PRAGMA user_version")[0].int("user_version"), 3)

        let tables = try database.query("SELECT name FROM sqlite_master WHERE type = 'table'")
            .compactMap { $0.string("name") }
        XCTAssertFalse(tables.contains("session_usage"))
        XCTAssertFalse(tables.contains("session_usage_latest"))
        XCTAssertFalse(tables.contains("provider_daily_usage"))

        // 新表必须还在
        XCTAssertTrue(tables.contains("usage_events"))
        XCTAssertTrue(tables.contains("daily_rollup"))
        XCTAssertTrue(tables.contains("session_rollup"))
    }

    func testMigrationToV3DropsRedundantSessionColumns() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)

        let columns = try database.query("PRAGMA table_info(agent_sessions)")
            .compactMap { $0.string("name") }

        // model_name 已下沉到 usage_events；留着会误导下一个读代码的人
        XCTAssertFalse(columns.contains("model_name"))
        XCTAssertFalse(columns.contains("source_file_id"))
        XCTAssertFalse(columns.contains("total_cost_usd_micros"))

        // 会话元信息保留
        XCTAssertTrue(columns.contains("source_session_key"))
        XCTAssertTrue(columns.contains("project_id"))
        XCTAssertTrue(columns.contains("provider_id"))
    }

    func testV1DatabaseMigratesAllTheWayToV3() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try database.execute(TokenMeterDatabaseSchema.v1)

        try TokenMeterDatabaseMigrator.migrate(database)

        XCTAssertEqual(try database.query("PRAGMA user_version")[0].int("user_version"), 3)
        let tables = try database.query("SELECT name FROM sqlite_master WHERE type = 'table'")
            .compactMap { $0.string("name") }
        XCTAssertFalse(tables.contains("session_usage"))
        XCTAssertTrue(tables.contains("usage_events"))
    }
```

同时**删除** Task 3 加的 `testMigrationFromV1AddsNewTablesAndKeepsLegacyOnes`：它断言旧表保留，那是 v2 的过渡态，v3 之后不再成立。

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter TokenMeterDatabaseMigratorTests`
Expected: FAIL，`XCTAssertEqual failed: ("2") is not equal to ("3")`

- [ ] **Step 3: 实现**

`TokenMeterDatabaseSchema.swift`：`currentVersion` 改为 `3`，新增

```swift
    /// v3：删除 v1 的用量表与 agent_sessions 上已下沉的列。
    /// 此时 writer 只写 usage_events，scanner 只调 writer，Electron 只查 rollup 表。
    public static let v3Cleanup = """
    DROP TABLE IF EXISTS provider_daily_usage;
    DROP TABLE IF EXISTS session_usage_latest;
    DROP TABLE IF EXISTS session_usage;

    -- DROP COLUMN 不能删除被索引引用的列，先摘掉索引
    DROP INDEX IF EXISTS idx_sessions_source_file;

    ALTER TABLE agent_sessions DROP COLUMN source_file_id;
    ALTER TABLE agent_sessions DROP COLUMN model_name;
    ALTER TABLE agent_sessions DROP COLUMN model_provider;
    ALTER TABLE agent_sessions DROP COLUMN message_count;
    ALTER TABLE agent_sessions DROP COLUMN event_count;
    ALTER TABLE agent_sessions DROP COLUMN total_cost_usd_micros;
    ALTER TABLE agent_sessions DROP COLUMN worktree_path;
    ALTER TABLE agent_sessions DROP COLUMN session_closed_at;

    INSERT OR IGNORE INTO schema_migrations(version, name) VALUES (3, 'phase3_drop_v1_usage_tables');
    PRAGMA user_version = 3;
    """
```

`ALTER TABLE ... DROP COLUMN` 需要 SQLite 3.35+。本机链接的是 3.51.0，实测可用。

`TokenMeterDatabaseMigrator.migrate` 追加第三段：

```swift
        if currentVersion < 1 {
            try database.execute(TokenMeterDatabaseSchema.v1)
        }
        if currentVersion < 2 {
            try database.execute(TokenMeterDatabaseSchema.v2Additions)
        }
        try database.execute(TokenMeterDatabaseSchema.v3Cleanup)
```

- [ ] **Step 4: 全套验证**

Run: `swift test`
Expected: 全绿。任何引用 `session_usage` 的残留测试都会在这里暴露——那正是本任务要清掉的。

Run: `cd Electron && npx vitest run`
Expected: 全绿。Task 16 已把查询切到 rollup 表。

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenMeterCore/TokenMeterDatabaseSchema.swift Sources/TokenMeterCore/TokenMeterDatabaseMigrator.swift Tests/TokenMeterCoreTests/TokenMeterDatabaseMigratorTests.swift
git commit -m "refactor: drop v1 usage tables and redundant session columns"
```

---

## 实测记录

（Task 17 完成后填写）

- 首次全量扫描耗时：
- 增量扫描（无变化）耗时：
- `usage_events` 行数：
- ccusage 对账结果：

---

## Self-Review

**Spec 覆盖检查：**

| Spec 章节 | 对应任务 |
|---|---|
| 4.1 明细事实表 | Task 3 |
| 4.2 汇总表 | Task 3、Task 12 |
| 4.3 adapter 接口 | Task 6 |
| 4.3.1 token 语义归一 | Task 8（Codex 减法）、Task 9（omp）、Task 10（OpenCode）、Task 1（`totalTokens` 排除 reasoning） |
| 4.4 去重 | Task 7、Task 11（保留早者需应用层比较） |
| 4.5 时区 | Task 12 |
| 5.1 定价数据 | Task 4 |
| 5.2 模型名解析 | Task 2、Task 5 |
| 5.3 计价时机 | Task 11（写入时算）；「重算成本」按钮见下方缺口 |
| 6.1 增量扫描 | Task 13、Task 14 |
| 6.2 全量重扫 | Task 15 |
| 6.3 自动刷新 | Task 15（`scan.finished` 事件）；轮询与窗口隐藏暂停属 Phase 2 |
| 9.3 对账 | Task 17 |

**发现的缺口，已补：**

- Spec 5.3 提到「重算成本」按钮，但没有对应任务。它的实现是 `UPDATE usage_events SET cost_usd_micros = ?, cost_source = ?` 逐行重算 + `RollupBuilder.rebuildAll()`，不重扫文件。**归入 Phase 2 的设置页**，因为 Phase 1 没有触发它的 UI。
- Spec 6.3 的自动刷新轮询与窗口隐藏暂停需要 renderer 配合，**归入 Phase 2**。Phase 1 只铺好 `scan.finished` 事件通道。

**类型一致性检查：**

- `UsageEvent` 的字段名在 Task 1、6、8、9、10、11 中一致（`cacheWrite5mTokens` 而非 `cacheWrite5m`）。
- `ParsedSession`（Task 1）取代了 `ParsedAgentSession`，Task 6/8/9/10 全部返回前者，Task 11 消费前者。
- `UsageEventParser`（Task 6）是 `AnyObject` 协议，`init(resuming:)` + `consume(_:)` + `finish(_:)`。Task 6/8/9 的三个 parser 都是 `final class` 并实现它；Task 14 的 `streamingParser(for:resuming:)` 构造它们。
- 三个 parser 的测试统一走协议扩展提供的静态 `parse(lines:sourceURL:resuming:)`；生产路径只走 `consume`/`finish`。
- `CostCalculator.cost(for:)` 返回 `(micros: Int64?, source: CostSource)`，Task 5 定义、Task 11 消费，签名一致。
- `UsageEventDeduplicator.deduplicate(_:)` 在 Task 7 定义、Task 11 调用。
- `RollupBuilder.rebuildAll()` 在 Task 12 定义，Task 14、15 调用。
- `UsageEventWriter.lastSourceOffset(sourceFileId:)` 在 Task 11 定义，Task 14 调用。
- `JSONLStreamReader.readLines(from:startingAt:markers:onLine:)`（流式）在 Task 13 定义，Task 14 调用；同名的数组版仅供 Task 13 自身的测试使用。
- `ClaudeCodeUsageEventParser.makeDateFormatters()` 是 `static`，被 Codex 与 omp 两个 parser 复用（Task 6/8/9），避免三份重复定义。

**风险提示：**

- Task 13 的字节预筛用 `Data.range(of:)`，Swift 没有 SIMD 优化的 `memmem`。若它成为 3.28 GB 文件的瓶颈，退路是 `withUnsafeBytes` 手写 Boyer-Moore。先测再优化。
- Task 12 的 `'localtime'` modifier 依赖进程时区（`TZ` 环境变量 / 系统设置）。Swift 与 Electron 都在本机同一时区，一致；但测试必须显式 `setenv("TZ", ...)`，否则在 CI 的 UTC 环境下测不出该 bug。

