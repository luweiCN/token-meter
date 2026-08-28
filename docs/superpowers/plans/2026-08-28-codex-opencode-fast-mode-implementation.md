# Codex / OpenCode Fast 模式 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fast 用量单独成行（`{base}-fast`），按 OpenAI API Fast/Priority 短上下文牌价计费；OpenCode 已有的 `-fast` 目录 ID 能对上价，原生 Codex 从 `service_tier` 合成同一身份。

**Architecture:** 不改查价算法。Fast 是一等定价键；`ModelNameNormalizer` 不剥 `-fast`。Codex 解析器额外记住 `serviceTier`，只在写出 `UsageEvent` 时把 `fast`/`priority` 合成到模型名。OpenCode 适配器不动。`derivedVersion` 升到 13 以重扫历史。

**Tech Stack:** Swift（TokenMeterCore）、XCTest、`scripts/pricing-overrides.json` + `scripts/update-pricing.sh`、Python `unittest`。

**上游 spec:** `docs/superpowers/specs/2026-08-28-codex-opencode-fast-mode-design.md`

**本轮不做:** Claude Code Fast、ChatGPT credits 倍率、未知 `*-fast` 自动乘系数、更新 Standard Sol 牌价、Fast 专用 UI。

---

## 涉及文件

修改：

- `Sources/TokenMeterCore/ModelNameNormalizer.swift` — 注释：为何 `-fast` 不进 effort 表
- `Sources/TokenMeterCore/UsageEventModels.swift` — `ParserState.codexServiceTier`
- `Sources/TokenMeterCore/CodexUsageEventParser.swift` — 读 `service_tier`，写出 `{base}-fast`
- `Sources/TokenMeterCore/TokenMeterDatabaseSchema.swift` — `derivedVersion = 13`
- `scripts/pricing-overrides.json` — Fast 价卡
- `Sources/TokenMeterCore/Resources/litellm-pricing.json` — 只经 `update-pricing.sh` 重生
- `Tests/TokenMeterCoreTests/ModelNameNormalizerTests.swift`
- `Tests/TokenMeterCoreTests/UsageEventModelsTests.swift`
- `Tests/TokenMeterCoreTests/CodexUsageEventParserTests.swift`
- `Tests/TokenMeterCoreTests/CostCalculatorTests.swift`
- `Tests/TokenMeterCoreTests/PricingTests.swift`
- `Tests/TokenMeterCoreTests/OpenCodeUsageEventAdapterTests.swift`
- `scripts/test_transform_pricing.py`

**术语（后续任务必须同名）：**

- 实例字段：`serviceTier: String?`（解析器）
- 状态字段：`ParserState.codexServiceTier: String?`
- 合成函数：`billedModelName(base:)`
- 读档位：`consumeThreadSettings(_:)`
- Fast 判定：`fast` 与 `priority`（小写比较）；`flex` 不是 Fast
- 定价键：`gpt-5.6-sol-fast` 等，见 Task 5 表

测试命令：

```
swift test --filter <TestClass>/<testName>
python3 -m unittest scripts.test_transform_pricing
```

---

### Task 1: 锁住「不剥 `-fast`」

**Files:**

- Modify: `Tests/TokenMeterCoreTests/ModelNameNormalizerTests.swift`
- Modify: `scripts/test_transform_pricing.py`
- Modify: `Sources/TokenMeterCore/ModelNameNormalizer.swift`（只改注释）
- Modify: `scripts/transform_pricing.py`（只改 `EFFORT_SUFFIXES` 旁注释）

这是表征测试：今天 `canonical("gpt-5.6-sol-fast")` 已经等于自身。先加测试锁住，再写注释防止有人把它加进 `effortSuffixes`。测试应当 **PASS**（不是红）。若 FAIL，说明已经有人剥了 `-fast`，先停下来对一下 spec。

- [ ] **Step 1: 加 Swift 表征测试**

在 `ModelNameNormalizerTests` 末尾追加：

