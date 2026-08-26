# Grok Build 一等公民接入 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 Grok Build 接进 TokenMeter：扫描 `updates.jsonl` 进用量账本，用本机 `grok login` 登录态拉 SuperGrok 周/月额度，设置里可开关。

**Architecture:** 不新开子系统。本地走现有 JSONL scanner + 新 `GrokUsageEventParser`；额度走新 `GrokUsageProvider` spawn `grok agent --no-leader stdio` 调 `x.ai/billing`，JSON 解析与 spawn 分开。身份三分：`LocalAgentKind.grok` / `SourceKind.grokJSONL` (`grok_jsonl`) / `provider_id` `"grok"`。

**Tech Stack:** Swift（TokenMeterCore / TokenMeterApp）、XCTest、Electron/React 设置与图表名单、`scripts/pricing-overrides.json`。

**上游 spec:** `docs/superpowers/specs/2026-08-26-grok-build-design.md`

**第一版不做:** hooks、unified.jsonl、`costUsdTicks`、xAI API credits、gRPC-Web、把月窗升级成环。

---

## 涉及文件

新建：

- `Sources/TokenMeterCore/GrokUsageEventParser.swift` — 解析 `updates.jsonl`
- `Sources/TokenMeterCore/GrokBillingParser.swift` — billing JSON → `ProviderUsageSnapshot`
- `Sources/TokenMeterCore/GrokUsageProvider.swift` — 找二进制、查 auth 文件、spawn CLI
- `Tests/TokenMeterCoreTests/GrokUsageEventParserTests.swift`
- `Tests/TokenMeterCoreTests/GrokBillingParserTests.swift`
- `Tests/TokenMeterCoreTests/GrokUsageProviderTests.swift`

修改（身份 / 扫描）：

- `Sources/TokenMeterCore/LocalAgentModels.swift` — `LocalAgentKind.grok`、`SourceKind.grokJSONL`
- `Sources/TokenMeterCore/UsageEventModels.swift` — `ParserState.grokSawUsage`
- `Sources/TokenMeterCore/TokenMeterPaths.swift` — `GrokPaths` + defaultScanRoots
- `Sources/TokenMeterCore/TokenMeterDatabaseSchema.swift` — `scan_roots.kind` CHECK 加 `grok_jsonl`
- `Sources/TokenMeterCore/TokenMeterDatabaseMigrator.swift` — CHECK 重建条件改为含 `grok_jsonl`；默认 agent 追加 `grok`
- `Sources/TokenMeterCore/UsageEventWriter.swift` — `providerId` 映射
- `Sources/TokenMeterCore/LocalAgentScanner.swift` — `grokJSONL` 分支、`makeParser`、`markers`、`corpusTotals`
- `Sources/TokenMeterApp/ProviderStore.swift` — `allCasesForLocalIndex`、`LocalAgentKind.sourceKind`

修改（额度 / 设置 / UI）：

- `Sources/TokenMeterCore/ProviderConfig.swift` — `ProviderType.grok`
- `Sources/TokenMeterCore/ProviderConfigLoader.swift` — defaultConfig 加 grok
- `Sources/TokenMeterCore/Providers.swift` — `ProviderRegistry` case `.grok`
- `Sources/TokenMeterCore/SettingsStore.swift` — 新装默认 enabledAgentKinds 含 grok
- `Sources/TokenMeterCore/AgentBinaryDetector.swift` — 探测 grok，搜索 `~/.grok/bin`
- `Sources/TokenMeterCore/LiveSessionStore.swift` — allowedAgentKinds 加 grok
- `Sources/TokenMeterApp/PopoverView.swift` — seriesColor、MenuBarProviderName
- `Electron/src/main/settingsRepository.ts` — `LOCAL_AGENT_KIND_ALLOWED`
- `Electron/src/main/ipc.ts` — `AGENT_TO_SOURCE_KIND`
- `Electron/src/main/overviewRepository.ts` — live CASE 加 grok（**不加 dsh**）
- `Electron/src/renderer/routes/Settings.tsx` — AGENT_KINDS + QUOTA_PROVIDERS
- `Electron/src/renderer/routes/Overview.tsx` / `Projects.tsx` / `Models.tsx` / `Sessions.tsx`
- `Electron/src/renderer/charts/AgentTrendChart.tsx`
- `Electron/src/renderer/styles.css` — `--s6`
- `scripts/pricing-overrides.json` — `grok-4.6` / `grok-4.6-build`
- `README.md` / `README.en.md`

测试同步改现有断言：`SettingsStoreTests`、`ProviderRegistryTests`、`ProviderConfigLoaderTests`、`LocalAgentScannerTests.testSeedsDefaultScanRootsFromHomeDirectory`、`AgentBinaryDetectorTests`、`settingsRepository.test.ts`。

**术语（后续任务必须同名）：**

- kind rawValue：`grok` / `grok_jsonl`
- 账本 id：`grok`
- 显示名：`Grok Build`
- `GrokPaths.sessionsRoot(homeDirectory:environment:)`
- `GrokPaths.updatesFiles(under:) throws -> [URL]`
- `GrokAuth.isUsable(authURL:now:)`
- `GrokBillingParser.parse(data:providerId:displayName:fetchedAt:)`
- 去重键：`grok:{sessionId}:{eventId}:{sourceOffset}`

---

### Task 1: 身份枚举、路径、schema CHECK、writer 映射

**Files:**

- Modify: `Sources/TokenMeterCore/LocalAgentModels.swift`
- Modify: `Sources/TokenMeterCore/UsageEventModels.swift`
- Modify: `Sources/TokenMeterCore/TokenMeterPaths.swift`
- Modify: `Sources/TokenMeterCore/TokenMeterDatabaseSchema.swift`（`scan_roots` CHECK，约第 74 行）
- Modify: `Sources/TokenMeterCore/UsageEventWriter.swift`（`providerId(for:)`）
- Modify: `Sources/TokenMeterApp/ProviderStore.swift`（`allCasesForLocalIndex`、`sourceKind`）
- Test: `Tests/TokenMeterCoreTests/LocalAgentScannerTests.swift`（已有 `testSeedsDefaultScanRootsFromHomeDirectory`）

- [ ] **Step 1: 改失败测试**

在 `testSeedsDefaultScanRootsFromHomeDirectory` 把期望改成含 grok：

```swift
XCTAssertEqual(roots.map(\.kind), [
    .claudeJSONL, .codexJSONL, .codexJSONL, .opencodeSQLite, .ompJSONL, .reasonixStats, .dshJSONL, .grokJSONL
])
XCTAssertEqual(roots.map { $0.rootURL.path }, [
    "/tmp/token-meter-home/.claude/projects",
    "/tmp/token-meter-home/.codex/sessions",
    "/tmp/token-meter-home/.codex/archived_sessions",
    "/tmp/token-meter-home/.local/share/opencode/opencode.db",
    "/tmp/token-meter-home/.omp/agent/sessions",
    "/tmp/token-meter-home/.reasonix/stats",
    "/tmp/token-meter-home/.dsh/sessions",
    "/tmp/token-meter-home/.grok/sessions"
])
XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM scan_roots"), 8)
```

同文件追加：

