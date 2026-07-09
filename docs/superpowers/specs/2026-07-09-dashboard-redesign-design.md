# TokenMeter 主界面与数据层重构设计

日期：2026-07-09
状态：待评审

## 1. 背景

主界面的统计维度不足：看不到模型维度的分布、看不到按天和按时间段的用量、看不到每个会话的用量。趋势图是纯 CSS 条，`TokenTrendChart.tsx` 是七行的占位组件。

但 UI 只是症状。根因在数据层：

`ClaudeCodeSessionParser.parse()` 把一个 session 文件里所有 assistant 消息的 usage **求和成一条记录**（`ClaudeCodeSessionParser.swift:83`），只保留最后一条消息的时间戳和最后出现的模型名。`session_usage_latest` 也只指向每个 session 的最新一行。

由此产生四个当前无法修复的缺陷：

1. **跨天会话的 token 全记在最后一天。** `provider_daily_usage` 用 `substr(u.observed_at, 1, 10)` 取日期（`LocalAgentUsageRepository.swift:317`）。
2. **会话内切换模型会丢失。** 一个 session 只能存一个 `model_name`，另一个模型的 token 被算到错误的模型头上。
3. **无法按小时切片**，因此做不出时间段分布，也做不出 5 小时计费窗口。
4. **成本恒为 0。** 经核实，当前版本的 Claude Code 已不再写入 `costUSD` 字段（在 275 MB 的样本文件中出现 0 次），而 `ClaudeCodeSessionParser.costUSDMicros(in:)` 只读这个字段。

此外发现一个现存 bug：`substr(observed_at, 1, 10)` 切出的是 **UTC 日期**。用户在东八区，每天 00:00–08:00 的活动被记入前一天。

## 2. 目标与非目标

### 目标

- 数据层改为 message 级：一条 assistant API 响应对应一行明细记录，带真实时间戳与模型名。
- 成本可离线自算，cache 分档计价。
- 主界面重做：概览页、用量页、会话/项目/模型分页。
- 统一 adapter 接口，使新增 agent 的成本降到「实现一个协议」。
- 自动刷新，事件驱动为主、轮询兜底。
- 常驻内存可控。

### 非目标

- 不做 turn 分组（沿 `parentUuid` 上溯把 assistant 记录归入发起它的 user 消息）。ccgauge 需要它是因为要展示对话轮次表，本设计的明细表止步于 API 响应级。
- 不做同比/环比对比模块。它只在「单日」这类特定时间范围下有意义，是三个额外查询换一个次要信息。
- 不为本机不存在数据的 agent 写 parser（Amp、Goose、Copilot、Codebuff、Kimi 未安装；Droid、Hermes 目录为空）。无法用真实数据验证的 parser 不构成可交付成果。
- 不做数据迁移。旧数据的日期归属和模型归属本来就是错的，保留它等于保留错误统计。schema 直接 v2，检测到 v1 则重建表并触发一次全量重扫。

## 3. 架构

进程职责划死：

| 进程 | 职责 |
|---|---|
| Swift (`TokenMeterCore`) | **唯一写入方**。扫描、解析、去重、计价、写 SQLite。菜单栏常驻。 |
| Electron 主进程 | **唯一查询方**。以 `readonly` 打开同一 SQLite，所有聚合用 SQL 完成。 |
| Electron renderer | 只接聚合结果，一屏图表的数据量在 KB 级。 |

数据流：**文件 → Swift 解析成 delta 事件 → SQLite 明细表 → SQL 聚合 → 图表**。聚合只发生在最后一步。

IPC 复用现有 `tokenMeterSocketClient`，双向：

- Swift → Electron：`scan.progress`（全量重扫进度）、`scan.finished`（触发查询刷新）。
- Electron → Swift：`scan.requestFull`（用户点全量重扫按钮）。

## 4. 数据层

### 4.1 明细事实表