```swift
    func testDoesNotStripFastSuffix() {
        // Fast 改单价，不是 effort。剥掉会把 gpt-5.6-sol-fast 并进 sol，
        // 也会把真模型 grok-4-fast 错剥成 grok-4。
        XCTAssertEqual(ModelNameNormalizer.canonical("gpt-5.6-sol-fast"), "gpt-5.6-sol-fast")
        XCTAssertEqual(ModelNameNormalizer.canonical("gpt-5.6-luna-fast"), "gpt-5.6-luna-fast")
        XCTAssertEqual(ModelNameNormalizer.canonical("GPT-5.5-Fast"), "gpt-5.5-fast")
        XCTAssertEqual(ModelNameNormalizer.canonical("codex/gpt-5.6-sol-fast"), "gpt-5.6-sol-fast")
        XCTAssertEqual(ModelNameNormalizer.canonical("grok-4-fast"), "grok-4-fast")
        XCTAssertEqual(ModelNameNormalizer.canonical("gpt-5.5-xhigh"), "gpt-5.5")
    }
```

- [ ] **Step 2: 加 Python 表征测试**

在 `scripts/test_transform_pricing.py` 的 `CanonicalTests.test_matches_swift_normalizer` 里追加：

```python
        self.assertEqual(canonical("gpt-5.6-sol-fast"), "gpt-5.6-sol-fast")  # Fast 不是 effort，不剥
        self.assertEqual(canonical("grok-4-fast"), "grok-4-fast")
```

并在 `CostCalculatorTests.testPricingKeyCanonicalStripsOnlyWhitelistedPrefixes` 追加：

```swift
        XCTAssertEqual(CostCalculator.pricingKeyCanonical("gpt-5.6-sol-fast"), "gpt-5.6-sol-fast")
        XCTAssertEqual(CostCalculator.pricingKeyCanonical("grok-4-fast"), "grok-4-fast")
```

- [ ] **Step 3: 跑测试，确认已经 PASS**

```
swift test --filter ModelNameNormalizerTests/testDoesNotStripFastSuffix
swift test --filter CostCalculatorTests/testPricingKeyCanonicalStripsOnlyWhitelistedPrefixes
python3 -m unittest scripts.test_transform_pricing.CanonicalTests.test_matches_swift_normalizer
```

Expected: 全部 PASS。

- [ ] **Step 4: 补注释**

`ModelNameNormalizer.swift` 的 `effortSuffixes` 注释改为：

```swift
    /// OmniRoute 为不支持切换思考档位的 agent 在网关层建的档位别名（gpt-5.5-xhigh 等）。
    /// 计价上就是基础模型：档位只改推理 token 用量，不改单价。
    /// 只收数据里实际见过的档位后缀。-medium/-low 刻意不收：
    /// mistral-medium、whisper-medium 的 medium 是尺寸不是档位，剥了就错了。
    /// -fast 也不收：Codex/OpenCode 的 Fast 改单价；grok-4-fast 是独立产品。
    private static let effortSuffixes = ["-xhigh", "-high"]
```

`scripts/transform_pricing.py` 的 `EFFORT_SUFFIXES` 注释改为：

```python
# 与 Swift 的 ModelNameNormalizer.effortSuffixes 对齐：OmniRoute 网关层的档位别名，
# 计价按基础模型。-medium/-low 刻意不收（mistral-medium 的 medium 是尺寸不是档位）。
# -fast 也不收：Fast 改单价；grok-4-fast 是独立产品。
EFFORT_SUFFIXES = ("-xhigh", "-high")
```

- [ ] **Step 5: 再跑一遍，然后提交**

```
swift test --filter ModelNameNormalizerTests
python3 -m unittest scripts.test_transform_pricing
```

Expected: PASS。

```bash
git add Sources/TokenMeterCore/ModelNameNormalizer.swift scripts/transform_pricing.py \
  Tests/TokenMeterCoreTests/ModelNameNormalizerTests.swift \
  Tests/TokenMeterCoreTests/CostCalculatorTests.swift \
  scripts/test_transform_pricing.py
git commit -m "test: 锁住模型名不剥 -fast 后缀"
```

---

### Task 2: `ParserState.codexServiceTier`

**Files:**

- Modify: `Sources/TokenMeterCore/UsageEventModels.swift`
- Modify: `Tests/TokenMeterCoreTests/UsageEventModelsTests.swift`

