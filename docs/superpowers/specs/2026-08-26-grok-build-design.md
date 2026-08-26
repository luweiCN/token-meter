# Grok Build 一等公民接入 · 设计文档

**日期**：2026-08-26
**状态**：已与用户确认，待写实现计划
**目标**：把 Grok Build 接进 TokenMeter 现有的两条管道——本地会话用量（总览 / 项目 / 会话 / 模型）和 SuperGrok 订阅额度（菜单栏环 + 弹窗卡）——设置里可开关。第一版不对齐 hooks 实时会话。

参考：Tokscale `crates/tokscale-core/src/sessions/grok.rs` 与 `crates/tokscale-cli/src/commands/usage/grok.rs`。只借口径和字段，不搬 unified.jsonl 优先、不搬 gRPC-Web protobuf。

---

## 0. 已确认决策

| 项 | 选择 |
|---|---|
| 额度种类 | SuperGrok 周/月计算池（`grok login` 登录态）。不是 xAI Console API credits |
| 第一版范围 | 本地扫描 + SuperGrok 额度 + 设置开关。hooks 下一刀 |
| 实现策略 | 会话文件为主、额度走 `grok agent stdio` 的 `x.ai/billing` |
| 成本 | 定价表 computed。不用 `costUsdTicks`（单位未对账） |

---

## 1. 架构

Grok Build 作为新的一等公民，只加两条现有管道，不新开子系统。

### 1.1 身份

对齐 Claude 的「kind / 文件类型 / 账本 id」三分：

| 角色 | 取值 |
|---|---|
| 设置开关 `LocalAgentKind` | `grok` |
| 扫描源 `SourceKind` | `grok_jsonl`（rawValue `"grok_jsonl"`） |
| 账本 / 额度 `provider_id` | `grok` |
| 显示名 | Grok Build（菜单栏徽章取首词 **Grok**） |

`UsageEventWriter.providerId(for:)`：`.grokJSONL` → `"grok"`，与额度供应商 id 相同，图表和菜单栏才能对上同一家。

### 1.2 本地用量

```
$GROK_HOME/sessions/<urlencoded-cwd>/<session-id>/updates.jsonl
        ↓ GrokUsageEventParser（只认这一份文件）
usage_events → rollup → 总览 / 项目 / 会话 / 模型
```

- `GROK_HOME` 未设则根目录为 `~/.grok/sessions`
- 第一版不扫 `events.jsonl`、`chat_history.jsonl`、`~/.grok/logs/unified.jsonl`

关掉设置里的 `grok` 时，这条 scan root 不跑（现有 `enabledAgentKinds` → `SourceKind` 过滤，见 `ProviderStore`）。

### 1.3 额度

```
~/.grok/auth.json 有登录态
        ↓ spawn: grok agent --no-leader stdio
        ↓ JSON-RPC  x.ai/billing
ProviderUsageSnapshot（周/月池百分比 + 重置时间）
        ↓ 现有 ≥5 分钟轮询
菜单栏环 + 弹窗供应商卡
```

和 Codex 同一类：本机 CLI + 登录态。TokenMeter **不读、不存、不打日志** Grok access token；真正带凭证发请求的是 Grok CLI。不填 API Key，不手写 gRPC protobuf，不打 `grok.com/rest/*`。

### 1.4 隐私

- 会话日志只读，不写入 `~/.grok`
- 入库只有 token 数、模型名、时间戳、路径元数据；提示词和回复正文不入库
- 额度请求只打用户已经登录的 Grok 后端（由 CLI 发起）

---

## 2. 本地扫描与解析

### 2.1 文件发现

对齐 DSH：专用枚举，**文件名必须是 `updates.jsonl`**。不能复用 `jsonlFiles()`（那会把同目录 `events.jsonl` / `chat_history.jsonl` 算进去）。

路径形态：

```
<sessions-root>/<urlencoded-cwd>/<session-id>/updates.jsonl
```

- `sessionKey` = 路径上的 `<session-id>`
- `projectPath`：优先同目录 `summary.json` 的 `info.cwd`；否则 URL-decode 上一层目录名
- 子代理：`summary.json` 有 `parent_session_id` 则写入 `ParsedSession.rootSessionKey`（查询层归并，与 Codex/OMP 相同）。没有则当主会话。多层父链交给现有 `flattenRootSessionKeys()`，解析器只填直接父 id
- 子代理可读名：`summary.json` 的 `agent_name`（有则写入 `subagentLabel`，没有则 nil）