```sql
CREATE TABLE usage_events (
  id INTEGER PRIMARY KEY,
  session_id INTEGER NOT NULL REFERENCES agent_sessions(id) ON DELETE CASCADE,
  source_file_id INTEGER NOT NULL REFERENCES source_files(id) ON DELETE CASCADE,
  event_seq INTEGER NOT NULL,               -- 文件内序号
  observed_epoch_ms INTEGER NOT NULL,       -- UTC 毫秒，唯一时间真相
  model_name TEXT,                          -- 原始名，如 claude-fable-5
  model_canonical TEXT,                     -- 归一名
  tokens_input INTEGER NOT NULL DEFAULT 0,
  tokens_output INTEGER NOT NULL DEFAULT 0,
  tokens_reasoning INTEGER NOT NULL DEFAULT 0,
  tokens_cache_read INTEGER NOT NULL DEFAULT 0,
  tokens_cache_write_5m INTEGER NOT NULL DEFAULT 0,
  tokens_cache_write_1h INTEGER NOT NULL DEFAULT 0,
  -- reasoning 是 output 的子集，不计入 total，见 4.3.1
  tokens_total INTEGER GENERATED ALWAYS AS (
    tokens_input + tokens_output +
    tokens_cache_read + tokens_cache_write_5m + tokens_cache_write_1h
  ) VIRTUAL,
  cost_usd_micros INTEGER,
  cost_source TEXT NOT NULL CHECK (cost_source IN ('reported','computed','unknown')),
  dedupe_key TEXT,
  source_offset INTEGER NOT NULL,
  is_sidechain INTEGER NOT NULL DEFAULT 0 CHECK (is_sidechain IN (0,1)),
  UNIQUE(source_file_id, event_seq)
);

CREATE UNIQUE INDEX idx_usage_dedupe
  ON usage_events(session_id, dedupe_key) WHERE dedupe_key IS NOT NULL;
CREATE INDEX idx_usage_time ON usage_events(observed_epoch_ms);
CREATE INDEX idx_usage_session ON usage_events(session_id, observed_epoch_ms);
CREATE INDEX idx_usage_model_time ON usage_events(model_canonical, observed_epoch_ms);
```

关键设计点：

- **`source_file_id` 必须存在。** 经核实，Claude Code 的 subagent 转录位于 `<父sessionId>/subagents/agent-*.jsonl`，且文件内的 `sessionId` 字段等于**父 session 的 UUID**（已在本机 52 个 subagents 目录上验证）。因此一个逻辑 session 对应多个源文件。`source_offset` 是文件内偏移，必须与 `source_file_id` 成对才有意义。`agent_sessions.source_file_id` 相应移除。
- **`model_name` 从 `agent_sessions` 下沉到明细行。** 本机真实数据中一个 session 内混用 `claude-fable-5` 与 `claude-opus-4-8`。
- **cache 写入分 5m / 1h 两档。** 1h 档的计价是 input 单价的 2 倍，合并存储就无法正确计价。
- **时间戳存 UTC epoch 毫秒。** 本地日期由写入方计算并落到 rollup 表。时区变更只需重建 rollup，不必重扫文件。

### 4.2 汇总表

两张物化表，均可从明细表纯函数地重建：

```sql
CREATE TABLE daily_rollup (
  usage_date TEXT NOT NULL,          -- 本地日期 YYYY-MM-DD
  provider_id TEXT NOT NULL,
  source_kind TEXT NOT NULL,
  project_id INTEGER,
  model_canonical TEXT NOT NULL,
  sessions_count INTEGER NOT NULL,
  events_count INTEGER NOT NULL,
  tokens_input INTEGER NOT NULL DEFAULT 0,
  tokens_output INTEGER NOT NULL DEFAULT 0,
  tokens_reasoning INTEGER NOT NULL DEFAULT 0,
  tokens_cache_read INTEGER NOT NULL DEFAULT 0,
  tokens_cache_write_5m INTEGER NOT NULL DEFAULT 0,
  tokens_cache_write_1h INTEGER NOT NULL DEFAULT 0,
  cost_usd_micros INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (usage_date, provider_id, source_kind, coalesce(project_id,-1), model_canonical)
);

CREATE TABLE session_rollup (
  session_id INTEGER PRIMARY KEY REFERENCES agent_sessions(id) ON DELETE CASCADE,
  first_event_epoch_ms INTEGER NOT NULL,
  last_event_epoch_ms INTEGER NOT NULL,
  events_count INTEGER NOT NULL,
  tokens_total INTEGER NOT NULL,
  cost_usd_micros INTEGER NOT NULL,
  cost_unknown_events INTEGER NOT NULL DEFAULT 0,  -- 有多少条事件的成本没算进去
  primary_model TEXT                  -- token 最多的模型
);
CREATE INDEX idx_session_rollup_last ON session_rollup(last_event_epoch_ms DESC);
```