- [ ] **Step 1: 写失败测试（续读字段要进 JSON）**

把 `testParserStateRoundTripsThroughJSON` 改成带上 Fast 档位（旧的无字段用例另留一条，锁住缺 key 解码）：

```swift
    func testParserStateRoundTripsThroughJSON() throws {
        let state = ParserState(
            lastEventSeq: 7,
            lastCumulative: CumulativeTokenTotals(inputTokens: 100, cachedInputTokens: 90, outputTokens: 10, reasoningTokens: 2)
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(ParserState.self, from: data)
        XCTAssertEqual(decoded, state)
    }

    func testParserStateRoundTripsCodexServiceTier() throws {
        let state = ParserState(lastEventSeq: 1, codexServiceTier: "fast")
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(ParserState.self, from: data)
        XCTAssertEqual(decoded.codexServiceTier, "fast")
    }

    func testParserStateMissingCodexServiceTierDecodesAsNil() throws {
        let json = #"{"lastEventSeq":1,"resumeOffset":0}"#
        let decoded = try JSONDecoder().decode(ParserState.self, from: Data(json.utf8))
        XCTAssertNil(decoded.codexServiceTier)
    }
```

- [ ] **Step 2: 跑测试，确认编译失败**

```
swift test --filter UsageEventModelsTests/testParserStateRoundTripsCodexServiceTier
```

Expected: FAIL/compile error：`ParserState` 没有 `codexServiceTier`。

- [ ] **Step 3: 加上字段**

在 `ParserState` 里，`codexIsUserFork` 后面加：

```swift
    public var codexServiceTier: String?
```

`init` 参数列表在 `codexIsUserFork` 后加 `codexServiceTier: String? = nil`，函数体 `self.codexServiceTier = codexServiceTier`。合成 `Codable` 即可：缺 key 解成 nil。

- [ ] **Step 4: 跑测试确认 PASS**

```
swift test --filter UsageEventModelsTests
```

Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add Sources/TokenMeterCore/UsageEventModels.swift Tests/TokenMeterCoreTests/UsageEventModelsTests.swift
git commit -m "feat: ParserState 续读 Codex service_tier"
```

---

### Task 3: Codex 解析器合成 `{base}-fast`

**Files:**

- Modify: `Tests/TokenMeterCoreTests/CodexUsageEventParserTests.swift`
- Modify: `Sources/TokenMeterCore/CodexUsageEventParser.swift`

现有夹具：

```swift
    private let meta = #"{"type":"session_meta","payload":{"id":"s1","timestamp":"2026-07-08T01:00:00Z","cwd":"/repo"}}"#
    private let turnContext = #"{"type":"turn_context","payload":{"model":"gpt-5.5"}}"#
```

token 行沿用 `testSubtractsCachedInputFromInput` 那条 `token_count`（input 1000 / cached 900 / output 50）。新测试只断言 `modelName`。

- [ ] **Step 1: 写失败测试（event_msg 外壳 + fast）**

```swift
    func testFastServiceTierAppendsFastSuffix() throws {
        let settings = #"{"type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"gpt-5.5","service_tier":"fast"}}}"#
        let token = #"{"type":"event_msg","timestamp":"2026-07-08T01:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":900,"output_tokens":50,"reasoning_output_tokens":10,"total_tokens":1050}}}}"#
        let lines = [line(meta, offset: 0), line(turnContext, offset: 1), line(settings, offset: 2), line(token, offset: 3)]
        let (session, state) = try CodexUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/c.jsonl"), resuming: nil
        )
        XCTAssertEqual(session.events[0].modelName, "gpt-5.5-fast")
        XCTAssertEqual(state.codexServiceTier, "fast")
        XCTAssertEqual(state.modelName, "gpt-5.5", "基础 slug 仍是 turn_context 的值")
    }