```swift
func testGrokHomeOverridesDefaultSessionsRoot() {
    let home = URL(fileURLWithPath: "/tmp/token-meter-home", isDirectory: true)
    let roots = TokenMeterPaths.defaultScanRoots(
        homeDirectory: home,
        environment: ["GROK_HOME": "/opt/custom-grok"]
    )
    let grok = roots.first { $0.kind == .grokJSONL }
    XCTAssertEqual(grok?.rootURL.path, "/opt/custom-grok/sessions")
    XCTAssertEqual(grok?.displayName, "Grok Build")
}

func testGrokUpdatesFilesIgnoresSiblingJsonl() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("grok-files-\(UUID().uuidString)", isDirectory: true)
    let session = root.appendingPathComponent("%2Ftmp%2Fproj/sess-1", isDirectory: true)
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    try Data().write(to: session.appendingPathComponent("updates.jsonl"))
    try Data().write(to: session.appendingPathComponent("events.jsonl"))
    try Data().write(to: session.appendingPathComponent("chat_history.jsonl"))
    defer { try? FileManager.default.removeItem(at: root) }

    let files = try GrokPaths.updatesFiles(under: root)
    XCTAssertEqual(files.map(\.lastPathComponent), ["updates.jsonl"])
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter LocalAgentScannerTests/testSeedsDefaultScanRootsFromHomeDirectory`

Expected: FAIL（`SourceKind` 还没有 `grokJSONL`，或路径列表长度仍是 7）。

- [ ] **Step 3: 实现身份与路径**

`LocalAgentModels.swift`：

```swift
public enum LocalAgentKind: String, Codable, Equatable, CaseIterable {
    case claudeCode
    case codex
    case opencode
    case omp
    case reasonix
    case dsh
    case grok
}

public enum SourceKind: String, Codable, Equatable {
    case claudeJSONL = "claude_jsonl"
    case codexJSONL = "codex_jsonl"
    case ompJSONL = "omp_jsonl"
    case opencodeSQLite = "opencode_sqlite"
    case reasonixStats = "reasonix_stats"
    case dshJSONL = "dsh_jsonl"
    case grokJSONL = "grok_jsonl"
}
```

`TokenMeterPaths.defaultScanRoots` 在 DSH 根之后追加：

```swift
DefaultScanRoot(
    kind: .grokJSONL,
    rootURL: GrokPaths.sessionsRoot(homeDirectory: homeDirectory, environment: environment),
    displayName: "Grok Build"
)
```

同文件 `DshPaths` 旁：

```swift
public enum GrokPaths {
    public static func sessionsRoot(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let configured = environment["GROK_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
                .standardizedFileURL
        }
        return homeDirectory.appendingPathComponent(".grok/sessions", isDirectory: true)
    }

    public static func updatesFiles(under root: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return [] }
        var files: [URL] = []
        for case let file as URL in enumerator where file.lastPathComponent == "updates.jsonl" {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                files.append(file)
            }
        }
        return files.sorted { $0.path < $1.path }
    }
}
```

`scan_roots` CHECK（schema **和** 后面 Task 6 的 migrator 重建 SQL 必须同构）改成：

```sql
kind TEXT NOT NULL CHECK (kind IN ('claude_jsonl', 'codex_jsonl', 'omp_jsonl', 'opencode_sqlite', 'reasonix_stats', 'dsh_jsonl', 'grok_jsonl')),
```

`UsageEventWriter.providerId`：

```swift
case .grokJSONL: return "grok"
```

`ParserState` 加 `public var grokSawUsage: Bool?`，`init` 增加 `grokSawUsage: Bool? = nil` 并赋值。Swift 自动 Codable 即可（缺 key 解码为 nil）。

`ProviderStore.swift`：

```swift
static var allCasesForLocalIndex: [SourceKind] {
    [.claudeJSONL, .codexJSONL, .opencodeSQLite, .ompJSONL, .reasonixStats, .dshJSONL, .grokJSONL]
}
```

`LocalAgentKind.sourceKind` 加 `case .grok: .grokJSONL`。

所有 `switch SourceKind` / `LocalAgentKind` 必须补全（编译器会报）。`LocalAgentScanner.makeParser` 本任务可先 `throw LocalAgentParserError.unsupportedFormat`，Task 5 再接 parser。`markers` 把 `.grokJSONL` 放进 `nil` 那一组。`scan()` / `corpusTotals` 的 switch 先让 `.grokJSONL` 走空或与 JSONL 相同的骨架，否则不能编译。

`scan()` 的 switch 本任务写成：

```swift
case .claudeJSONL, .codexJSONL, .ompJSONL, .reasonixStats:
    try scanJSONLRoot(...)
case .dshJSONL:
    try scanDshRoot(...)
case .grokJSONL:
    try scanJSONLRoot(...) // Task 5 会改成只枚举 updates.jsonl；此刻仅让编译通过
case .opencodeSQLite:
    try scanOpenCodeRoot(...)
```

**注意：** 此刻 `scanJSONLRoot` 仍用 `jsonlFiles()`，会误扫 `events.jsonl`。不要在 Task 1 提交后认为扫描已正确——Task 5 必须改掉。若担心中间状态，Task 1 的 `.grokJSONL` 分支写成 `break` / 空实现（0 文件），测试只覆盖 paths。

推荐：Task 1 的 `scan()` 对 `.grokJSONL` **先空实现**（什么都不扫），避免误索引。`corpusTotals` 同样 `case .grokJSONL: break`。

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter LocalAgentScannerTests/testSeedsDefaultScanRootsFromHomeDirectory`

Expected: PASS。再跑 `testGrokHomeOverridesDefaultSessionsRoot` 和 `testGrokUpdatesFilesIgnoresSiblingJsonl`。

- [ ] **Step 5: Commit**

```bash
git add Sources/TokenMeterCore/LocalAgentModels.swift Sources/TokenMeterCore/UsageEventModels.swift Sources/TokenMeterCore/TokenMeterPaths.swift Sources/TokenMeterCore/TokenMeterDatabaseSchema.swift Sources/TokenMeterCore/UsageEventWriter.swift Sources/TokenMeterCore/LocalAgentScanner.swift Sources/TokenMeterApp/ProviderStore.swift Tests/TokenMeterCoreTests/LocalAgentScannerTests.swift
git commit -m "feat: 登记 Grok Build 身份、路径与 scan_roots kind"
```

---

### Task 2: `GrokUsageEventParser` — `turn_completed.usage` 拆桶

**Files:**

- Create: `Sources/TokenMeterCore/GrokUsageEventParser.swift`
- Create: `Tests/TokenMeterCoreTests/GrokUsageEventParserTests.swift`
- Modify: `Sources/TokenMeterCore/LocalAgentScanner.swift` — `makeParser` case `.grokJSONL`

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
@testable import TokenMeterCore

final class GrokUsageEventParserTests: XCTestCase {
    private func line(_ text: String, offset: Int64) -> JSONLLine {
        JSONLLine(text: text, offset: offset, nextOffset: offset + Int64(text.utf8.count) + 1)
    }

    private func parse(
        _ lines: [JSONLLine],
        sourceURL: URL = URL(fileURLWithPath: "/tmp/proj-enc/sess-1/updates.jsonl"),
        resuming: ParserState? = nil
    ) throws -> (session: ParsedSession?, state: ParserState) {
        let parser = GrokUsageEventParser(resuming: resuming)
        for line in lines { parser.consume(line) }
        return try parser.finish(sourceURL: sourceURL)
    }

    func testTurnCompletedSplitsInclusiveBuckets() throws {
        let json = """
        {"timestamp":1787744223,"method":"_x.ai/session/update","params":{"sessionId":"sess-1","update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":1332007,"outputTokens":10990,"totalTokens":1342997,"cachedReadTokens":1196416,"cacheCreationTokens":0,"reasoningTokens":9148,"modelUsage":{"grok-4.6-build":{"inputTokens":1332007}}}},"_meta":{"eventId":"sess-1-1224","agentTimestampMs":1787744223003}}}
        """
        let result = try parse([line(json, offset: 42)])
        let session = try XCTUnwrap(result.session)
        XCTAssertEqual(session.sourceKind, .grokJSONL)
        XCTAssertEqual(session.sessionKey, "sess-1")
        XCTAssertEqual(session.events.count, 1)
        let event = session.events[0]
        XCTAssertEqual(event.inputTokens, 135591)
        XCTAssertEqual(event.cacheReadTokens, 1_196_416)
        XCTAssertEqual(event.cacheWrite5mTokens, 0)
        XCTAssertEqual(event.outputTokens, 10990)
        XCTAssertEqual(event.reasoningTokens, 9148)
        XCTAssertEqual(event.totalTokens, 1_342_997)
        XCTAssertEqual(event.modelName, "grok-4.6-build")
        XCTAssertNil(event.reportedCostUSDMicros)
        XCTAssertEqual(event.dedupeKey, "grok:sess-1:sess-1-1224:42")
        XCTAssertEqual(event.sourceOffset, 42)
        XCTAssertEqual(Int(event.observedAt.timeIntervalSince1970 * 1000), 1_787_744_223_003)
        XCTAssertEqual(result.state.grokSawUsage, true)
        XCTAssertEqual(result.state.requiresFullReplay, nil)
    }

    func testDuplicateEventIdDifferentOffsetAreDistinct() throws {
        func record(_ eventId: String, offset: Int64) -> JSONLLine {
            line(
                """
                {"params":{"sessionId":"sess-1","update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":100,"outputTokens":10,"totalTokens":110,"cachedReadTokens":0,"reasoningTokens":0}},"_meta":{"eventId":"\(eventId)","agentTimestampMs":1700000000000}}}
                """,
                offset: offset
            )
        }
        let session = try XCTUnwrap(try parse([record("same", offset: 10), record("same", offset: 99)]).session)
        XCTAssertEqual(session.events.map(\.dedupeKey), [
            "grok:sess-1:same:10",
            "grok:sess-1:same:99"
        ])
    }

    func testZeroUsageProducesNoEvent() throws {
        let json = #"{"params":{"sessionId":"sess-1","update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":0,"outputTokens":0,"totalTokens":0}}}}"#
        let result = try parse([line(json, offset: 0)])
        XCTAssertNil(result.session)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter GrokUsageEventParserTests`