`daily_rollup` 带 `model_canonical` 维度，「模型 × 日期」交叉才成立。年度热力图与趋势图查它。

**`sessions_count` 不可跨分组相加。** 它是该分组内的 distinct session 数；同一个 session 若在一天内用了两个模型，会在两行里各计一次。任何「总会话数」都必须从 `session_rollup` 或 `usage_events` 上做 `count(distinct session_id)`，不能对 `daily_rollup.sessions_count` 求和。token 与 cost 列则是可加的。

`session_rollup` 支撑会话列表与「在不在跑」判定（`max(last_event_epoch_ms)`）。

**小时分布不做物化表。** 单日几百条明细，从 `usage_events` 带索引聚合即可。

### 4.3 adapter 接口

```swift
public struct UsageEvent {
    let eventSeq: Int
    let observedAt: Date
    let modelName: String?
    let inputTokens, outputTokens, reasoningTokens: Int64
    let cacheReadTokens, cacheWrite5mTokens, cacheWrite1hTokens: Int64
    let reportedCostUSDMicros: Int64?
    let dedupeKey: String?
    let sourceOffset: Int64
    let isSidechain: Bool
}

public struct ParsedSession {
    let sourceKind: SourceKind
    let sessionKey: String
    let projectPath: String?
    let cliVersion: String?
    let events: [UsageEvent]
    let rawMeta: [String: String]
}

public protocol LocalAgentSessionParser {
    func parse(lines: [JSONLLine], resuming state: ParserState?) throws -> (ParsedSession, ParserState)
}
```

`events: [UsageEvent]` 这一个类型签名的改变，是整轮重构的核心。

**每个 adapter 内部负责把源语义归一成 delta 事件。** 各源的语义差异：

| 源 | usage 语义 | 提取路径 |
|---|---|---|
| Claude Code | 每条消息独立 delta | `message.usage.{input_tokens, output_tokens, cache_read_input_tokens}` + `cache_creation.{ephemeral_5m_input_tokens, ephemeral_1h_input_tokens}` |
| Codex | **累计值**，需相邻差分 | `payload.info.last_token_usage`（增量，优先）或对 `total_token_usage` 做差 |
| omp | 每条消息独立 delta，**自带成本** | `message.usage.{input, output, cacheRead, cacheWrite, reasoningTokens}` + `message.usage.cost.total` |
| OpenCode | SQLite，`message.data` 是 JSON 文本 | 解析 `data` 后取 tokens 与 cost |

`resuming state:` 参数服务于增量续读：Codex 的差分需要知道上一条的累计值。`source_files.parser_state` 字段已预留位置。

#### 4.3.1 token 语义归一（关键）

各源对「input」和「output」的定义**不一致**。以下结论均由本机真实数据的算术恒等式验证得出，不是从文档推断的：

| 源 | 恒等式 | 含义 | 验证样本 |
|---|---|---|---|
| Codex | `total = input + output` | `cached_input ⊂ input`，`reasoning ⊂ output` | 598/600 条成立 |
| omp | `total = input + output + cacheRead` | cache **独立于** input，`reasoning ⊂ output` | 3024 条反例证伪了 `total = input + output` |
| Claude Code | 无 total 字段 | `input_tokens` 不含 cache（cache 是独立字段），无 reasoning 字段 | Anthropic API 语义 |

`UsageEvent` 的字段定义因此固定为：

- `inputTokens` — **非缓存**输入。
- `cacheReadTokens` — 缓存读取，与 `inputTokens` **不重叠**。
- `outputTokens` — 输出，**已包含** reasoning。
- `reasoningTokens` — `outputTokens` 的子集，仅供展示，**不计入 total**。

各 adapter 的转换规则：

| 源 | inputTokens | cacheReadTokens |
|---|---|---|
| Claude Code | `input_tokens` 原样 | `cache_read_input_tokens` |
| Codex | `input_tokens - cached_input_tokens` | `cached_input_tokens` |
| omp | `input` 原样 | `cacheRead` |