```

- [ ] **Step 2: 跑测试，确认失败原因是模型名仍为 `gpt-5.5`**

```
swift test --filter CodexUsageEventParserTests/testFastServiceTierAppendsFastSuffix
```

Expected: FAIL，`gpt-5.5` != `gpt-5.5-fast`（或 events 为空——那就是 settings 行干扰了解析，先修 consume 别把 settings 当 token）。

- [ ] **Step 3: 最小实现**

`CodexUsageEventParser`：

1. 加 `private var serviceTier: String?`
2. `init`：`serviceTier = state?.codexServiceTier`
3. `finish` 的 `ParserState(...)` 加 `codexServiceTier: serviceTier`
4. 两个辅助函数：

```swift
    private func consumeThreadSettings(_ payload: [String: Any]) {
        let settings = JSONDictionary.dictionary(payload, "thread_settings") ?? payload
        if let tier = JSONDictionary.string(settings, "service_tier") {
            serviceTier = tier
        }
    }

    private func billedModelName(base: String?) -> String? {
        guard let base, !base.isEmpty else { return base }
        let tier = (serviceTier ?? "").lowercased()
        guard tier == "fast" || tier == "priority" else { return base }
        if base.lowercased().hasSuffix("-fast") { return base }
        return base + "-fast"
    }
```

5. `consume` 的 `switch`：

```swift
        case "thread_settings_applied":
            consumeThreadSettings(payload)

        case "turn_context":
            if let payloadModel { modelName = payloadModel }
            projectPath = JSONDictionary.string(payload, "cwd") ?? projectPath
            if let modelName { flushPendingModelEvents(model: billedModelName(base: modelName) ?? modelName) }

        case "event_msg":
            if payloadType == "thread_settings_applied" {
                consumeThreadSettings(payload)
                return
            }
            guard isTokenCount, let info, let observedAt = timestamp(in: object) else { return }
            consumeTokenCount(
                info: info,
                observedAt: observedAt,
                sourceOffset: line.offset,
                eventModel: eventModel
            )
```

6. `waitingForTurnContext` 块开头也认 settings（fork 窗口里的档位不能丢），然后照旧 `return`：

```swift
            if entryType == "thread_settings_applied" || payloadType == "thread_settings_applied" {
                consumeThreadSettings(payload)
            }
```

7. `consumeTokenCount` 里 `resolvedModel` 在传入 `flushPendingModelEvents` / `resolvedEvent` 之前包一层 `billedModelName(base:)`：

```swift
        let billed = billedModelName(base: resolvedModel) ?? resolvedModel
        if let billed {
            if !pendingModelEvents.isEmpty { flushPendingModelEvents(model: billed) }
            events.append(resolvedEvent(pending, model: billed))
        } else {
            pendingModelEvents.append(pending)
        }