`TokenMeterPaths.defaultScanRoots` 增加一根。`scan_roots.kind` 的 CHECK 约束加 `'grok_jsonl'`；旧库走现有「重建 scan_roots 表」迁移（与 dsh 相同，不是 derivedVersion 重建）。

### 2.2 权威事件：`turn_completed.usage`

Grok Build 当前版本在 `updates.jsonl` 里写 ACP 扩展事件 `_x.ai/session/update` / `session/update`，`sessionUpdate == "turn_completed"`，带 `params.update.usage`。本机实测结构（数字是该 user turn 内各次模型调用之和，按**整段记录**写入，不再做 delta）：

```json
"usage": {
  "inputTokens": 1332007,
  "outputTokens": 10990,
  "totalTokens": 1342997,
  "cachedReadTokens": 1196416,
  "cacheCreationTokens": 0,
  "reasoningTokens": 9148,
  "modelUsage": { "grok-4.6-build": { ... } }
}
```

也接受 `params.update.usage` 出现在其它 `sessionUpdate` 上（Tokscale `GrokUsage.from_update` 不限定事件名）。

Grok 的桶是**含子集**的：`inputTokens` 含 cache read，`outputTokens` 含 reasoning。写入 TokenMeter 时按现有 `UsageEvent` 合同拆：

| 落库字段 | 算法 |
|---|---|
| `inputTokens` | `max(0, inputTokens - cachedReadTokens)` |
| `cacheReadTokens` | `cachedReadTokens` |
| `cacheWrite5mTokens` | `cacheCreationTokens`（Grok 不分 5m/1h TTL，整段落 5m 档，与 DSH 相同） |
| `cacheWrite1hTokens` | 0 |
| `outputTokens` | **原样保留** Grok 的 `outputTokens`（reasoning 留在里面） |
| `reasoningTokens` | `reasoningTokens`（只展示，不进 `UsageEvent.totalTokens`，`CostCalculator` 也不再加一遍） |

用上面那条数验算：135591 + 10990 + 1196416 = **1,342,997**，等于 Grok 的 `totalTokens`。

**不要**学 DSH `tokensFromUsage` 再从 output 里减 reasoning。TokenMeter 的计价是 `outputTokens × 输出单价`；减了会漏计思考 token。DSH 那处是它自己的源格式约定，不覆盖 `UsageEvent` 文件头注释里的合同。

兼容蛇形字段名（`input_tokens` / `cached_read_tokens` / `cache_creation_tokens` / `reasoning_tokens`），与 Tokscale 相同。

模型名：`modelUsage` 恰好一个 key 就用它（例如 `grok-4.6-build`）；否则用 `summary.json` 的 `current_model_id`；再没有则 `nil`（writer 记 unknown）。

`costUsdTicks` 丢掉，`reportedCostUSDMicros` 保持 nil，成本走定价表。

去重键：`grok:{sessionId}:{eventId}:{sourceOffset}`。Tokscale 已证实 `eventId` 会复用，必须带文件内偏移。`eventId` 取 `params._meta.eventId` 或顶层 `_meta.eventId`，都没有则用 `turn-{eventSeq}`。

时间戳：优先 `_meta.agentTimestampMs`（毫秒）；否则 `timestamp` 若像秒（绝对值 < 1e12）则 ×1000。

一条带 usage 的更新 = 一条 `usage_events`。进行中的 turn 还没有 `turn_completed`，等它结束后下一次扫描再入账。

### 2.3 旧文件兜底

整份 `updates.jsonl` **一次 usage 对象都没有** 时，才用 `_meta.totalTokens` 的正向单调增量，整段落成 `inputTokens`（output / cache / reasoning 为 0）。这是旧 Grok 的缺口：总量能看，模型页的 input/output 会偏。

计数规则（Tokscale `ActiveTurn` 的单调约束）：

- 忽略 `totalTokens < 0`
- 若新值小于上次见到的值：视为流式回退，忽略
- 若新值大于上次：差值为本段 input
- 用户消息块（`sessionUpdate == "user_message_chunk"`）开启新 turn 基线

若同一文件先按兜底入过账、后来又出现 `turn_completed.usage`：`ParserState.requiresFullReplay = true`，scanner 删掉该 `source_file_id` 的旧事件并整文件重解析，避免两套口径叠在一起。