**若不做这个减法，Codex 的 token 会被计成将近两倍**——那个 3.2 GB 的 session 里 `cached_input` 占 `input` 的 94.6%。

Codex 另有畸形事件（`input = output = 0` 但 `total > 0`，600 条中出现 2 条）。adapter 必须跳过这类事件并计数，不得把 `total` 当作 output 写入。

### 4.4 去重

沿用现有的 `messageId::requestId` 组合键（`ClaudeCodeSessionParser.swift:51`），但补两条规则：

1. 精确匹配 `(messageId, requestId)` 时，**保留时间戳更早的那条**（同一条 assistant 响应会因 resume/fork 出现在多个 session 文件里）。注意 `idx_usage_dedupe` 这个唯一索引只能拦住重复插入，「保留早者」需要应用层先比较 `observed_epoch_ms` 再决定 `INSERT` 还是 `UPDATE`——`INSERT OR IGNORE` 会保留先写入的那条，而扫描顺序不保证时间顺序。
2. 退化到只按 `messageId` 匹配时，若已存在 `is_sidechain = 0` 的条目，则**丢弃 `is_sidechain = 1` 的副本**。这是 ccusage 修复的重复计费问题（其 issue #913）：`/btw` 类 sidechain 会用新的 `requestId` 重放父消息，规则 1 拦不住。

subagent 转录里的记录是**真实的 API 消耗**，照常计入，只是 `is_sidechain = 1`，UI 可筛选。

### 4.5 时区

`usage_events.observed_epoch_ms` 是唯一时间真相（UTC）。

`daily_rollup.usage_date` 是**本地日期**，由 Swift 在写入时按系统时区计算。热力图、趋势图、「今日」KPI 全部基于它。

时区变更后提供「重建汇总」操作：只读 `usage_events` 重算两张 rollup 表，不触碰源文件。

## 5. 成本计算

### 5.1 定价数据

LiteLLM 的 `model_prices_and_context_window.json` 过滤后固化为仓库内的 JSON 资源，随 Swift 包一起分发。**运行时完全离线**，不发起任何网络请求——这与 TokenMeter 的本地工具定位一致。

`scripts/update-pricing.sh` 手动运行时才联网抓取并写回仓库，产物需提交。

定价落到 `model_pricing` 表（启动时从 JSON 资源 upsert），允许用户覆盖：

```sql
CREATE TABLE model_pricing (
  model_key TEXT PRIMARY KEY,
  input_per_mtok_micros INTEGER NOT NULL,
  output_per_mtok_micros INTEGER NOT NULL,
  cache_read_per_mtok_micros INTEGER NOT NULL,
  cache_write_5m_per_mtok_micros INTEGER NOT NULL,
  cache_write_1h_per_mtok_micros INTEGER NOT NULL,
  source TEXT NOT NULL CHECK (source IN ('litellm','builtin','user')),
  snapshot_version TEXT
);
```

### 5.2 模型名解析

`model_canonical` 的解析顺序（照搬 ccgauge 已验证的规则）：

1. 精确匹配
2. 去掉日期后缀 `-YYYYMMDD`
3. 去掉 provider 前缀 `vertex_ai/`、`bedrock/`、`anthropic/`
4. 按家族名兜底（fable / opus / sonnet / haiku / gpt-5 …）

缓存费率**优先取 LiteLLM 的真实字段**（`cache_read_input_token_cost`、`cache_creation_input_token_cost`、`cache_creation_input_token_cost_above_1hr`，分别覆盖 669 / 225 / 113 个模型）。仅在字段缺失时才回落到派生值：`cache_read = input × 0.1`，`cache_write_5m = input × 1.25`，`cache_write_1h = input × 2`。

不要把 `input × 2` 当成 1 小时缓存的固定倍率。经核实，`claude-fable-5` 与 `claude-haiku-4-5` 的实际比值确为 2.00，但 `claude-3-opus` 是 0.40、`claude-3-haiku` 是 24.00。

**LiteLLM 已把智谱的 provider slug 从 `zhipuai` 改为 `zai`。** 抓取脚本若仍按 `zhipuai` 过滤，`glm-4.6` 等模型会一条定价都拿不到，成本静默变成 `unknown`。快照 key 形如 `zai/glm-4.6`，而 OpenCode 上报的是裸 `glm-4.6`，因此 `ModelNameNormalizer` 的前缀表必须包含 `zai/`。