```

`resolvedEvent` 继续用传入的 `model` 写 `modelName` 和 `dedupeKey`（已经是 billed 名）。`flushPendingModelEvents(model:)` 的调用方必须传入 billed 名。

`turn_context` 里 **不要** 把 `self.modelName` 改成带 `-fast` 的值。

- [ ] **Step 4: 跑 Step 1 的测试，确认 PASS**

```
swift test --filter CodexUsageEventParserTests/testFastServiceTierAppendsFastSuffix
```

Expected: PASS。再跑 `swift test --filter CodexUsageEventParserTests` 防止回归。

- [ ] **Step 5: 再写失败测试（priority、default、外层 type、中途切换、续读）**

```swift
    func testPriorityServiceTierIsFast() throws {
        let settings = #"{"type":"thread_settings_applied","payload":{"thread_settings":{"service_tier":"priority"}}}"#
        let token = #"{"type":"event_msg","timestamp":"2026-07-08T01:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":1}}}}"#
        let lines = [line(meta, offset: 0), line(turnContext, offset: 1), line(settings, offset: 2), line(token, offset: 3)]
        let (session, _) = try CodexUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/c.jsonl"), resuming: nil
        )
        XCTAssertEqual(session.events[0].modelName, "gpt-5.5-fast")
    }

    func testDefaultServiceTierKeepsBaseModel() throws {
        let settings = #"{"type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"service_tier":"default"}}}"#
        let token = #"{"type":"event_msg","timestamp":"2026-07-08T01:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":1}}}}"#
        let lines = [line(meta, offset: 0), line(turnContext, offset: 1), line(settings, offset: 2), line(token, offset: 3)]
        let (session, _) = try CodexUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/c.jsonl"), resuming: nil
        )
        XCTAssertEqual(session.events[0].modelName, "gpt-5.5")
    }

    func testMissingServiceTierKeepsBaseModel() throws {
        let token = #"{"type":"event_msg","timestamp":"2026-07-08T01:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":1}}}}"#
        let lines = [line(meta, offset: 0), line(turnContext, offset: 1), line(token, offset: 2)]
        let (session, state) = try CodexUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/c.jsonl"), resuming: nil
        )
        XCTAssertEqual(session.events[0].modelName, "gpt-5.5")
        XCTAssertNil(state.codexServiceTier)
    }

    func testFastToggleOnlyAffectsLaterEvents() throws {
        let tokenA = #"{"type":"event_msg","timestamp":"2026-07-08T01:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":1}}}}"#
        let on = #"{"type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"service_tier":"fast"}}}"#
        let tokenB = #"{"type":"event_msg","timestamp":"2026-07-08T01:06:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"cached_input_tokens":0,"output_tokens":2}}}}"#
        let off = #"{"type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"service_tier":"default"}}}"#
        let tokenC = #"{"type":"event_msg","timestamp":"2026-07-08T01:07:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":30,"cached_input_tokens":0,"output_tokens":3}}}}"#
        let lines = [
            line(meta, offset: 0), line(turnContext, offset: 1),
            line(tokenA, offset: 2), line(on, offset: 3),
            line(tokenB, offset: 4), line(off, offset: 5), line(tokenC, offset: 6)
        ]
        let (session, _) = try CodexUsageEventParser.parse(
            lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/c.jsonl"), resuming: nil
        )
        XCTAssertEqual(session.events.map(\.modelName), ["gpt-5.5", "gpt-5.5-fast", "gpt-5.5"])
    }

    func testResumesFastServiceTierFromParserState() throws {
        let token = #"{"type":"event_msg","timestamp":"2026-07-08T01:06:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":1}}}}"#
        let previous = ParserState(
            lastEventSeq: 4,
            modelName: "gpt-5.5",
            sessionKey: "s1",
            codexServiceTier: "fast"
        )
        let (session, _) = try CodexUsageEventParser.parse(
            lines: [line(meta, offset: 0), line(token, offset: 1)],
            sourceURL: URL(fileURLWithPath: "/tmp/c.jsonl"),
            resuming: previous
        )
        XCTAssertEqual(session.events[0].modelName, "gpt-5.5-fast")
    }
```

- [ ] **Step 6: 先跑，该红的红、该绿的绿；不够就补最小代码**

```
swift test --filter CodexUsageEventParserTests
```

Expected: 新测试若因 `resuming` 没把 `modelName` 当 billed 基准而失败，检查 `consumeTokenCount` 的 `resolvedModel` 来源：`eventModel ?? modelName`，再 `billedModelName`。不要把 `self.modelName` 改成带后缀。

`flex` 不测也行（spec：不是 Fast）；不要写特殊分支。

- [ ] **Step 7: 提交**

```bash
git add Sources/TokenMeterCore/CodexUsageEventParser.swift Tests/TokenMeterCoreTests/CodexUsageEventParserTests.swift
git commit -m "feat: Codex Fast 从 service_tier 合成模型名"
```

---

### Task 4: CostCalculator 精确匹配 Fast 价

**Files:**

- Modify: `Tests/TokenMeterCoreTests/CostCalculatorTests.swift`

不改 `CostCalculator` 生产代码：有独立键就会命中。测试锁住「不剥 `-fast` 去借 Standard 价 / 不借 grok-4」。

- [ ] **Step 1: 写失败测试（夹具里同时有 Standard、Fast、grok-4-fast）**

```swift
    private func fastAwareCalculator() -> CostCalculator {
        func card(_ input: Double, _ output: Double) -> ModelPricing {
            ModelPricing(
                inputPerMTok: input, outputPerMTok: output,
                cacheReadPerMTok: input * 0.1, cacheWrite5mPerMTok: input * 1.25,
                cacheWrite1hPerMTok: input * 2.0
            )
        }
        let snapshot = PricingSnapshot(
            snapshotVersion: "test",
            source: "litellm",
            models: [
                "gpt-5.6-sol": card(5.0, 30.0),
                "gpt-5.6-sol-fast": card(8.0, 40.0),
                "gpt-5.6-luna-fast": card(0.40, 2.40),
                "grok-4-fast": card(0.20, 0.50)
            ]
        )
        return CostCalculator(snapshot: snapshot)
    }

    func testFastModelUsesItsOwnRateNotStandard() {
        let calc = fastAwareCalculator()
        let fast = calc.cost(for: event(model: "gpt-5.6-sol-fast", input: 1_000_000))
        XCTAssertEqual(fast.micros, 8_000_000)
        XCTAssertEqual(fast.source, .computed)
        let standard = calc.cost(for: event(model: "gpt-5.6-sol", input: 1_000_000))
        XCTAssertEqual(standard.micros, 5_000_000)
    }

    func testOpenCodeLunaFastComputesWhenUnreported() {
        let result = fastAwareCalculator().cost(for: event(model: "gpt-5.6-luna-fast", input: 1_000_000))
        XCTAssertEqual(result.micros, 400_000)
        XCTAssertEqual(result.source, .computed)
    }

    func testGrokFastKeepsItsOwnPrice() {
        let result = fastAwareCalculator().cost(for: event(model: "grok-4-fast", input: 1_000_000))
        XCTAssertEqual(result.micros, 200_000)
    }

    func testUnknownFastSuffixStaysUnknown() {
        // 禁止剥 -fast 去借 gpt-5.6-sol。没登记的 Fast 身份就是不知道。
        let result = fastAwareCalculator().cost(for: event(model: "gpt-5.6-terra-fast", input: 1_000_000))
        XCTAssertNil(result.micros)
        XCTAssertEqual(result.source, .unknown)
    }
