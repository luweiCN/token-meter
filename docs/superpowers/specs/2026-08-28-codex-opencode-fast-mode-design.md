# Codex / OpenCode Fast 模式 设计文档

**日期**：2026-08-28
**状态**：已实现
**目标**：把 Fast 当成单独的模型身份（`{base}-fast`），用 OpenAI API Fast/Priority 牌价计费。OpenCode 已写入的 `-fast` 目录 ID 能对上价；原生 Codex 从 `service_tier` 合成同一身份。ChatGPT credits 倍率不进入美元列。

---

## 0. 已确认决策

| 项 | 选择 |
|---|---|
| 展示 | Fast 与 Standard 分两行，不合并 |
| 口径 | 继续 API 美元。不用 ChatGPT credits 倍率（credits 会调，API 价相对稳） |
| Codex | 读 `service_tier`，合成 `{base}-fast` |
| OpenCode | 保留日志里的 `*-fast` modelID，不剥 |
| 查价 | Fast 作为快照一等公民；精确匹配；不做 2× 家族兜底 |
| 归一化 | **不**把 `-fast` 加进 `-xhigh` / `-high` 剥离表 |
| 本轮范围 | Codex JSONL + OpenCode SQLite。Claude Code `speed: "fast"` 下一刀 |

---

## 1. 背景

Fast 不是新模型权重。厂商侧是请求档位：

- Codex / ChatGPT：`service_tier = "fast"`（请求里常落成 `priority`）。速度约 1.5×（API 文档最高写到 2.5×）。ChatGPT credits 为 2.5×（GPT-5.6/5.5）或 2×（GPT-5.4）。API Fast 按模型公布美元价，不是统一倍率。
- OpenAI API：`service_tier: "fast"` 与 `"priority"` 同档（2026-07-30 Priority 改名为 Fast）。
- Anthropic：`speed: "fast"` + beta header，模型 ID 不变。本轮不做。

OpenCode 是少数把档位写进 **目录 modelID** 的客户端：`experimental.modes.fast` → `` `${model.id}-${mode}` ``，例如 `gpt-5.6-luna-fast`。上游 API 仍用原 `api.id`，另带 `service_tier: "priority"`。订阅场景 `cost` 为 0，TokenMeter 走 computed，快照没有 `*-fast` → `unknown`。

原生 Codex 模型 slug **不变**。档位在 `thread_settings_applied.thread_settings.service_tier`。`turn_context` 与 `token_count` 都没有这个字段。当前 `CodexUsageEventParser` 不读它，Fast 用量被算进 Standard 行、按 Standard 价。

`grok-4-fast`、`grok-code-fast-1` 是独立产品，定价表已有条目。不能无脑剥 `-fast`。

---

## 2. 身份

统一 canonical：`{base}-fast`（先 `lowercased()`，与现有 `ModelNameNormalizer` 一致）。界面不另做「Fast」徽章，Models 页按 `model_canonical` 聚合，名字就是 `gpt-5.6-sol-fast`。

| 来源 | 日志 | 入库 `model_name` / `model_canonical` |
|---|---|---|
| OpenCode | `modelID: "gpt-5.6-luna-fast"` | `gpt-5.6-luna-fast` |
| Codex Standard | `model: "gpt-5.6-sol"`，`service_tier` 缺省 / `"default"` | `gpt-5.6-sol` |
| Codex Fast | `model: "gpt-5.6-sol"`，`service_tier` 为 `"fast"` 或 `"priority"` | `gpt-5.6-sol-fast` |
| 真模型 | `grok-4-fast` | `grok-4-fast`（不剥、不改） |

`fast` 与 `priority` 同一档（大小写不敏感）。`flex` 不是 Fast。

同一 Fast 身份跨 Codex / OpenCode 归并。Standard 与 Fast 不归并。

`ModelNameNormalizer.effortSuffixes` 仍只有 `["-xhigh", "-high"]`。注释写明：那些档位只改推理 token 用量；Fast 改单价，剥了会把 Fast 并进 Standard。配套的 `CostCalculator.pricingKeyCanonical` 与 `scripts/transform_pricing.py` 的 `EFFORT_SUFFIXES` 保持同一张表。

---

## 3. Codex 解析

### 3.1 两份状态

解析器分开记：

- `modelName`：继续来自 `turn_context` / `model_info.slug` 的基础 slug，**不含** `-fast`
- `serviceTier`：最近一次读到的档位（`String?`）

写出 `UsageEvent` 时再合成展示名：