### 5.3 计价时机

**成本在写入时算好并存进明细行。** pricing 快照几个月才更新一次，而查询每分钟都在跑。

`cost_source` 取值：

- `reported` — 源文件自带成本（omp、OpenCode）。
- `computed` — 由 pricing 表算出（Claude Code、Codex）。
- `unknown` — 模型名在 pricing 表中无匹配，成本记 NULL 而非 0，UI 显式标注「定价未知」。

代价是 pricing 更新后历史成本不会自动变。配「重算成本」操作：只 `UPDATE usage_events` 并重建 rollup，不重扫源文件。

Codex 的 `service_tier` 倍率（fast/priority）暂不实现——本机 `~/.codex/config.toml` 未设置该字段，无法验证。留作 adapter 内部的扩展点。

## 6. 扫描、刷新与进度

### 6.1 增量扫描

沿用现有 `source_files` 指纹机制（`dev` / `inode` / `size_bytes` / `mtime_ns` / `content_fingerprint`）。指纹未变则跳过整个文件。

**单文件断点续读**：续读位置是 `select max(source_offset) from usage_events where source_file_id = ?`——按**文件**取，不是按 session 取。一个 session 横跨父 jsonl 与多个 subagent jsonl，各文件的偏移互不相干。配合 `source_files.parser_state`（Codex 的累计基线）。

本机最大的单个 Codex session 文件是 **3.28 GB**，内含 36,293 条 `token_count` 事件与超过 10 万条 `function_call` 事件。全量重解析不可接受。

**字节级预筛**：逐行 JSON 解析前，先在原始字节里查找标记串（Claude 找 `"usage"`，Codex 找 `"token_count"`），未命中直接跳过该行。ccusage 用 `memchr::memmem` 实现，Swift 侧用 `Data.range(of:)` 等价实现。

### 6.2 全量重扫

用户显式点击触发（设置页或索引状态页）。Swift 侧清空 `usage_events` 并重新解析全部源文件，通过 IPC 推送进度：

```
{ kind: "scan.progress", filesTotal, filesDone, bytesTotal, bytesDone, currentRoot }
```

Electron 渲染进度条。预计首次全量扫描处理 12.8 GB，耗时以分钟计。

### 6.3 自动刷新

主路径是**事件驱动**：Swift 扫描完成 → `scan.finished` → Electron 主进程重查 → 推给 renderer。

兜底是轮询，周期取 `SettingsSnapshot.autoRefreshSeconds`（该字段已存在于 `Electron/src/renderer/api.ts:13`，目前无人使用）。默认 60 秒。

窗口隐藏（`window.on('hide')` / `document.visibilityState`）时暂停轮询，显示时立刻刷新一次。

导航栏提供手动刷新按钮与自动刷新状态指示。

供应商额度（智谱余额、OpenCode Go 套餐）**走独立的刷新周期与独立的失败态**。它们是 HTTP 请求，需要 API Key、会超时、会 401，不能与本地 SQLite 查询共用刷新节奏。单个 provider 失败不影响整页。

## 7. 界面

### 7.1 导航

概览 / 用量 / 会话 / 项目 / 模型 / 索引状态 / 设置。

### 7.2 概览页

主区（左）与监控栏（右 300px，sticky）两栏。

主区自上而下：

1. **KPI 行**（4 张）：运行中 Agent 数（带脉冲点与「N 秒前有活动」）、今日 Tokens（带日环比）、今日会话数、今日成本（带本月累计）。
2. **额度行**：仅显示用户置顶的少量供应商额度，复用已有的 `ProviderConfigOverride.menuRank`，默认与菜单栏一致。完整列表在设置页。另含当前 5h 计费窗口的 LIVE 卡（剩余时间、进度、燃烧率）。
3. **用量趋势**：堆叠柱状图，四段为 输入 / 缓存写入 / 缓存读取 / 输出。粒度（小时/天/周/月）与范围（7天/30天/90天）**联动约束**：范围 ≤ 2 天才开放「小时」，≥ 90 天才开放「月」。在 1180px 默认窗口下主区仅约 840px，画不下 720 根柱子；与其产出一张无法阅读的图，不如禁用该组合。
4. **年度活动热力图** 与 **模型排行** 并排（热力图占更大宽度）。