```

- [ ] **Step 2: 跑测试**

```
swift test --filter CostCalculatorTests/testFastModelUsesItsOwnRateNotStandard
swift test --filter CostCalculatorTests/testUnknownFastSuffixStaysUnknown
```

Expected: 若生产代码没有剥 `-fast`，这些在 Task 1 之后就该 PASS。若 `terra-fast` 被算成 sol 的 $5，说明有人加了剥离或家族兜底，停下来按 spec 修。

- [ ] **Step 3: 提交**

```bash
git add Tests/TokenMeterCoreTests/CostCalculatorTests.swift
git commit -m "test: Fast 价精确匹配、不剥后缀兜底"
```

---

### Task 5: 登记 Fast API 价并重生快照

**Files:**

- Modify: `scripts/pricing-overrides.json`
- Modify: `Sources/TokenMeterCore/Resources/litellm-pricing.json`（只通过脚本）
- Modify: `Tests/TokenMeterCoreTests/PricingTests.swift`

- [ ] **Step 1: 写失败测试（包内快照必须有 Fast 键）**

在 `PricingTests.testBundledSnapshotPricesTheModelsThisMachineActuallyUses` 的模型列表里加入 Fast 身份，或另写：

```swift
    func testBundledSnapshotIncludesCodexFastRates() throws {
        let snapshot = try PricingSnapshot.loadBundled()
        let solFast = try XCTUnwrap(snapshot.models["gpt-5.6-sol-fast"], "缺 gpt-5.6-sol-fast，OpenCode/Codex Fast 会 unknown")
        XCTAssertEqual(solFast.inputPerMTok, 8.0)
        XCTAssertEqual(solFast.outputPerMTok, 40.0)
        XCTAssertEqual(solFast.cacheReadPerMTok, 0.8)
        XCTAssertEqual(solFast.cacheWrite5mPerMTok, 10.0)
        XCTAssertEqual(solFast.cacheWrite1hPerMTok, 10.0)

        let lunaFast = try XCTUnwrap(snapshot.models["gpt-5.6-luna-fast"])
        XCTAssertEqual(lunaFast.inputPerMTok, 0.4)
        XCTAssertEqual(lunaFast.outputPerMTok, 2.4)

        let standard = try XCTUnwrap(snapshot.models["gpt-5.6-sol"])
        XCTAssertNotEqual(standard.inputPerMTok, solFast.inputPerMTok)
    }