### 2.4 增量续读

`updates.jsonl` 是追加写，走现有 JSONL 续读（`resumeOffset` + 前缀完好）。`ParserState` 必须记住：

- `sessionKey` / `projectPath` / `rootSessionKey` / `subagentLabel` / `modelName` / `startedAt` / `updatedAt`
- `grokSawUsage: Bool?`（optional，旧 state 缺 key 当 false）
- 上次见到的 `totalTokens`：放进 `lastCumulative.inputTokens`（只在未见 usage 时有意义）

`finish()`：若本文件从未见 usage（state + 本轮），才把兜底事件写入 `ParsedSession.events`。见过 usage 则丢弃全部兜底。

扫描循环：`.grokJSONL` 走与 DSH 类似的按文件扫描（或 JSONL 根扫描但文件列表换成 `grokFiles()`）。第一版不做 Codex 那种 marker 预筛（当前会话文件远小于 Codex 的 GB 级 rollout）。

### 2.5 定价

当前随包 LiteLLM 快照没有 `grok-4.6` / `grok-4.6-build`。实现时按 [xAI 官方牌价](https://docs.x.ai) 查证后写入 `scripts/pricing-overrides.json`，键至少覆盖：

- `grok-4.6`
- `grok-4.6-build`

两键在官方未拆价时用同一组 input / cacheRead / output。`CostCalculator` 按 `ModelNameNormalizer.canonical` 匹配（取 `/` 最后一段，不剥 `-build`）。匹配不到就 `cost_source = unknown`，不允许家族兜底。

---

## 3. SuperGrok 额度与菜单栏

### 3.1 `GrokUsageProvider`

`ProviderType` 增加 `grok`。`ProviderConfigLoader.defaultConfig` 增加启用项：id `grok`，displayName `Grok Build`，无 credential / endpoint。

`fetchProviderUsage()` 顺序：

1. 找不到 `grok` 可执行文件 → `providerErrorSnapshot`，文案「未检测到 Grok 命令行」。搜索路径 = Codex 现有列表 **加上** `~/.grok/bin` 与 `$GROK_HOME/bin`（LaunchAgent 的 PATH 只有系统四件套）。
2. `~/.grok/auth.json` 不存在，或所有条目的 `expires_at` 都已过期 → 「未登录 Grok Build，请运行 grok login」。只检查文件存在与 `expires_at` 字符串，**不把 `key` / `refresh_token` 读进日志或错误文案**。
3. spawn `grok agent --no-leader stdio`（可执行文件用第 1 步找到的绝对路径，避免再依赖 PATH）：
   - stdin 写 JSON-RPC 行：`initialize`（ACP 握手，protocolVersion `"1"`，最小 capabilities）然后 `{"jsonrpc":"2.0","id":2,"method":"x.ai/billing","params":{}}`
   - 读 stdout 行，直到 `id == 2` 的响应
   - 有 `error` 或超时（10 秒，与 Codex 同级）则失败
   - 拿到 `result` 后 SIGTERM；stderr 丢弃，避免 ACP 噪音进错误文案
4. 解析 `result`（见 3.2）

不实现 Tokscale 的 `GetGrokCreditsConfig` gRPC-Web、`/rest/tasks/usage`、`/rest/subscriptions`。CLI 自己刷新 token。

多份 `auth.json` 条目：CLI 自己选当前会话；TokenMeter 不按条目循环。

### 3.2 解析

`GrokBillingParser`：`result` 当 JSON 对象，字段全部可选，兼容 `{val: n}` 包装（Tokscale `numeric_value`）。

百分比，按下述顺序取第一个有限值并 clamp 到 0…100：

1. `creditUsagePercent` / `usedPercent` / `usagePercent`（含 `config.` 前缀）
2. `totalUsed / monthlyLimit`（路径含 `usage.totalUsed`、`config.monthlyLimit` 等）

周期起止：`billingCycle.billingPeriodStart/End`、`currentPeriod.start/end`、`billingPeriodStart/End`。能解析成日期则：

- 跨度 6–8 天 → 周窗
- 跨度 27–33 天 → 月窗
- 其它 / 缺失 → **默认周窗**（SuperGrok 共用周池）

默认产出 **一条** metric（一个百分比对应一个窗口）。只有响应里出现两套**互不相同的周期对象**（例如同时有 weekly 与 monthly 的 used/limit 或两段 billingCycle）时才产出第二条。禁止把同一个百分比复制成 7d 和 30d 两只环。

窗口映射到现有菜单栏语义：

| 周期 | `label` | `windowDurationMinutes` | 弹窗 |
|---|---|---|---|
| 周 | `7d` | 10080 | **环**（资格线是 `windowDurationMinutes <= 7×24×60`） |
| 月 | `30d` | 43200 | **条**（与 OpenCode Go 月窗相同，不因环缺位而升级） |

只有周窗时：单窗供应商，`QuotaDisplayModel` 的 rings 只有一只，`MenuBarQuotaModel.Cell.shortWindow == nil`，菜单栏无论选 short/long 都画这一只。

`remainingPercent = 100 - usedPercent`。`resetAt` 用周期结束时间。`resetText` 用现有 formatter。组 `title` = `displayName`（Grok Build），弹窗当主组，标签只留 `7d` / `30d`。

告警走现有 `quotaUsedThresholdPercent`，不单开 Grok 阈值。刷新走现有 ≥5 分钟闸门。

### 3.3 失败

一律 `providerErrorSnapshot` + `ProviderErrorMessage.sanitized(providerName: "Grok Build", …)`。HTTP/RPC 402 或文案含 weekly limit / credits 时，用户可见「额度用尽」一类短句，不要把 JSON-RPC 堆栈或 token 漏出去。

### 3.4 菜单栏外观

- `PopoverView.MBTheme.seriesColor("grok")`：浅 `#111111` / 深 `#E6E6E6`
- `MenuBarProviderName`：`grok` → `Grok Build`（徽章仍取 displayName 首词 Grok）
- 供应商图标：`Sources/TokenMeterApp/Resources/ProviderIcons/grok.pdf`；没有矢量稿时第一版可以缺图标、只靠文字徽章，不挡功能

---

## 4. 设置、接线与测试

### 4.1 设置页

Coding Agent 集成加一行，和 Reasonix / DSH 同类（只统计、不装 hooks）：

- id `grok`，标签 **Grok Build**
- 说明：自动统计 `~/.grok` 会话流水
- `AgentBinaryDetector` 增加 `("grok", "grok")`，搜索目录含 `~/.grok/bin`

供应商额度加一行：

- id `grok`，pill **自动接入**
- 说明：自动读取本机登录凭证
- 来源：`~/.grok/auth.json`
- 无 Key 输入、无 WebView 登录

`AgentHooksInstaller` **不**给 Grok 写 hook 文件。

### 4.2 默认启用与迁移

新安装：`SettingsStore` 默认 `enabledAgentKinds` 含 `grok`（在现有 `claudeCode, codex, opencode, omp, reasonix, dsh` 之后）。

老库：`ensureNewAgentDefaults` 仅当数组**恰好等于** `["claudeCode","codex","opencode","omp","reasonix","dsh"]` 时追加 `"grok"`。用户改过开关的不回头（与 reasonix / dsh 同一幂等规则）。

Electron `LOCAL_AGENT_KIND_ALLOWED` 与 Swift `validateEnabledAgentKinds` 同步接受 `grok`。

### 4.3 必须改到的名单

漏一项，Grok 就会在某一页变成「其他」或扫不进来。

| 层 | 改什么 |
|---|---|
| `LocalAgentKind` / `SourceKind` | `grok` / `grok_jsonl` |
| `scan_roots.kind` CHECK + migrator | 加 `grok_jsonl` |
| `TokenMeterPaths.defaultScanRoots` | GROK_HOME / `~/.grok/sessions` |
| `LocalAgentScanner` | `.grokJSONL` 分支 + `grokFiles()` |
| `UsageEventWriter.providerId` | `grok_jsonl` → `grok` |
| `ProviderType` + `ProviderRegistry` + defaultConfig | `.grok` |
| SettingsStore / Electron `LOCAL_AGENT_KIND_ALLOWED` | 接受 `grok` |
| 总览 / 项目 / 会话 / 模型显示名 | `grok` → Grok Build |
| 趋势图系列 | `AgentTrendChart` / `Sessions.tsx` TREND_PROVIDERS 加入 `grok`，色 `--s6`（浅 `#111111` / 深 `#E6E6E6`） |
| `LiveSessionStore.allowedAgentKinds` | 登记 `grok`（hooks 以后才用） |
| Electron `AGENT_TO_SOURCE_KIND` 与 `overviewRepository` live CASE | `grok` → `grok_jsonl` |
| 菜单栏 `seriesColor` / `MenuBarProviderName` | 见 §3.4 |
| README 支持的数据源表 | 补 Grok Build 一行 |

`overviewRepository` 里 live_sessions 的 CASE **目前漏了 `dsh`**。本轮只加 `grok`，不顺手修 dsh（与本需求无关）。

### 4.4 测试（成功标准）

解析（Swift 单元测试，fixture 用匿名 JSON 行，不读用户家目录）：

1. 含 cache / reasoning 的 `turn_completed` → 拆桶后 `input+output+cacheRead == totalTokens`，`outputTokens` 仍含 reasoning，`reasoningTokens` 等于源字段
2. 无 usage、只有 `_meta.totalTokens` 爬升 → 只产生兜底 input 事件
3. 先兜底再出现 usage → `requiresFullReplay`，重放后库语义上只剩 usage 口径（parser 单测：第二轮 finish 只返回 usage 事件）
4. 路径解码 cwd；`parent_session_id` 进入 `rootSessionKey`
5. 文件发现：同目录 `events.jsonl` 不在 `grokFiles()` 结果里
6. 去重键含 `sourceOffset`，两条相同 `eventId`、不同偏移视为两条

额度：

7. 合成 billing JSON：周窗 metric `label == "7d"` 且 `windowDurationMinutes == 10080`
8. 月窗 `30d` / 43200
9. 只有百分比、没有日期 → 默认周窗
10. 无二进制 / 无 auth.json / 超时 → 固定中文错误；断言消息不含 `eyJ` / `Bearer` / token 形字符串

接线：

11. 设置接受 `grok`；拒绝未知 kind（在现有 settings 测试上加一条）
12. migrator：旧默认全集才追加 `grok`；用户改过的集合不变
13. `defaultScanRoots` 含 grok 根；`GROK_HOME` 覆盖生效

不测：真打 grok.com、真 spawn 联网的 grok agent、hooks 实时卡、unified.jsonl。spawn 路径用注入的可执行文件 / stub 测超时与「找不到二进制」。

### 4.5 明确不做（第一版）

- Grok hooks / 总览「进行中」秒级卡
- `~/.grok/logs/unified.jsonl`
- `costUsdTicks` 上报成本
- xAI Console API credits
- Tokscale 的 gRPC-Web protobuf 与 `grok.com/rest/*`
- 为凑菜单栏环位把月窗升级成环

---

## 5. 错误处理

| 情况 | 行为 |
|---|---|
| 会话目录不存在 | 该根 0 文件，不报错 |
| `updates.jsonl` 某行不是 JSON | 跳过该行 |
| 有 usage 但 token 全 0 | 不产生事件 |
| `summary.json` 缺或坏 | cwd 回退 URL-decode；没有 parent 就当主会话 |
| grok 二进制不存在 | 额度卡错误文案，扫描仍可进行（日志在磁盘上） |
| 未登录 | 额度卡错误文案，扫描不受影响 |
| billing `result` 无法抽出百分比 | 额度卡错误：「Grok 响应中没有可用的额度字段」 |
| spawn 超时 | 杀掉进程，额度卡错误 |

额度失败不得让本地扫描停掉；扫描失败不得让其它供应商额度停掉（现有 ProviderStore 隔离保持不变）。

---

## 6. 组件边界

| 单元 | 做什么 | 怎么用 | 依赖 |
|---|---|---|---|
| `GrokUsageEventParser` | 把一行 updates JSONL 变成 `UsageEvent` | scanner 按文件喂行 | `UsageEventParser`、`summary.json` 边车 |
| `grokFiles()` / 根路径 | 只枚举 `updates.jsonl` | scanner | `GROK_HOME` |
| `GrokBillingParser` | billing JSON → `ProviderUsageSnapshot` | provider 测与生产共用 | 无网络 |
| `GrokUsageProvider` | 找二进制、检查 auth 文件、spawn、交给 parser | `ProviderRegistry` | 本机 `grok` CLI |
| 设置 / Electron 名单 | 开关与显示名 | 现有设置页 | 无 |

改 parser 内部拆桶不应迫使额度代码变化；改 billing JSON 路径不应迫使扫描变化。