**年度热力图**：53 列 × 7 行，一格一天。着色维度可切（Token / 成本 / 会话数），默认 Token。

- **强度用对数映射**，不用线性。token 用量是长尾分布——本机存在 3.28 GB 的单个 session，某天用量可能是中位数的数十倍，线性映射会让 364 天挤在最浅色而 1 天全黑。
- hover 出 tooltip：当天 token、会话数、请求数、成本、缓存命中率。
- **click 跳转到用量页**，并把日期筛选设为该日、粒度设为小时。

不做独立的「当日详情面板」。当日详情就是用量页在 `from = to = 某日` 时的一个特例，复用同一套筛选与图表实现。

**模型排行**：横条，成本 / Token 两种排序可切。

右侧监控栏只放**会话列表**：进行中的会话置顶高亮（项目、agent、模型、已跑时长、已耗 token 与成本），下方列出最近结束的若干条。

### 7.3 用量页

多维筛选：时间范围、粒度、模型、项目、agent、会话。筛选状态写入 URL query。

区块：KPI 行（总 token / 总成本 / 会话数 / 请求数 / 缓存命中率 / 缓存节省）、趋势图、Token 构成条、模型分布、项目分布、明细表。

**Token 构成条**保留为常驻区块。按本机数据推算缓存读取占比将超过 88%，不显式拆开的话，KPI 上的 token 总数会长期误导——这也是 ccgauge 把「缓存节省了多少钱」做成一等 KPI 的原因。

### 7.4 会话 / 项目 / 模型页

各自的排行与明细表，支持排序、搜索、分页。会话页可下钻到单个会话的 usage 时间线。

### 7.5 响应式

Electron 窗口默认 1180×760，当前未设 `minWidth`。本设计设 `minWidth: 720`。

| 断点 | 行为 |
|---|---|
| ≥ 1600px | 容器 max-width 1720px 居中，主区吃掉多余宽度，右栏固定 300px。「小时」粒度解锁。 |
| 1180px（默认） | 主区约 840px。KPI 4 列、额度 3 列、热力图与模型排行并排。 |
| < 960px | 全部单列。**右侧会话列表隐藏**，导航栏出现一个带数字的脉冲徽标按钮，点击弹出浮层显示完整会话列表。 |

### 7.6 图表实现

**不引入图表库。**

需要绘制的图表只有三类：堆叠柱状图（受联动约束，最多约 90 根柱 × 4 段 = 360 个矩形）、365 格年度热力图、横条排行。

- 热力图必须是 DOM——每格要 hover 与 click，canvas 需手写命中检测。
- 横条排行本来就是 div。ccgauge 的 `activity-stats.tsx` 与 `model-bar-chart.tsx` 同样是纯 CSS，未走图表库。
- 因此图表库只需负责一个堆叠柱状图。为此引入 Recharts（连带整棵 d3 依赖树）或 ECharts（约 1 MB）不划算，付出的是常驻 JS heap，换来的是用不上的功能。

手写一个约 200 行的堆叠柱状图 SVG 组件：Y 轴刻度、稀疏 X 标签、hover tooltip、`ResizeObserver` 响应式。

退路：若将来需要 dataZoom 或十万点折线，再单独引入 uPlot（40 KB，canvas）覆盖该场景，不影响已有组件。

## 8. 性能与内存预算

**Phase 2 的第一件事是实测当前基线**，用 `process.getProcessMemoryInfo()` 量出改造前 Electron 各进程的常驻内存。在拿到这个数字之前，下面的目标值是估计而非承诺。

验收标准：

- 窗口打开、常驻空闲：目标 < 200 MB（全部 Electron 进程之和）。若实测超出，必须给出按进程的内存构成分析与优化措施，不得静默放宽。
- 窗口关闭：destroy renderer，仅 Swift 菜单栏进程常驻。
- 增量扫描（无文件变化）：< 500 ms。
- 概览页首屏查询：< 100 ms。

约束：

- renderer 绝不接收明细行。所有聚合在主进程 SQLite 内完成。会话表分页，单页 ≤ 50 行。
- better-sqlite3 以 `readonly` 打开，复用 prepared statement。
- 零图表库依赖。

## 9. 测试策略

### 9.1 Swift