```

- [ ] **Step 2: 跑测试，确认失败是缺键**

```
swift test --filter PricingTests/testBundledSnapshotIncludesCodexFastRates
```

Expected: FAIL，`缺 gpt-5.6-sol-fast`。

- [ ] **Step 3: 写入 override**

在 `scripts/pricing-overrides.json` 的 `models` 对象里加入（`note` 不进快照）：

```json
    "gpt-5.6-sol-fast": {
      "inputPerMTok": 8.0,
      "outputPerMTok": 40.0,
      "cacheReadPerMTok": 0.8,
      "cacheWrite5mPerMTok": 10.0,
      "cacheWrite1hPerMTok": 10.0,
      "note": "OpenAI API Fast 短上下文（openai.com/api-fast-mode，2026-08-28）：$8 / $0.80 cached / $10 writes / $40。非 ChatGPT credits。"
    },
    "gpt-5.6-terra-fast": {
      "inputPerMTok": 4.0,
      "outputPerMTok": 24.0,
      "cacheReadPerMTok": 0.4,
      "cacheWrite5mPerMTok": 5.0,
      "cacheWrite1hPerMTok": 5.0,
      "note": "OpenAI API Fast 短上下文（2026-08-28）。非 ChatGPT credits。"
    },
    "gpt-5.6-luna-fast": {
      "inputPerMTok": 0.4,
      "outputPerMTok": 2.4,
      "cacheReadPerMTok": 0.04,
      "cacheWrite5mPerMTok": 0.5,
      "cacheWrite1hPerMTok": 0.5,
      "note": "OpenAI API Fast 短上下文（2026-08-28）。非 ChatGPT credits。"
    },
    "gpt-5.5-fast": {
      "inputPerMTok": 12.5,
      "outputPerMTok": 75.0,
      "cacheReadPerMTok": 1.25,
      "cacheWrite5mPerMTok": 15.625,
      "cacheWrite1hPerMTok": 25.0,
      "note": "OpenAI API Fast 短上下文 input/output/cache read（2026-08-28）；writes 按 convert_model 缺省 input×1.25 / ×2。非 ChatGPT credits。"
    },
    "gpt-5.4-fast": {
      "inputPerMTok": 5.0,
      "outputPerMTok": 30.0,
      "cacheReadPerMTok": 0.5,
      "cacheWrite5mPerMTok": 6.25,
      "cacheWrite1hPerMTok": 10.0,
      "note": "OpenAI API Fast 短上下文；writes 派生。非 ChatGPT credits。"
    },
    "gpt-5.4-mini-fast": {
      "inputPerMTok": 1.5,
      "outputPerMTok": 9.0,
      "cacheReadPerMTok": 0.15,
      "cacheWrite5mPerMTok": 1.875,
      "cacheWrite1hPerMTok": 3.0,
      "note": "OpenAI API Fast 短上下文；writes 派生。非 ChatGPT credits。"
    }
```

JSON 必须仍是合法对象：注意与前一条之间的逗号。不要手改 `litellm-pricing.json`。

- [ ] **Step 4: 重生快照**

```
bash scripts/update-pricing.sh
```

Expected: `wrote Sources/TokenMeterCore/Resources/litellm-pricing.json with <N> models`。stderr 里对 `gpt-5.6-sol-fast` **不应**出现「上游已收录」警告（canonical 与 `gpt-5.6-sol` 不同）。联网失败就停，不要手填快照。

- [ ] **Step 5: 跑测试确认 PASS**

```
swift test --filter PricingTests/testBundledSnapshotIncludesCodexFastRates
python3 -m unittest scripts.test_transform_pricing
```

Expected: PASS。`jq '.models["gpt-5.6-sol-fast"]' Sources/TokenMeterCore/Resources/litellm-pricing.json` 能看到价，没有 `note` 字段。

- [ ] **Step 6: 提交**

```bash
git add scripts/pricing-overrides.json Sources/TokenMeterCore/Resources/litellm-pricing.json \
  Tests/TokenMeterCoreTests/PricingTests.swift