```
func billedModelName(base: String?) -> String? {
    guard let base, !base.isEmpty else { return base }
    let tier = (serviceTier ?? "").lowercased()
    guard tier == "fast" || tier == "priority" else { return base }
    let lower = base.lowercased()
    if lower.hasSuffix("-fast") { return base }
    return base + "-fast"
}
```

合成发生在 `resolvedEvent`（以及任何把 `modelName` 写进事件 / pending flush 的路径），这样 `dedupeKey` 里的 `modelKey` 与计费身份一致。已经发出的事件不回写：`/fast` 中途切换只影响之后的 `token_count`。

### 3.2 从哪读 `service_tier`

只认 `thread_settings` 对象上的 `service_tier`。实际落盘有两种外壳，都要认：

1. 外层 `type == "thread_settings_applied"`，`payload.thread_settings.service_tier`
2. 外层 `type == "event_msg"` 且 `payload.type == "thread_settings_applied"`，同样读 `payload.thread_settings.service_tier`

`turn_context` 与 `token_count.info` 没有该字段，不猜测。旧 jsonl 全程没有 `thread_settings_applied` → `serviceTier` 保持 nil → 全部 Standard。

Codex JSONL 的原始字节预筛必须包含 `thread_settings_applied`。解析器支持该事件并不够：若预筛只保留 `token_count`、`session_meta`、`turn_context`、`task_started`，档位行会在 JSON 解析前被静默丢弃，Fast 事件仍会按 Standard 入库。

### 3.3 续读

`ParserState` 增加可选字段 `codexServiceTier: String?`（缺 key 的旧 state 解码为 nil，行为与今天相同）。`finish` 写出、`init(resuming:)` 读回。增量续读时，文件后半段的 Fast 不会因为没重放到 settings 事件而掉回 Standard。

### 3.4 与 fork / pending 模型的关系

现有 fork 回放门闩、`pendingModelEvents`、迟到模型逻辑不改语义。flush pending 时用 **当时** 的 `billedModelName`，不把后来才出现的 Fast 档回贴到更早的 token 上。

---

## 4. OpenCode

`OpenCodeUsageEventAdapter` **不改**。它已经把 `modelID` 原样写入 `modelName`。ChatGPT 订阅 `cost == 0` → `reportedCostUSDMicros == nil` → `CostCalculator` computed。本轮只让 `gpt-5.6-luna-fast` 这种键能在快照里命中。

OpenCode 的 `variant`（`max` / `xhigh` 等）是推理档位，不是 Fast；继续走现有 `-xhigh`/`-high` 剥离，与 `-fast` 正交。例如 `modelID: gpt-5.6-luna-fast` + `variant: max` → canonical `gpt-5.6-luna-fast`。

---

## 5. 定价