- 每个 adapter 的 parser 单测，输入为**真实样本的脱敏切片**（保留结构，抹去路径与内容）。
- Codex 累计值差分逻辑的单测，含乱序、缺失、重置（`compacted` 事件）等边界，以及 `input = output = 0 && total > 0` 的畸形事件必须被跳过。
- **token 语义归一单测**（见 4.3.1）：给 Codex adapter 喂 `input_tokens = 1000, cached_input_tokens = 900`，断言产出 `inputTokens = 100, cacheReadTokens = 900`，`totalTokens` 不把 900 算两遍。给 omp adapter 喂同样数值的 `input = 1000, cacheRead = 900`，断言产出 `inputTokens = 1000, cacheReadTokens = 900`。两者的 `reasoningTokens` 均不计入 `totalTokens`。
- 去重规则单测：精确键碰撞保留早者；`messageId` 退化匹配时丢弃 sidechain 副本。
- 时区分桶单测（bug 的最小复现）：构造 `observed_epoch_ms` 对应 UTC `2026-07-08T16:30:00Z` 的事件。在东八区，它的本地时间是 `2026-07-09 00:30`，应归入 `usage_date = 2026-07-09`。当前实现 `substr(observed_at, 1, 10)` 会得到 `2026-07-08`。
- pricing 解析单测：四级 fallback 各命中一次。

### 9.2 Electron

- repository 层 SQL 测试，用内存 SQLite 加固定 fixture。
- 组件测试沿用现有 `@testing-library/react`。
- 堆叠柱状图组件的快照与边界测试（空数据、单柱、全零）。

### 9.3 对账

**用 ccusage 作为 oracle。** 全量重扫后，对同一时间范围执行：

```bash
ccusage daily --json --since 20260601 --until 20260630
```

与 `daily_rollup` 的聚合结果逐日对比 token 与成本。两者的定价表同源（LiteLLM）、去重键同构（`messageId::requestId`），数字应当吻合。差异即缺陷。

这是本设计最强的验证手段：一个成熟的、被广泛使用的独立实现，作为我们数字正确性的参照。

**对账范围限于 ccusage 也支持的源**：Claude Code、Codex、OpenCode。ccusage 不支持 omp，该 adapter 只能靠自身单测与手工抽样核对。

## 10. 分阶段实现

### Phase 1 — 数据层

schema v2；`LocalAgentSessionParser` 接口改为输出 `[UsageEvent]`；改造 4 个现有 adapter（Claude Code、Codex、omp、OpenCode）；pricing 资源与计价；rollup 重建；全量重扫按钮与进度 IPC；字节级预筛。

验收：与 ccusage 对账通过；增量扫描 < 500 ms；单元测试覆盖上述边界。

### Phase 2 — 主界面

堆叠柱状图组件；年度热力图；概览页；用量页；会话/项目/模型页；响应式；自动刷新。

验收：常驻内存 < 200 MB 实测通过；三个断点手动验证；热力图 click 正确跳转并带上筛选。

### Phase 3 — 新 agent

按已定型的 adapter 接口新增：Gemini CLI、pi-agent、Kilo、Qwen、OpenClaw。这五个在本机均有真实数据可供验证。

验收：每个 adapter 有基于真实样本的单测；扫描后在 UI 中可见且数字合理。

## 11. 已知取舍与风险

- **不做数据迁移**，首次升级需一次全量重扫（12.8 GB，分钟级）。已通过显式按钮与进度反馈缓解。
- **成本写入时计算**，pricing 更新后需手动触发「重算成本」。选择理由是查询频率远高于 pricing 更新频率。
- **`cost_source = 'unknown'` 时成本记 NULL**，UI 需处理「部分成本未知」的汇总展示，不能静默按 0 累加。
- **手写图表组件**的工作量与渲染细节风险（tooltip 定位、坐标轴刻度、响应式重绘）由我们承担，换取零依赖与最低常驻内存。若实现中发现复杂度失控，退路是引入 uPlot。
- **subagent 归属**：本设计将 subagent 转录中的记录计入其父 session（因其 `sessionId` 字段即父 session UUID），标记 `is_sidechain = 1`。不做 turn 级归属。
- **Codex `service_tier` 倍率未实现**，本机配置未启用该字段，无法验证。