git commit -m "feat: 登记 OpenAI API Fast 牌价"
```

---

### Task 6: OpenCode `*-fast` + cost 0 走 computed

**Files:**

- Modify: `Tests/TokenMeterCoreTests/OpenCodeUsageEventAdapterTests.swift`

适配器不改。这条把适配器（保留 modelID、`cost: 0` → 无 reported）和包内快照串起来。

- [ ] **Step 1: 写失败测试**

```swift
    func testLunaFastWithZeroCostIsPricedFromBundledSnapshot() throws {
        let database = try makeDatabase()
        try insert(database, id: "m1", sessionId: "s1", createdMs: 1_000,
            data: #"{"id":"m1","sessionID":"s1","role":"assistant","modelID":"gpt-5.6-luna-fast","providerID":"openai","cost":0,"time":{"created":1000},"tokens":{"input":1000000,"output":0,"reasoning":0,"cache":{"read":0,"write":0}}}"#)
        let sessions = try OpenCodeUsageEventAdapter(sourceDatabase: database).changedSessions(after: nil)
        let event = try XCTUnwrap(sessions.first?.events.first)
        XCTAssertEqual(event.modelName, "gpt-5.6-luna-fast")
        XCTAssertNil(event.reportedCostUSDMicros)

        let priced = try CostCalculator(snapshot: PricingSnapshot.loadBundled()).cost(for: event)
        XCTAssertEqual(priced.source, .computed)
        XCTAssertEqual(priced.micros, 400_000)
    }
```

- [ ] **Step 2: 跑测试**

```
swift test --filter OpenCodeUsageEventAdapterTests/testLunaFastWithZeroCostIsPricedFromBundledSnapshot
```

Expected: Task 5 完成后 PASS。若 `modelName` 不是 `gpt-5.6-luna-fast`，适配器被改过，停下来。若 micros 为 nil，快照没进键。

- [ ] **Step 3: 提交**

```bash
git add Tests/TokenMeterCoreTests/OpenCodeUsageEventAdapterTests.swift
git commit -m "test: OpenCode luna-fast 零上报成本按 API Fast 价计"
```

---

### Task 7: `derivedVersion` 13

**Files:**

- Modify: `Sources/TokenMeterCore/TokenMeterDatabaseSchema.swift`

没有独立行为测试可红：migrator 测试读的是 `derivedVersion` 常量。改注释 + 数字，跑现有 migrator 测试。

- [ ] **Step 1: 升版本**

`derivedVersion` 注释块追加一行，常量改为 13：

```swift
    /// 13：Codex Fast 从 service_tier 合成 {base}-fast；OpenCode *-fast 按 API Fast 价重算
    public static let derivedVersion: Int64 = 13
```

- [ ] **Step 2: 跑 migrator 测试**

```
swift test --filter TokenMeterDatabaseMigratorTests
swift test --filter CodexUsageEventParserTests
swift test --filter CostCalculatorTests
swift test --filter PricingTests
swift test --filter ModelNameNormalizerTests
swift test --filter OpenCodeUsageEventAdapterTests/testLunaFastWithZeroCostIsPricedFromBundledSnapshot
python3 -m unittest scripts.test_transform_pricing
```

Expected: 全部 PASS。

- [ ] **Step 3: 提交**

```bash
git add Sources/TokenMeterCore/TokenMeterDatabaseSchema.swift
git commit -m "feat: derivedVersion 13 重扫 Fast 身份与价格"
```

---

## Spec 覆盖

| Spec | Task |
|---|---|
| 身份 `{base}-fast`、不剥 `-fast`、grok-4-fast | 1 |
| Codex 两份状态 + `billedModelName` | 3 |
| 两种 `thread_settings_applied` 外壳 | 3（event_msg + 外层 type） |
| `ParserState.codexServiceTier` 续读 | 2、3 |
| 中途 `/fast` 只影响后续事件 | 3 `testFastToggleOnlyAffectsLaterEvents` |
| fork 窗口不丢档位 | 3 waiting 块 |
| OpenCode 适配器不改、cost 0 → computed | 6 |
| Fast 价卡 + 精确匹配 + 未知 Fast = unknown | 4、5 |
| `derivedVersion` 13 | 7 |
| 不做 Claude / credits / 2× 兜底 / Standard 改价 | 计划头「本轮不做」 |