Expected: FAIL（`GrokUsageEventParser` 不存在）。

- [ ] **Step 3: 实现 parser（usage 路径）**

`GrokUsageEventParser.swift` 完整实现（本任务先让上面三个测试过；fallback 在 Task 3）：

- `consume`：JSON 失败则 return。
- 从 `params.sessionId` 取 sessionKey。
- `usage` 路径：`params.update.usage`（字典）。字段用 `JSONDictionary.int64`，键顺序 camelCase 优先再蛇形：`inputTokens`/`input_tokens`，`cachedReadTokens`/`cacheReadTokens`/`cache_read_input_tokens`，`cacheCreationTokens`/`cacheWriteTokens`/`cache_creation_input_tokens`，`outputTokens`/`output_tokens`，`reasoningTokens`/`thoughtTokens`/`thinkingTokens`。
- `inputStored = max(0, rawInput - cacheRead)`；output **不减** reasoning。
- 全 0 则 return（仍可把 `grokSawUsage = true` 如果见到 usage 对象——与 Claude `sawUsageField` 一致：见过 usage 对象就算会话文件。零 token 不 append 事件）。
- 模型：`usage.modelUsage` 若为单 key 对象则用该 key。
- eventId：`params._meta.eventId` 或顶层 `_meta.eventId`，否则 `turn-{eventSeq}`。
- 时间：`agentTimestampMs` 毫秒；否则 `timestamp`，若 `< 1_000_000_000_000` 当秒 ×1000。
- `finish`：`sessionKey` 仍空则用 `sourceURL.deletingLastPathComponent().lastPathComponent`（目录名即 session-id）。没有任何事件且未见 usage → `(nil, state)`。有 sessionKey 则返回 `ParsedSession`（events 可能为空——零 token usage 文件）。
- `ParserState.grokSawUsage = true` 一旦见过 usage 对象。
- `sourceKind: .grokJSONL`，`rawMeta: ["source": "grok"]`。

`makeParser`：`case .grokJSONL: return GrokUsageEventParser(resuming: state)`。

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter GrokUsageEventParserTests`

Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/TokenMeterCore/GrokUsageEventParser.swift Sources/TokenMeterCore/LocalAgentScanner.swift Tests/TokenMeterCoreTests/GrokUsageEventParserTests.swift
git commit -m "feat: 解析 Grok turn_completed.usage 并按 UsageEvent 合同拆桶"
```

---

### Task 3: 无 usage 时 totalTokens 兜底 + 升级重放

**Files:**

- Modify: `Sources/TokenMeterCore/GrokUsageEventParser.swift`
- Modify: `Tests/TokenMeterCoreTests/GrokUsageEventParserTests.swift`

- [ ] **Step 1: 写失败测试**（追加到 `GrokUsageEventParserTests`）

```swift
func testTotalTokensDeltasBecomeInputWhenNoUsage() throws {
    let lines = [
        line(#"{"params":{"update":{"sessionUpdate":"user_message_chunk"}},"_meta":{"totalTokens":1000,"agentTimestampMs":1700000001000}}"#, offset: 0),
        line(#"{"params":{"update":{"sessionUpdate":"agent_message_chunk"}},"_meta":{"totalTokens":1500,"agentTimestampMs":1700000002000}}"#, offset: 50),
        line(#"{"params":{"update":{"sessionUpdate":"agent_message_chunk"}},"_meta":{"totalTokens":1400,"agentTimestampMs":1700000002500}}"#, offset: 80),
        line(#"{"params":{"update":{"sessionUpdate":"user_message_chunk"}},"_meta":{"totalTokens":1500,"agentTimestampMs":1700000003000}}"#, offset: 100),
        line(#"{"params":{"update":{"sessionUpdate":"agent_thought_chunk"}},"_meta":{"totalTokens":1800,"agentTimestampMs":1700000004000}}"#, offset: 120)
    ]
    let session = try XCTUnwrap(try parse(lines).session)
    XCTAssertEqual(session.events.map(\.inputTokens), [500, 300])
    XCTAssertTrue(session.events.allSatisfy { $0.outputTokens == 0 && $0.cacheReadTokens == 0 })
    XCTAssertEqual(try parse(lines).state.grokSawUsage, false)
}

func testUsageDiscardsFallbackAndRequestsReplayIfFallbackAlreadyEmitted() throws {
    let fallback = line(#"{"params":{"sessionId":"sess-1","update":{"sessionUpdate":"agent_message_chunk"}},"_meta":{"totalTokens":2000,"agentTimestampMs":1700000001000}}"#, offset: 0)
    let first = try parse([fallback])
    XCTAssertEqual(first.session?.events.count, 1)
    XCTAssertEqual(first.state.grokSawUsage, false)

    let usage = line(
        #"{"params":{"sessionId":"sess-1","update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":100,"outputTokens":10,"totalTokens":110,"cachedReadTokens":0,"reasoningTokens":0}},"_meta":{"eventId":"e1","agentTimestampMs":1700000005000}}}"#,
        offset: 40
    )
    let second = try parse([fallback, usage], resuming: first.state)
    XCTAssertEqual(second.state.requiresFullReplay, true)
    XCTAssertEqual(second.state.grokSawUsage, true)
    let events = try XCTUnwrap(second.session?.events)
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events[0].inputTokens, 100)
    XCTAssertEqual(events[0].outputTokens, 10)
}
```

兜底计数（与 spec 一致）：

- `user_message_chunk` 开启新 turn，基线 = 当前已见 `lastTotal`（没有则为 0）
- 新 `totalTokens` > last：若已有 active turn，把 max 更新为该值；turn 结束（下一条 user_message 或 finish）时 emit `max - baseline`（>0 才 emit）
- 新值 < last：忽略（流式回退）
- 第一段：测试数据里第一条 user_message 时 lastTotal 尚无，基线 0，随后 1500 被 1400 忽略，turn1 delta = 1500-1000？ 

**按测试数据钉死算法，避免实现时和测试打架：**