LiteLLM 没有 `*-fast`。在 `scripts/pricing-overrides.json` 按 **OpenAI API Fast 短上下文牌价** 登记（[Fast mode 价表](https://openai.com/api-fast-mode/)，2026-08-28 查证）。`update-pricing.sh` 合并进 `litellm-pricing.json`，override 无条件优先。

TokenMeter 的 `RateCard` 有两档缓存写入。价表只有一列 cache writes 时：`cacheWrite5m` 与 `cacheWrite1h` 都用该列。价表没有 cache writes 时：沿用 `transform_pricing.convert_model` 的缺省——5m = input × 1.25，1h = input × 2.0。

| 键 | input | cacheRead | cacheWrite5m | cacheWrite1h | output | 出处 |
|---|---:|---:|---:|---:|---:|---|
| `gpt-5.6-sol-fast` | 8.00 | 0.80 | 10.00 | 10.00 | 40.00 | Fast 表短上下文 |
| `gpt-5.6-terra-fast` | 4.00 | 0.40 | 5.00 | 5.00 | 24.00 | Fast 表短上下文 |
| `gpt-5.6-luna-fast` | 0.40 | 0.04 | 0.50 | 0.50 | 2.40 | Fast 表短上下文 |
| `gpt-5.5-fast` | 12.50 | 1.25 | 15.625 | 25.00 | 75.00 | Fast 表；writes 派生 |
| `gpt-5.4-fast` | 5.00 | 0.50 | 6.25 | 10.00 | 30.00 | Fast 表；writes 派生 |
| `gpt-5.4-mini-fast` | 1.50 | 0.15 | 1.875 | 3.00 | 9.00 | Fast 表；writes 派生 |

`note` 写明出处与「API Fast 短上下文，非 ChatGPT credits」。

查价：`CostCalculator` 仍只对 `ModelNameNormalizer.canonical(event.modelName)` 做精确匹配。有 Fast 覆盖键就 computed；没有（未来新的 `{base}-fast`）→ `unknown`。禁止「剥 `-fast` 再乘系数」——GPT-5.5 Fast 是 2.5×，Sol Fast 相对现行 Fast 表是 $8/$40，系数不统一。

`grok-4-fast` 已在快照中，精确命中自己的价，不受影响。

长上下文档位 TokenMeter 本来就不建模；Standard / Fast 都用短上下文价。

本轮 **不** 改 Standard 牌价。包里 `gpt-5.6-sol` 仍可能是 LiteLLM 的 $5/$30，而现行 API Standard 可能已是 $4/$20。Fast 按 Fast 表登记，不把 Standard 顺手改掉。Standard 对齐留给下一次 `update-pricing.sh`。

---

## 6. 数据重建

`TokenMeterDatabaseSchema.derivedVersion` 当前为 14。13 首次引入 Fast 身份与价格；14 将 `thread_settings_applied` 纳入 Codex 预筛并再次全量重扫，修正此前被误算成 Standard 的 Codex Fast 事件。

必须 bump：Codex 的 `dedupeKey` 含模型名，身份一变旧键对不上；OpenCode Fast 事件已经按 unknown 落过库，不重算费用不会自己变。

---

## 7. 测试

| 文件 | 锁住的行为 |
|---|---|
| `ModelNameNormalizerTests` | `gpt-5.6-sol-fast` 保持 `gpt-5.6-sol-fast`；`grok-4-fast` 保持；`-xhigh` 仍剥 |
| `CodexUsageEventParserTests` | `service_tier: fast` / `priority` → `gpt-5.5-fast`；`default` / 缺省 → `gpt-5.5`；中途切换只影响后续事件；两种外壳都能读；`ParserState` 续读带上档位 |
| `LocalAgentScannerTests` | 原始 JSONL 经生产 marker 预筛后仍保留 `thread_settings_applied`，最终以 `*-fast` 和 computed Fast 价格入库 |
| `CostCalculatorTests` | `gpt-5.6-sol-fast` 用 Fast 价；$8/M input；`gpt-5.6-sol` Standard 不变；`grok-4-fast` 仍走自己的快照价 |
| `OpenCodeUsageEventAdapterTests` | `modelID: gpt-5.6-luna-fast` 且 `cost: 0` 时，writer/calculator 路径能 computed（可用 parser + CostCalculator 夹具，不必为这一条改适配器） |
| `scripts/test_transform_pricing.py` | Swift `effortSuffixes` 与 Python `EFFORT_SUFFIXES` 仍是 `("-xhigh", "-high")`；`canonical("gpt-5.6-sol-fast")` 不去掉 `-fast` |
| `PricingTests` / override 合并 | 覆盖键进快照后能查到 |

Codex 测试夹具在现有 `session_meta` + `turn_context` 上加一行 `thread_settings_applied`，再跟 `token_count`。

---

## 8. 明确不做

- Claude Code Fast（`speed: "fast"`）
- 把 ChatGPT 2.5× / 2× credits 折进美元列
- 未知 `{base}-fast` 自动按 2× 猜价
- 把 Fast 并进基础模型（无论是归一化剥离还是 UI 合并）
- 长上下文 / 短上下文分档
- 更新 Standard `gpt-5.6-sol` 等 LiteLLM 滞后牌价
- Models 页为 Fast 做单独视觉样式

---

## 9. 主要改动面

| 文件 | 职责 |
|---|---|
| `Sources/TokenMeterCore/CodexUsageEventParser.swift` | 读 `service_tier`，写出 `{base}-fast` |
| `Sources/TokenMeterCore/LocalAgentScanner.swift` | Codex marker 保留 `thread_settings_applied` |
| `Sources/TokenMeterCore/UsageEventModels.swift` | `ParserState.codexServiceTier` |
| `Sources/TokenMeterCore/ModelNameNormalizer.swift` | 注释：为什么 `-fast` 不在 effort 表 |
| `Sources/TokenMeterCore/TokenMeterDatabaseSchema.swift` | `derivedVersion = 14`，升级后重扫历史 Fast 事件 |
| `scripts/pricing-overrides.json` | Fast 价卡 |
| `Sources/TokenMeterCore/Resources/litellm-pricing.json` | 由 `update-pricing.sh` 重生，不手改 |
| 上表测试文件 | 锁行为 |