实现采用 Tokscale `ActiveTurn`：

1. 见到 `totalTokens`（`_meta.totalTokens` 或 `params._meta.totalTokens`）且 ≥0。
2. `user_message_chunk`：把当前 active turn `into_message`（delta = maxTotal - baseline，>0 才 append 兜底事件），然后 `ActiveTurn(baseline: lastTotal ?? 0, ...)`。
3. 单调：`totalTokens < lastTotal` continue；`>` 则 `observe` 并更新 `lastTotal`。
4. `finish`：若 `grokSawUsage != true` 且本轮也未见 usage，把剩余 active turn flush 进 events；否则 **丢弃全部兜底事件**，只留 usage 事件。
5. 若 `resuming.grokSawUsage != true` 且 `resuming` 已有 `lastEventSeq > 0`（已经 emit 过兜底）且本轮见到 usage：`requiresFullReplay = true`。

把测试 1 的期望改成与该算法一致，写测试前先在注释里列出逐步 lastTotal：

- line0 user_message total=1000：开 turn baseline=0（last 仍 nil，用 0），observe 1000，last=1000。finish 前还有后续。
- line1 total=1500：observe max=1500
- line2 total=1400：忽略
- line3 user_message total=1500：flush turn1 delta=1500-0=1500；新 turn baseline=1500
- line4 total=1800：observe 1800；finish flush delta=300

这样 `events.map(\.inputTokens) == [1500, 300]`。**用这个期望，不要用 [500, 300]。** Step 1 代码里改成：

```swift
XCTAssertEqual(session.events.map(\.inputTokens), [1500, 300])
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter GrokUsageEventParserTests/testTotalTokensDeltasBecomeInputWhenNoUsage`

Expected: FAIL（当前 parser 忽略 totalTokens，session 为 nil 或 events 为空）。

- [ ] **Step 3: 实现兜底与 replay 标志**

在 parser 内加 `struct ActiveTurn { var baseline, maxTotal: Int64; var timestamp: Date; var turnIndex: Int }`。`lastTotal` 续读时从 `state.lastCumulative?.inputTokens` 恢复。`finish` 写回 `lastCumulative = CumulativeTokenTotals(inputTokens: lastTotal ?? 0, ...)`。未见 usage 时才把 fallback events 放进 `ParsedSession.events`。

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter GrokUsageEventParserTests`

Expected: PASS（含 Task 2 的拆桶测试）。

- [ ] **Step 5: Commit**

```bash
git add Sources/TokenMeterCore/GrokUsageEventParser.swift Tests/TokenMeterCoreTests/GrokUsageEventParserTests.swift
git commit -m "feat: Grok 旧日志用 totalTokens 增量兜底，出现 usage 则整文件重放"
```

---

### Task 4: `summary.json` 边车（cwd / parent / 模型名）

**Files:**

- Modify: `Sources/TokenMeterCore/GrokUsageEventParser.swift`
- Modify: `Tests/TokenMeterCoreTests/GrokUsageEventParserTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
func testFinishReadsSummarySidecar() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("grok-sum-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let summary = """
    {"info":{"id":"child-1","cwd":"/Users/me/code/app"},"parent_session_id":"root-9","current_model_id":"grok-4.6","agent_name":"explore"}
    """
    try Data(summary.utf8).write(to: dir.appendingPathComponent("summary.json"))
    let updates = dir.appendingPathComponent("updates.jsonl")
    let json = #"{"params":{"sessionId":"child-1","update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":10,"outputTokens":2,"totalTokens":12,"cachedReadTokens":0}}},"_meta":{"agentTimestampMs":1700000000000}}"#
    let session = try XCTUnwrap(try parse([line(json, offset: 0)], sourceURL: updates).session)
    XCTAssertEqual(session.projectPath, "/Users/me/code/app")
    XCTAssertEqual(session.rootSessionKey, "root-9")
    XCTAssertEqual(session.subagentLabel, "explore")
    XCTAssertEqual(session.events[0].modelName, "grok-4.6")
}

func testFinishDecodesWorkspaceDirectoryWhenSummaryMissing() throws {
    let url = URL(fileURLWithPath: "/tmp/sessions/%2FUsers%2Fme%2Fproj/abc-uuid/updates.jsonl")
    let json = #"{"params":{"sessionId":"abc-uuid","update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":10,"outputTokens":1,"totalTokens":11}}},"_meta":{"agentTimestampMs":1700000000000}}"#
    let session = try XCTUnwrap(try parse([line(json, offset: 0)], sourceURL: url).session)
    XCTAssertEqual(session.sessionKey, "abc-uuid")
    XCTAssertEqual(session.projectPath, "/Users/me/proj")
    XCTAssertNil(session.rootSessionKey)
}
```

模型名规则：usage 里 `modelUsage` 单 key 优先于 summary 的 `current_model_id`。本测试 usage 无 modelUsage，故用 summary。

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter GrokUsageEventParserTests/testFinishReadsSummarySidecar`

Expected: FAIL（projectPath/rootSessionKey 仍为 nil）。

- [ ] **Step 3: 实现**

`finish(sourceURL:)`：

1. sessionKey 仍空则 `sourceURL.deletingLastPathComponent().lastPathComponent`
2. 读 `sourceURL.deletingLastPathComponent().appendingPathComponent("summary.json")`，失败忽略
3. JSON 对象：`info.cwd` 或 `cwd` → projectPath；`parent_session_id` → rootSessionKey；`agent_name` → subagentLabel；`current_model_id` 填到尚未有 modelName 的事件（只填 nil 的）
4. projectPath 仍空：对 `sourceURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent` 做 `removingPercentEncoding`

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter GrokUsageEventParserTests`

Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/TokenMeterCore/GrokUsageEventParser.swift Tests/TokenMeterCoreTests/GrokUsageEventParserTests.swift
git commit -m "feat: Grok 会话从 summary.json 读取 cwd、父会话与模型"
```

---

### Task 5: scanner 只扫 `updates.jsonl`

**Files:**

- Modify: `Sources/TokenMeterCore/LocalAgentScanner.swift`（`scan` / `corpusTotals` / `markers`）

- [ ] **Step 1: 写失败测试**

`LocalAgentScannerTests` 追加（模式照 `DshIntegrationTests`：临时目录 + migrate + INSERT scan_root + scanRoot）：

```swift
func testGrokScanIndexesUpdatesJsonlOnly() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("grok-scan-\(UUID().uuidString)", isDirectory: true)
    let session = root.appendingPathComponent("%2Ftmp%2Fapp/sess-a", isDirectory: true)
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let usage = #"{"params":{"sessionId":"sess-a","update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":50,"outputTokens":5,"totalTokens":55,"cachedReadTokens":0}}},"_meta":{"eventId":"e","agentTimestampMs":1700000000000}}"# + "\n"
    try Data(usage.utf8).write(to: session.appendingPathComponent("updates.jsonl"))
    try Data(#"{"type":"noise"}"#.utf8).write(to: session.appendingPathComponent("events.jsonl"))

    let database = try SQLiteDatabase(path: ":memory:")
    try TokenMeterDatabaseMigrator.migrate(database)
    try database.execute(
        "INSERT INTO scan_roots(kind, root_path, display_name, stable_source_key) VALUES (?, ?, ?, ?)",
        [.text(SourceKind.grokJSONL.rawValue), .text(root.path), .text("Grok"), .text("grok_jsonl:\(root.path)")]
    )
    let rootId = try XCTUnwrap(database.query("SELECT id FROM scan_roots").first?.int("id"))
    let scanner = LocalAgentScanner(database: database)
    try await scanner.scanRoot(id: rootId) // LocalAgentScanner.scanRoot 是 async throws

    let files = try database.query("SELECT relative_path FROM source_files")
    XCTAssertEqual(files.compactMap { $0.string("relative_path") }.filter { $0.hasSuffix("events.jsonl") }, [])
    XCTAssertEqual(try scalarInt(database, "SELECT count(*) AS value FROM usage_events"), 1)
    XCTAssertEqual(try database.query("SELECT provider_id FROM agent_sessions")[0].string("provider_id"), "grok")
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter LocalAgentScannerTests/testGrokScanIndexesUpdatesJsonlOnly`

Expected: FAIL（`.grokJSONL` 仍空实现，usage_events = 0）。

- [ ] **Step 3: 实现扫描**

把 `scanJSONLRoot` 的文件枚举改成：

```swift
let files = root.kind == .grokJSONL
    ? try GrokPaths.updatesFiles(under: root.rootURL)
    : try jsonlFiles(under: root.rootURL)
```

`scan()`：

```swift
case .claudeJSONL, .codexJSONL, .ompJSONL, .reasonixStats, .grokJSONL:
    try scanJSONLRoot(...)
```

`corpusTotals` 同样：`.grokJSONL` 用 `GrokPaths.updatesFiles`。`markers(.grokJSONL) = nil`。

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter LocalAgentScannerTests/testGrokScanIndexesUpdatesJsonlOnly`

Expected: PASS。`swift test --filter GrokUsageEventParserTests` 仍 PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/TokenMeterCore/LocalAgentScanner.swift Tests/TokenMeterCoreTests/LocalAgentScannerTests.swift
git commit -m "feat: Grok 扫描根只索引 updates.jsonl"
```

---

### Task 6: migrator —— CHECK 约束与默认启用 grok

**Files:**

- Modify: `Sources/TokenMeterCore/TokenMeterDatabaseMigrator.swift`
- Modify: `Sources/TokenMeterCore/SettingsStore.swift`（默认 enabledAgentKinds 字符串）
- Test: `Tests/TokenMeterCoreTests/TokenMeterDatabaseMigratorTests.swift`
- Test: `Tests/TokenMeterCoreTests/SettingsStoreTests.swift`（两处 `enabledAgentKinds` 期望数组末尾加 `"grok"`）

- [ ] **Step 1: 写失败测试**

`TokenMeterDatabaseMigratorTests` 追加：

```swift
func testEnsureScanRootsKindAcceptsGrokJsonl() throws {
    let database = try memoryDatabase()
    try TokenMeterDatabaseMigrator.migrate(database)
    try database.execute(
        "INSERT INTO scan_roots(kind, root_path, display_name, stable_source_key) VALUES ('grok_jsonl', '/tmp/g', 'Grok Build', 'grok_jsonl:/tmp/g')"
    )
    XCTAssertEqual(try rowCount(database, "scan_roots"), 1)
}

func testEnsureNewAgentDefaultsAppendsGrokToUntouchedSet() throws {
    let database = try memoryDatabase()
    try TokenMeterDatabaseMigrator.migrate(database)
    try database.execute(
        "INSERT OR REPLACE INTO settings(key, value_json, value_type, version, updated_by) VALUES ('filters.enabledAgentKinds', ?, 'json', 1, 'importer')",
        [.text("[\"claudeCode\",\"codex\",\"opencode\",\"omp\",\"reasonix\",\"dsh\"]")]
    )
    try TokenMeterDatabaseMigrator.migrate(database)
    let json = try XCTUnwrap(database.query("SELECT value_json FROM settings WHERE key = 'filters.enabledAgentKinds'").first?.string("value_json"))
    let kinds = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String])
    XCTAssertEqual(Set(kinds), Set(["claudeCode","codex","opencode","omp","reasonix","dsh","grok"]))
}

func testEnsureNewAgentDefaultsDoesNotTouchCustomizedSet() throws {
    let database = try memoryDatabase()
    try TokenMeterDatabaseMigrator.migrate(database)
    try database.execute(
        "INSERT OR REPLACE INTO settings(key, value_json, value_type, version, updated_by) VALUES ('filters.enabledAgentKinds', ?, 'json', 1, 'electron')",
        [.text("[\"codex\"]")]
    )
    try TokenMeterDatabaseMigrator.migrate(database)
    let json = try XCTUnwrap(database.query("SELECT value_json FROM settings WHERE key = 'filters.enabledAgentKinds'").first?.string("value_json"))
    XCTAssertEqual(json, "[\"codex\"]")
}
```

若 `migrate` 不是 public 测试可见，用 `@testable`（已有）。`rowCount` helper 已在该文件。

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter TokenMeterDatabaseMigratorTests/testEnsureScanRootsKindAcceptsGrokJsonl`

Expected: FAIL（CHECK 还没有 `grok_jsonl`——若 Task 1 已改 schema 的 CREATE IF NOT EXISTS，**内存新库会过**，但旧库重建逻辑 `guard !createSQL.contains("dsh_jsonl")` 不会给老库加 grok。此测试用 migrate 后的新库，Task 1 之后可能已经 PASS。那时本任务的失败点是 defaults 测试。）

以 `testEnsureNewAgentDefaultsAppendsGrokToUntouchedSet` 为红灯。

- [ ] **Step 3: 实现**

`ensureScanRootsKind`：

```swift
guard !createSQL.contains("grok_jsonl") else { return }
```

重建 SQL 的 CHECK 与 schema 完全一致（含 `grok_jsonl`）。

`ensureNewAgentDefaults` 在 dsh 段落后：

```swift
let legacyWithDsh = Set(["claudeCode", "codex", "opencode", "omp", "reasonix", "dsh"])
if let rows = try? database.query("SELECT value_json FROM settings WHERE key = 'filters.enabledAgentKinds'"),
   let json = rows.first?.string("value_json"),
   let data = json.data(using: .utf8),
   var kinds = try? JSONSerialization.jsonObject(with: data) as? [String],
   Set(kinds) == legacyWithDsh {
    kinds.append("grok")
    if let updated = String(data: try JSONSerialization.data(withJSONObject: kinds), encoding: .utf8) {
        try? database.execute(
            "UPDATE settings SET value_json = ?, updated_at = CURRENT_TIMESTAMP WHERE key = 'filters.enabledAgentKinds'",
            [.text(updated)]
        )
    }
}
```

`SettingsStore` 导入默认：

```swift
try setJSON("filters.enabledAgentKinds", json: jsonString(["claudeCode", "codex", "opencode", "omp", "reasonix", "dsh", "grok"]), version: 1, updatedBy: .importer)
```

更新 `SettingsStoreTests` 两处数组期望，末尾加 `"grok"`。

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter TokenMeterDatabaseMigratorTests`

Expected: PASS。`swift test --filter SettingsStoreTests` PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/TokenMeterCore/TokenMeterDatabaseMigrator.swift Sources/TokenMeterCore/SettingsStore.swift Tests/TokenMeterCoreTests/TokenMeterDatabaseMigratorTests.swift Tests/TokenMeterCoreTests/SettingsStoreTests.swift
git commit -m "feat: 迁移 scan_roots 与默认 agent 列表以启用 Grok"
```

---

### Task 7: `GrokBillingParser`

**Files:**

- Create: `Sources/TokenMeterCore/GrokBillingParser.swift`
- Create: `Tests/TokenMeterCoreTests/GrokBillingParserTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
@testable import TokenMeterCore

final class GrokBillingParserTests: XCTestCase {
    func testWeeklyWindowFromPeriodDates() throws {
        let json = """
        {"creditUsagePercent":12.5,"billingCycle":{"billingPeriodStart":"2026-08-01T00:00:00Z","billingPeriodEnd":"2026-08-08T00:00:00Z"}}
        """
        let snapshot = try GrokBillingParser.parse(
            data: Data(json.utf8),
            providerId: "grok",
            displayName: "Grok Build",
            fetchedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.groups.count, 1)
        XCTAssertEqual(snapshot.groups[0].title, "Grok Build")
        let metric = snapshot.groups[0].items[0]
        XCTAssertEqual(metric.label, "7d")
        XCTAssertEqual(metric.windowDurationMinutes, 10_080)
        XCTAssertEqual(metric.usedPercent, 12.5)
        XCTAssertEqual(metric.remainingPercent, 87.5)
        XCTAssertEqual(metric.resetAt, ISO8601DateFormatter().date(from: "2026-08-08T00:00:00Z"))
    }

    func testMonthlyWindowFromThirtyDaySpan() throws {
        let json = """
        {"usedPercent":40,"billingCycle":{"billingPeriodStart":"2026-07-01T00:00:00Z","billingPeriodEnd":"2026-07-31T00:00:00Z"}}
        """
        let metric = try GrokBillingParser.parse(data: Data(json.utf8), providerId: "grok", displayName: "Grok Build").groups[0].items[0]
        XCTAssertEqual(metric.label, "30d")
        XCTAssertEqual(metric.windowDurationMinutes, 43_200)
    }

    func testPercentOnlyDefaultsToWeekly() throws {
        let json = #"{"config":{"creditUsagePercent":{"val":8}}}"#
        let metric = try GrokBillingParser.parse(data: Data(json.utf8), providerId: "grok", displayName: "Grok Build").groups[0].items[0]
        XCTAssertEqual(metric.label, "7d")
        XCTAssertEqual(metric.usedPercent, 8)
    }

    func testUsedOverLimitRatio() throws {
        let json = #"{"monthlyLimit":{"val":10000},"usage":{"totalUsed":{"val":2500}}}"#
        let metric = try GrokBillingParser.parse(data: Data(json.utf8), providerId: "grok", displayName: "Grok Build").groups[0].items[0]
        XCTAssertEqual(metric.usedPercent, 25)
        XCTAssertEqual(metric.label, "7d")
    }

    func testMissingPercentThrows() {
        XCTAssertThrowsError(try GrokBillingParser.parse(data: Data(#"{}"#.utf8), providerId: "grok", displayName: "Grok Build"))
    }

    func testDoesNotDuplicateOnePercentIntoTwoWindows() throws {
        let json = #"{"creditUsagePercent":10,"billingCycle":{"billingPeriodStart":"2026-08-01T00:00:00Z","billingPeriodEnd":"2026-08-08T00:00:00Z"}}"#
        let items = try GrokBillingParser.parse(data: Data(json.utf8), providerId: "grok", displayName: "Grok Build").groups[0].items
        XCTAssertEqual(items.count, 1)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter GrokBillingParserTests`

Expected: FAIL（类型不存在）。

- [ ] **Step 3: 实现**

`GrokBillingParser`：

- `enum ParseError: LocalizedError { case missingUsageFields }` 文案「Grok 响应中没有可用的额度字段」
- 递归取数：`number(in:path:)` 支持中间缺省、`{val:}` / `{value:}` 包装、字符串数字
- 百分比顺序：`creditUsagePercent`、`usedPercent`、`usagePercent`（根或 `config.`）；再 `totalUsed/monthlyLimit`（`usage.totalUsed`、`config.monthlyLimit`）
- clamp 0...100，非有限则当缺失
- 日期：`billingCycle.billingPeriodStart/End`、`currentPeriod.start/end`、`billingPeriodStart/End`（ISO8601，含/不含分数秒）
- 跨度天：`end-start` 的 `num_days`；6...8 → 周；27...33 → 月；否则周
- **一条** metric：id `"grok-7d"` 或 `"grok-30d"`，kind `.quota`，status `.ok`
- 只有再发现第二套**不同** billingCycle 对象时才加第二条（第一版测试不覆盖第二条；实现可先永远只产一条，满足「禁止复制同一百分比」）
- `resetText`：复制 `Providers.swift` 的 `countdownText(until:)`（`1d2h` / `3h4m` / `5m`）
- 组 id `"grok"`，title = displayName
- summary：`"\(label) \(UsageFormatter.numberText(remainingPercent))%"`

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter GrokBillingParserTests`

Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/TokenMeterCore/GrokBillingParser.swift Tests/TokenMeterCoreTests/GrokBillingParserTests.swift
git commit -m "feat: 解析 SuperGrok billing JSON 为 7d/30d 额度窗口"
```

---

### Task 8: `GrokUsageProvider` 错误路径（不联网）

**Files:**

- Create: `Sources/TokenMeterCore/GrokUsageProvider.swift`
- Create: `Tests/TokenMeterCoreTests/GrokUsageProviderTests.swift`
- Modify: `Sources/TokenMeterCore/ProviderConfig.swift` — `enum ProviderType` 加 `case grok`
- Modify: `Sources/TokenMeterCore/ProviderConfigLoader.swift` — defaultConfig 追加 grok
- Modify: `Sources/TokenMeterCore/Providers.swift` — Registry `case .grok: return GrokUsageProvider(config:)`
- Modify: `Tests/TokenMeterCoreTests/ProviderRegistryTests.swift`、`ProviderConfigLoaderTests.swift` 期望 id 列表末尾加 `"grok"`

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
@testable import TokenMeterCore

final class GrokUsageProviderTests: XCTestCase {
    private func config() -> ProviderConfig {
        ProviderConfig(
            id: "grok",
            type: .grok,
            displayName: "Grok Build",
            enabled: true,
            credential: nil,
            endpoint: nil,
            manualUsage: nil
        )
    }

    func testMissingBinaryMessage() async {
        let provider = GrokUsageProvider(
            config: config(),
            grokHome: URL(fileURLWithPath: "/tmp/missing-grok-home"),
            grokExecutable: { nil }
        )
        let snapshot = await provider.fetchProviderUsage()
        XCTAssertEqual(snapshot.status, .error)
        XCTAssertTrue(snapshot.message?.contains("未检测到 Grok 命令行") == true)
    }

    func testMissingAuthMessageDoesNotContainToken() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("grok-auth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let provider = GrokUsageProvider(
            config: config(),
            grokHome: home,
            grokExecutable: { "/usr/bin/true" }
        )
        let snapshot = await provider.fetchProviderUsage()
        XCTAssertTrue(snapshot.message?.contains("未登录 Grok Build") == true)
        XCTAssertFalse(snapshot.message?.contains("eyJ") == true)
        XCTAssertFalse(snapshot.message?.contains("Bearer") == true)
    }

    func testExpiredAuthIsLoggedOut() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("grok-auth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let json = """
        {"https://auth.x.ai::abc":{"key":"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.aaa","expires_at":"2020-01-01T00:00:00Z"}}
        """
        try Data(json.utf8).write(to: home.appendingPathComponent("auth.json"))
        let provider = GrokUsageProvider(
            config: config(),
            grokHome: home,
            grokExecutable: { "/usr/bin/true" },
            now: { ISO8601DateFormatter().date(from: "2026-08-26T00:00:00Z")! }
        )
        let snapshot = await provider.fetchProviderUsage()
        XCTAssertTrue(snapshot.message?.contains("未登录") == true)
        XCTAssertFalse(snapshot.message?.contains("eyJ") == true)
    }

    func testUsableAuthParsesBillingViaInjectedFetch() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("grok-auth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let json = """
        {"https://auth.x.ai::abc":{"key":"secret","expires_at":"2099-01-01T00:00:00Z"}}
        """
        try Data(json.utf8).write(to: home.appendingPathComponent("auth.json"))
        let provider = GrokUsageProvider(
            config: config(),
            grokHome: home,
            grokExecutable: { "/usr/bin/true" },
            fetchBilling: { Data(#"{"creditUsagePercent":3}"#.utf8) }
        )
        let snapshot = await provider.fetchProviderUsage()
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.groups[0].items[0].usedPercent, 3)
        XCTAssertEqual(snapshot.groups[0].items[0].label, "7d")
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter GrokUsageProviderTests`

Expected: FAIL（`ProviderType.grok` / `GrokUsageProvider` 不存在）。

- [ ] **Step 3: 实现**

`GrokAuth`（可放在同文件）：

```swift
enum GrokAuth {
    static func isUsable(authURL: URL, now: Date) -> Bool {
        guard let data = try? Data(contentsOf: authURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !object.isEmpty else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        var sawEntry = false
        for value in object.values {
            guard let entry = value as? [String: Any] else { continue }
            sawEntry = true
            guard let raw = entry["expires_at"] as? String else { return true }
            let expiry = formatter.date(from: raw) ?? plain.date(from: raw)
            if let expiry, expiry > now { return true }
            if expiry == nil { return true }
        }
        return false
    }
}
```

无任何未过期条目 → false。缺 `expires_at` 的条目视为仍可用。

`GrokUsageProvider`：

```swift
public struct GrokUsageProvider: UsageProvider {
    public let id: String
    public let displayName: String
    private let grokHome: URL
    private let grokExecutable: () -> String?
    private let now: () -> Date
    private let fetchBilling: () async throws -> Data

    public init(config: ProviderConfig) {
        self.init(
            config: config,
            grokHome: GrokPaths.sessionsRoot().deletingLastPathComponent(),
            grokExecutable: { GrokUsageProvider.locateGrokExecutable() }
        )
    }

    init(
        config: ProviderConfig,
        grokHome: URL,
        grokExecutable: @escaping () -> String?,
        now: @escaping () -> Date = Date.init,
        fetchBilling: (() async throws -> Data)? = nil
    ) {
        self.id = config.id
        self.displayName = config.displayName
        self.grokHome = grokHome
        self.grokExecutable = grokExecutable
        self.now = now
        let home = grokHome
        let exec = grokExecutable
        self.fetchBilling = fetchBilling ?? {
            try GrokUsageProvider.spawnBilling(executable: exec(), grokHome: home)
        }
    }
    ...
}
```

`locateGrokExecutable`：在 `CodexUsageProvider.searchDirectories` 的列表前插入 `grokHome/bin`（即 `~/.grok/bin`）和 `$GROK_HOME/bin`。找名为 `grok` 的可执行文件。

`spawnBilling`：`Process` 绝对路径，`arguments: ["agent", "--no-leader", "stdio"]`，stdin 写两行 JSON-RPC（initialize id=1，billing id=2），读 stdout 直到 `id == 2`，timeout 10s 则 terminate 并 `throw ProcessError.timedOut`。stderr 接 Pipe 丢弃。有 `error` key 则 throw `error.message` 字符串。`result` 再 `JSONSerialization.data`。

`fetchProviderUsage`：无二进制 / 未登录 / catch 全部 `providerErrorSnapshot`。ParseError 用 `error.localizedDescription`。消息里若含 `weekly limit` / `credits` / `402` 则改成「额度用尽」。**不要**把 auth.json 的 key 拼进任何字符串。

`grokHome` 生产路径：`FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")`，若 `GROK_HOME` 有值则用它（与 `GrokPaths.sessionsRoot` 的父目录一致）。不要用 sessions 目录当 grokHome。

修正生产 `init(config:)`：

```swift
let home = GrokPaths.sessionsRoot().deletingLastPathComponent()
```

`GrokPaths.sessionsRoot()` 无参时用 `FileManager` + `ProcessInfo.environment`，父目录即 GROK_HOME/`~/.grok`。正确。

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter GrokUsageProviderTests`

Expected: PASS。`swift test --filter ProviderRegistryTests` 与 `ProviderConfigLoaderTests` PASS（已更新期望）。

- [ ] **Step 5: Commit**

```bash
git add Sources/TokenMeterCore/GrokUsageProvider.swift Sources/TokenMeterCore/ProviderConfig.swift Sources/TokenMeterCore/ProviderConfigLoader.swift Sources/TokenMeterCore/Providers.swift Tests/TokenMeterCoreTests/GrokUsageProviderTests.swift Tests/TokenMeterCoreTests/ProviderRegistryTests.swift Tests/TokenMeterCoreTests/ProviderConfigLoaderTests.swift
git commit -m "feat: SuperGrok 额度供应商（CLI billing + 登录态检查）"
```

---

### Task 9: 设置页、二进制探测、Electron 白名单

**Files:**

- Modify: `Sources/TokenMeterCore/AgentBinaryDetector.swift`
- Modify: `Sources/TokenMeterCore/LiveSessionStore.swift`
- Modify: `Electron/src/main/settingsRepository.ts`
- Modify: `Electron/src/renderer/routes/Settings.tsx`
- Modify: `Electron/src/main/ipc.ts`
- Modify: `Electron/src/main/overviewRepository.ts`
- Test: `Tests/TokenMeterCoreTests/AgentBinaryDetectorTests.swift`
- Test: `Electron/src/main/settingsRepository.test.ts`

- [ ] **Step 1: 写失败测试**

`AgentBinaryDetectorTests.testDetectReportsFoundPathAndFirstVersionLine` 的 kinds 期望改为：

```swift
XCTAssertEqual(statuses.map(\.kind), ["claudeCode", "codex", "omp", "opencode", "dsh", "grok"])
```

并 `installFakeBinary("grok", versionOutput: "grok 1.0.5")`，断言 `byKind["grok"]?.found == true`。

`searchDirectories` 单测若没有，追加：

```swift
func testSearchDirectoriesIncludeGrokBin() {
    let dirs = AgentBinaryDetector.searchDirectories(homeDirectory: "/Users/me")
    XCTAssertTrue(dirs.contains("/Users/me/.grok/bin"))
}
```

`settingsRepository.test.ts` 现有 `accepts reasonix` 旁：

```ts
it('accepts grok in enabledAgentKinds', () => {
  repo.update({ enabledAgentKinds: ['claudeCode', 'codex', 'opencode', 'omp', 'reasonix', 'dsh', 'grok'] }, 3);
  expect(repo.get().enabledAgentKinds).toEqual(['claudeCode', 'codex', 'opencode', 'omp', 'reasonix', 'dsh', 'grok']);
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter AgentBinaryDetectorTests/testDetectReportsFoundPathAndFirstVersionLine`

Expected: FAIL（kinds 数组无 grok）。

Run: `npm test --prefix Electron -- src/main/settingsRepository.test.ts`

Expected: FAIL（unsupported grok）直到改 `LOCAL_AGENT_KIND_ALLOWED`。

- [ ] **Step 3: 实现**

`AgentBinaryDetector.binaries` 追加 `("grok", "grok")`。`searchDirectories` 在 `.local/bin` 旁加 `"\(homeDirectory)/.grok/bin"`。

`LiveSessionStore.allowedAgentKinds` 加 `"grok"`。

`LOCAL_AGENT_KIND_ALLOWED.grok = true`。

`Settings.tsx`：

```ts
{ id: 'grok', label: 'Grok Build', how: '自动统计 ~/.grok 会话流水' }
```

```ts
{ id: 'grok', name: 'Grok Build', pill: '自动接入', how: '自动读取本机登录凭证', src: '~/.grok/auth.json' }
```

`ipc.ts` `AGENT_TO_SOURCE_KIND.grok = 'grok_jsonl'`。

`overviewRepository.ts` 三处 `CASE ls.agent_kind` 增加 `WHEN 'grok' THEN 'grok_jsonl'`。不要加 dsh。

**不要**改 `AgentHooksInstaller`。

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter AgentBinaryDetectorTests`

Expected: PASS。

Run: `npm test --prefix Electron -- src/main/settingsRepository.test.ts`

Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/TokenMeterCore/AgentBinaryDetector.swift Sources/TokenMeterCore/LiveSessionStore.swift Electron/src/main/settingsRepository.ts Electron/src/main/settingsRepository.test.ts Electron/src/renderer/routes/Settings.tsx Electron/src/main/ipc.ts Electron/src/main/overviewRepository.ts Tests/TokenMeterCoreTests/AgentBinaryDetectorTests.swift
git commit -m "feat: 设置与探测名单加入 Grok Build"
```

---

### Task 10: 图表显示名、系列色、菜单栏

**Files:**

- Modify: `Sources/TokenMeterApp/PopoverView.swift`（`seriesColor`、`MenuBarProviderName`）
- Modify: `Electron/src/renderer/styles.css`（亮色 `--s5` 旁加 `--s6: #111111`；暗色块 `--s6: #e6e6e6`）
- Modify: `Electron/src/renderer/charts/AgentTrendChart.tsx`
- Modify: `Electron/src/renderer/routes/Overview.tsx`、`Projects.tsx`、`Models.tsx`、`Sessions.tsx`

- [ ] **Step 1: 写失败测试**

`QuotaDisplayModelTests` 或 `MenuBarQuotaModelTests` 若没有颜色测试，在 `TokenMeterAppTests` 追加最小测试不现实（Color 比较）。改为 Swift 字符串：

若没有现成测试钩子，本任务用 `MenuBarProviderName.label`——它是 enum 静态方法，可在 `QuotaDisplayModelTests` 或新建极小测试：

`Tests/TokenMeterAppTests/MenuBarProviderNameTests.swift`：

```swift
func testGrokLabel() {
    XCTAssertEqual(MenuBarProviderName.label("grok"), "Grok Build")
}
```

Electron 渲染层没有单独的 provider 名单单测。本任务以 `swift test --filter MenuBarProviderNameTests` 与 `npm test --prefix Electron` 全绿为通过标准。

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter MenuBarProviderNameTests`

Expected: FAIL（label 回落为 `"grok"`）。

- [ ] **Step 3: 实现**

`seriesColor`：

```swift
case "grok": return self == .light ? Color(hex: 0x111111) : Color(hex: 0xE6E6E6)
```

`MenuBarProviderName`：`case "grok": return "Grok Build"`

CSS 两套主题都加 `--s6`。

`KNOWN_PROVIDERS` / `TREND_PROVIDERS` / `PROVIDER_LABEL` / `AGENT_LABEL` 均加：

```ts
{ id: 'grok', label: 'Grok Build', cssVar: 'var(--s6)' }
```

Sessions：

```ts
{ id: 'grok', label: 'Grok Build', color: 'var(--s6)' }
```

Overview/Projects/Models：`grok: 'Grok Build'`。

不添加 `grok.pdf`（spec：缺图标不挡功能）。

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter MenuBarProviderNameTests`

Expected: PASS。

Run: `npm test --prefix Electron`

Expected: PASS（若有 Settings 开关测试点 grok，按红灯补 mock）。

- [ ] **Step 5: Commit**

```bash
git add Sources/TokenMeterApp/PopoverView.swift Tests/TokenMeterAppTests/MenuBarProviderNameTests.swift Electron/src/renderer/styles.css Electron/src/renderer/charts/AgentTrendChart.tsx Electron/src/renderer/routes/Overview.tsx Electron/src/renderer/routes/Projects.tsx Electron/src/renderer/routes/Models.tsx Electron/src/renderer/routes/Sessions.tsx
git commit -m "feat: Grok Build 图表与菜单栏显示名、系列色"
```

---

### Task 11: 定价覆盖与 README

**Files:**

- Modify: `scripts/pricing-overrides.json`
- Modify: `README.md`、`README.en.md`
- Test: `Tests/TokenMeterCoreTests/CostCalculatorTests.swift`（bundled 快照；必须先跑 `./scripts/update-pricing.sh` 把 override 打进 `litellm-pricing.json`）

定价步骤必须查证 [xAI Pricing](https://docs.x.ai)。查不到官网时使用 2026-08 公开表（须写进 override 的 `note`）：

| 键 | input / cacheRead / output（USD per 1M） |
|---|---|
| `grok-4.6` | 2.00 / 0.50 / 6.00 |
| `grok-4.6-build` | 与上相同 |

cacheWrite 两档 0。

- [ ] **Step 1: 写失败测试**

`Tests/TokenMeterCoreTests/CostCalculatorTests.swift` 已有 `event(model:input:output:...)` 工厂。追加：

```swift
func testGrok46PricingKeysResolve() throws {
    let snapshot = try PricingSnapshot.loadBundled()
    let calculator = CostCalculator(snapshot: snapshot)
    let result = calculator.cost(for: event(model: "grok-4.6-build", input: 1_000_000, output: 1_000_000))
    XCTAssertEqual(result.source, .computed)
    XCTAssertEqual(result.micros, 8_000_000) // $2 input + $6 output
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter CostCalculatorTests/testGrok46PricingKeysResolve`

Expected: FAIL（`cost_source == unknown` 或 micros nil）。

- [ ] **Step 3: 实现**

`pricing-overrides.json` 的 `models` 增加两条（`note` 写查证日期与 URL）。跑：

```bash
./scripts/update-pricing.sh
```

把更新后的 `Sources/TokenMeterCore/Resources/litellm-pricing.json` 一并提交。

README 中文表：

| Grok Build | `$GROK_HOME/sessions/*/*/updates.jsonl`（默认 `~/.grok/sessions`） |

额度表：

| Grok Build | `~/.grok/auth.json`（`grok login`） |

英文 README 对称加两行。Reasonix/DSH 若 README 未列全，**不要**顺手补（与本需求无关）。

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter CostCalculatorTests/testGrok46PricingKeysResolve`

Expected: PASS。

Run: `python3 -m unittest discover -s scripts -p 'test_*.py'`

Expected: PASS。

Run: `swift test`

Expected: PASS（全量 Swift）。

Run: `npm test --prefix Electron`

Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add scripts/pricing-overrides.json Sources/TokenMeterCore/Resources/litellm-pricing.json Tests/TokenMeterCoreTests/CostCalculatorTests.swift README.md README.en.md
git commit -m "feat: Grok 4.6 定价覆盖与 README 数据源"
```

---

## Spec 覆盖对照

| Spec | Task |
|---|---|
| §1.1 身份三分 | 1 |
| §1.2 / §2.1 只扫 updates.jsonl、GROK_HOME | 1, 5 |
| §2.2 usage 拆桶、去重键、模型名、不用 costUsdTicks | 2 |
| §2.3 兜底 + requiresFullReplay | 3 |
| §2.4 ParserState.grokSawUsage / lastCumulative | 3 |
| §2.1 / §2.2 summary.json cwd/parent/agent_name | 4 |
| §2.1 scan_roots CHECK + 种子根 | 1, 6 |
| §4.2 默认启用 + 幂等追加 | 6 |
| §3.2 billing 解析、单百分比不拆两窗 | 7 |
| §3.1 spawn/登录/无二进制、不泄漏 token | 8 |
| §4.1 设置页、探测、不装 hooks | 9 |
| §4.3 live CASE / ipc / Electron 白名单 | 9 |
| §3.4 / §4.3 颜色与显示名 | 10 |
| §2.5 定价 | 11 |
| §4.3 README | 11 |
| 不修 overview dsh CASE | 9 明确不加 |
| 不做 hooks / unified / gRPC / costUsdTicks | 全任务未包含 |

## 实现时注意

- `switch SourceKind` 必须穷尽，改枚举后先编译再写逻辑。
- Task 1 不要让 grok 根去扫全部 jsonl。
- 不要读 `auth.json` 的 `key` 进日志。
- 不要 bump `derivedVersion`（本功能只改 config 表 CHECK + 新扫描根）。
- `npm test --prefix Electron` 与 `swift test` 在 Task 11 收口全绿。
