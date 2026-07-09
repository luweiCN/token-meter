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

omp 的会话元信息在 **`"type":"session"`** 行里（`id`、`cwd`、`timestamp`，有时含 `title` / `parentSession`），46/46 个抽样文件全部存在。**不是 `session_meta`**——那是 Codex 的结构，omp 的 `.jsonl` 里一次都没出现过。照抄会让 `projectPath` 永远为 nil，omp 的用量无法归属任何项目，而且没有任何测试会红，因为 fixture 也是照抄的。

**也不能顺手接受 `"type":"session_init"`。** 943/1002 个 omp 文件是子 agent 文件，同时包含 `session` 行（UUID + `cwd`）与随后的 `session_init` 行（8 位短 spawn id、无 `cwd`）。解析时这两个分支不是在「识别」而是在「赋值」，后命中的覆盖先命中的，`sessionKey` 会从 UUID 退化成短串。多接受一种输入并非总是免费的——当处理带副作用时，宽容的匹配等于让最后一个说话的人赢。

`resuming state:` 参数服务于增量续读：Codex 的差分需要知道上一条的累计值。`source_files.parser_state` 字段已预留位置。

#### 4.3.1 token 语义归一（关键）

各源对「input」和「output」的定义**不一致**。以下结论均由本机真实数据的算术恒等式验证得出，不是从文档推断的：

| 源 | 恒等式 | 含义 | 验证样本 |
|---|---|---|---|
| Codex | `total = input + output` | `cached_input ⊂ input`，`reasoning ⊂ output` | 598/600 条成立 |
| omp | `total = input + output + cacheRead` | cache **独立于** input，`reasoning ⊂ output` | 3024 条反例证伪了 `total = input + output`；25,553 条 `output > reasoning`、0 条 `output < reasoning` |
| Claude Code | 无 total 字段 | `input_tokens` 不含 cache（cache 是独立字段），无 reasoning 字段 | Anthropic API 语义 |
| **OpenCode** | — | **`reasoning` 独立于 `output`** | **716 条 `output < reasoning`**（例：`output=53, reasoning=226`，glm-5.1）。反证了子集关系 |

`UsageEvent` 的字段定义因此固定为：

- `inputTokens` — **非缓存**输入。
- `cacheReadTokens` — 缓存读取，与 `inputTokens` **不重叠**。
- `outputTokens` — **完整输出，含 reasoning**。这是 `tokens_total` 生成列不加 `tokens_reasoning` 的前提。
- `reasoningTokens` — `outputTokens` 的子集，仅供展示，**不计入 total**。

**归一发生在 adapter 边界，不在生成列里分情况。** 源若把 reasoning 记在 `output` 之外（OpenCode 就是如此），它的 adapter 必须写入 `output + reasoning`；否则那部分输出永远不进 `tokens_total`。OpenCode 的 adapter 起初没做这件事，少算了 702,828 token。

"reasoning 是不是 output 的子集"必须**逐源用真实数据证伪**，不能因为三个源都成立就推广到第四个。判据很直接：找一条 `output < reasoning` 的记录。找不到不代表包含，但找到了就一定不包含。

各 adapter 的转换规则：

| 源 | inputTokens | cacheReadTokens |
|---|---|---|
| Claude Code | `input_tokens` 原样 | `cache_read_input_tokens` |
| Codex | `input_tokens - cached_input_tokens` | `cached_input_tokens` |
| omp | `input` 原样 | `cacheRead` |

**若不做这个减法，Codex 的 token 会被计成将近两倍**——那个 3.2 GB 的 session 里 `cached_input` 占 `input` 的 94.6%。

#### 4.3.2 Codex `token_count` 事件的实测行为

在一个 221 MB、含 5,366 条 `token_count` 事件的真实 session 上测得：

- **100% 的事件同时带 `last_token_usage` 与 `total_token_usage`。** 因此「对 `total` 做差分」这条路径在本机数据上从不触发。仍要实现它——其他 Codex 版本可能只写累计值——但不要以为它是主路径。
- **`total_token_usage` 从不递减**（0 次）。569 个 `compacted` 事件没有重置累计计数。重置处理逻辑保留为防御。
- **49 条畸形事件**（`last.input = last.output = 0` 但 `last.total_tokens > 0`，占 0.9%）。关键发现：**这些事件发生时 `total_token_usage` 的 input / output / cached 增量全部为 0**。那个 `total_tokens: 24505` 是**当前上下文窗口的大小**，不是本次消耗。它们是纯状态汇报，没有 token 被用掉。

  所以跳过它们既正确又不丢数据：两种口径（用 `last` 或对 `total` 差分）在这些事件上都得 0。**绝不能把 `total_tokens` 当成 output 写入**——那会凭空造出 120 万个不存在的 token。

- **`Σ last.input_tokens = 796,872,582`，而 `total_token_usage` 的终值是 `796,150,596`，相差 721,986（约 0.09%）。** 两个口径不完全等价。采用 `last` 优先（与 ccusage 一致，且它是 Codex 自报的「本次用量」）。这个偏差要在第 9.3 节的对账中记住，否则会被误当成我们的缺陷。

### 4.4 去重

沿用现有的 `messageId::requestId` 组合键（`ClaudeCodeSessionParser.swift:51`），但补两条规则：

1. 精确匹配 `(messageId, requestId)` 时，**保留时间戳更早的那条**（同一条 assistant 响应会因 resume/fork 出现在多个 session 文件里）。注意 `idx_usage_dedupe` 这个唯一索引只能拦住重复插入，「保留早者」需要应用层先比较 `observed_epoch_ms` 再决定 `INSERT` 还是 `UPDATE`——`INSERT OR IGNORE` 会保留先写入的那条，而扫描顺序不保证时间顺序。
2. 退化到只按 `messageId` 匹配时，若已存在 `is_sidechain = 0` 的条目，则**丢弃 `is_sidechain = 1` 的副本**。

规则 2 是**对 ccusage 上游修复的防御性移植**，不是本机观察到的问题。ccusage 的 issue #913 报告 `/btw` 类 sidechain 会用新的 `requestId` 重放父消息，从而重复计费缓存 token，规则 1 拦不住。

在本机数据上核查过：**5,492 个 session 文件、334,941 行中，零个 `message.id` 出现在多个 `requestId` 下**；50 个带 `subagents/` 的会话里，零个 `message.id` 在子文件与父文件间重叠；2,811 个 sidechain 文件的 `parentUuid` 从不指向主文件的 `uuid`。

该场景在本机不可复现，可能与特定 Claude Code 版本或 `/btw` 用法有关。规则保留——它防的是静默的重复计费，代价只有几行——但必须标明来源，否则下一个读代码的人会以为这里发生过事故。

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

`model_canonical` 的解析顺序：

1. 精确匹配
2. 去掉日期后缀 `-YYYYMMDD`
3. 去掉 provider 前缀 `vertex_ai/`、`bedrock/`、`anthropic/`、`zai/`

**不做家族兜底。** ccgauge 在匹配不到时会借用同家族任意模型的价格。在本机快照上实测，这会给出离谱的数字：

| 家族 | 变体数 | input 价跨度 | 兜底会选中 |
|---|---|---|---|
| `gpt-5` | 25 | $0.05 – $5.00（**100×**） | `gpt-5` ($1.25) |
| `glm` | 13 | $0.10 – $2.20（**22×**） | `glm-4-32b` ($0.10) |
| `haiku` | 17 | $0.25 – $1.20（4.8×） | `claude-3-5-haiku` ($0.80) |
| `opus` | 18 | $5.00 – $15.00（3×） | `anthropic.claude-3-opus` ($15.00) |

用 `gpt-5` 的价格给 `gpt-5.5` 计价会低估 4 倍；用 2024 年的 `claude-3-opus` 给现代 opus 计价会高估 3 倍。更糟的是这些结果会被标成 `cost_source = 'computed'`，用户看到一个精确到分的金额，无从知道它来自一个毫不相干的模型。

匹配不到就是匹配不到：`cost_usd_micros` 记 NULL，`cost_source` 记 `'unknown'`，UI 显示「定价未知」。这会促使人去跑 `scripts/update-pricing.sh`，而不是默默接受一个错误的数字。

#### 5.2.1 归一后撞名

多个原始 key 会归一到同一个 `model_canonical`。实测快照有 15 组，主因是 provider 前缀（`claude-opus-4-8` 与 `vertex_ai/claude-opus-4-8`），其次是日期后缀。

`CostCalculator` 只能保留一个：按**原始 key 的字典序**排序后取第一个（first-write-wins）。排序不可省略——Swift 字典的迭代顺序取决于每进程随机的哈希种子，实测同一份字典连跑十次得到四种顺序。

其中 2 组的价格并不一致：

| canonical | 胜出者 | 落选者 | 差异 |
|---|---|---|---|
| `claude-3-opus` | `claude-3-opus-20240229` (1h 缓存 $6.00) | `vertex_ai/claude-3-opus` ($30.00) | **5×** |
| `claude-3-haiku` | `claude-3-haiku-20240307` ($6.00) | `vertex_ai/claude-3-haiku` ($0.50) | **12×** |

成因是 LiteLLM 只给 direct-API 变体写了 `cache_creation_input_token_cost_above_1hr`（值本身可疑：opus 的比值 0.40，haiku 的 24.00），vertex 变体走了 `input × 2` 派生。于是「同一个 canonical 的两个价格」一个来自上游数据、一个来自我们的公式。

`scripts/transform_pricing.py` 在生成快照时检测这种情况并把它打印到 stderr。不阻塞生成——这两个都是 2024 年的模型，且只影响 1 小时缓存这一档——但人跑刷新脚本时必须能看见，而不是等某天有人对着账单发懵。

缓存费率**优先取 LiteLLM 的真实字段**（`cache_read_input_token_cost`、`cache_creation_input_token_cost`、`cache_creation_input_token_cost_above_1hr`，分别覆盖 669 / 225 / 113 个模型）。仅在字段缺失时才回落到派生值：`cache_read = input × 0.1`，`cache_write_5m = input × 1.25`，`cache_write_1h = input × 2`。

不要把 `input × 2` 当成 1 小时缓存的固定倍率。经核实，`claude-fable-5` 与 `claude-haiku-4-5` 的实际比值确为 2.00，但 `claude-3-opus` 是 0.40、`claude-3-haiku` 是 24.00。

转换脚本判断字段是否存在时**必须用 `is not None`，不能用真值判断**。LiteLLM 把「免费」显式写成 `0`：`zai/glm-4.6`、`glm-4.7`、`glm-5`、`glm-5-code`、`glm-5.1` 五个模型的 `cache_creation_input_token_cost` 都是 `0`。真值判断会把它们当成「字段缺失」并按 `input × 1.25` 派生出一个价格，等于给免费的缓存写入收费。**「免费」与「不知道」是两回事**——这与 `cost_usd_micros` 在成本未知时存 NULL 而非 0 是同一条原则。

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

1. **KPI 行**（4 张）：最近活动（见 7.2.1）、今日 Tokens（带日环比）、今日会话数、今日成本（带本月累计）。
2. **额度行**：仅显示用户置顶的少量供应商额度，复用已有的 `ProviderConfigOverride.menuRank`，默认与菜单栏一致。完整列表在设置页。另含当前 5h 计费窗口的 LIVE 卡（剩余时间、进度、燃烧率）。
3. **用量趋势**：堆叠柱状图，四段为 输入 / 缓存写入 / 缓存读取 / 输出。粒度（小时/天/周/月）与范围（7天/30天/90天）**联动约束**：范围 ≤ 2 天才开放「小时」，≥ 90 天才开放「月」。在 1180px 默认窗口下主区仅约 840px，画不下 720 根柱子；与其产出一张无法阅读的图，不如禁用该组合。
4. **年度活动热力图** 与 **模型排行** 并排（热力图占更大宽度）。

#### 7.2.1 为什么第一张卡是「最近活动」，而不是「运行中的 Agent」

原始需求是「很多任务在后台跑，首先要确认它在不在跑」。**这个问题没有可靠的非侵入答案。** 本机实测（14 个并发 agent 进程，其中一个正在执行任务、其余等待用户输入）：

| 信号 | claude | codex |
|---|---|---|
| 进程存在 | 无信息（11 个进程全在） | 无信息 |
| `%cpu` | 无信息（全为 0.0——`ps` 给的是**进程生命周期均值**，不是瞬时值） | 无信息 |
| 子进程数 | 无信息（全为 3） | 无信息 |
| ESTABLISHED 连接数 | **有信息**：等待输入时为 0，处理 turn 时 > 0 | 无信息（三个进程各持 1 条长连接，文件最后写入分别是 13 分钟、27 小时、86 小时前） |
| 是否持有 session 文件 | 无信息（从不持有，追加即关） | **有信息**（常驻持有，可定位到具体 session） |

两个信号各自只对一个 agent 有效，而且有效的部分**正好互补**：claude 能判断在不在跑却定位不到 session，codex 能定位 session 却判断不了在不在跑。

更要命的是它们都是**实现细节**。claude 明天引入连接池，或 codex 改成短连接，判据就静默失效——没有任何测试会变红，只有一张卡片开始骗人。

**唯一可靠的运行状态来源是 agent 自己。** 市面产品的做法是注入 hook：agent 开始时写一个状态，结束时改回来。它之所以可靠，正因为它不猜。

因此第一张卡只陈述磁盘上的事实：**哪些会话在多久之前消耗过 token**。5 分钟内有消耗的显示实心脉冲点。它不声称判断运行状态，因而永远不会骗人。

一张写着「2 个 Agent 正在运行」的卡片，若偶尔把闲置一天的会话算进去、或漏掉正在跑测试的那个，其伤害大于不做——用户会先不信这张卡，然后不信所有数字。**能确定的地方说确定，不能确定的地方不硬猜。**

后续可提供一条命令，帮用户向 Claude Code 的 `settings.json` 写入 hook；装了 hook 的 agent 显示真实运行状态，未装的显示最近活动。这是诚实的降级，不是妥协。

**年度热力图**：53 列 × 7 行，一格一天。着色维度可切（Token / 成本 / 会话数），默认 Token。

- **强度用对数映射**，不用线性。token 用量是长尾分布——本机存在 3.28 GB 的单个 session，某天用量可能是中位数的数十倍，线性映射会让 364 天挤在最浅色而 1 天全黑。

  这不是修辞。在本机 v1 库有数据的 63 天上实测（峰值 102.8 亿、中位数 2.49 亿）：

  | 档位 | 对数 | 线性 |
  |---|---:|---:|
  | 0 | 0 | **62** |
  | 1 | 0 | 0 |
  | 2 | 9 | 0 |
  | 3 | 30 | 0 |
  | 4 | 24 | 1 |

  线性色阶把 **98.4%** 的天数压进同一档。对数用了三档，加上 308 个无数据日的 level 0，整张图呈现四个层次。

  档位 1 空着，因为那个 102.8 亿的峰值是离群点，把整条曲线抬高了。**但这个测量取自 v1 库，而 v1 把跨天会话的 token 全记在最后一天**（§1 的缺陷之一），正是它制造了那个离群点。真实的 `daily_rollup` 分布只会更平缓。有了真实数据之后再回头评估是否需要改用分位数色阶——**用一个已知错误的数据源做的测量，只能用来证伪，不能用来定参数。**
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
| 1180px（默认） | 主区约 520px（左侧导航占 248px——早先写的「840px」是拍脑袋的）。KPI 4 列、额度 3 列、热力图与模型排行并排。 |
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

#### 9.3.1 本机基线（ccusage 20.1.0，2026-07-09 采集）

`ccusage <agent> daily --json`，全时间范围：

| agent | 天数 | 首日 | totalTokens | costUSD |
|---|---:|---|---:|---:|
| claude | 36 | 2026-05-30 | 10,244,861,237 | 12,150.66 |
| codex | 50 | 2026-04-16 | 18,455,520,473 | 14,869.44 |
| opencode | 73 | 2025-10-16 | 1,572,519,757 | 438.60 |

**token 语义已确认一致。** ccusage 的 codex 记录满足 `totalTokens = inputTokens + cachedInputTokens + outputTokens`，`reasoningOutputTokens` 不计入（实测最后一日 2,284,222 + 15,637,760 + 137,955 = 18,059,937）。这与 `UsageEvent.totalTokens` 的定义相同——两边都把 reasoning 视为已包含在 output 里，都把 cached 从 input 中分离后各计一次。因此两侧的 token 总量可以直接相减，不需要换算。

ccusage 的 codex 记录没有 `cacheCreation` 字段，与 codex 日志不区分缓存写入、我们的 `cache_write_5m` / `cache_write_1h` 对 codex 恒为 0 相符。

#### 9.3.2 我们漏扫了 `~/.codex/archived_sessions`

对账立刻发现 codex 少了 **954,227,362** token（占 5.2%）。50 天里 13 天不一致，全部是 ccusage 更多，集中在 2026-05-29 ~ 06-09。

原因不在解析，而在扫描范围。用一个独立的 Python 脚本直接累加 `~/.codex/sessions` 全部文件的 `last_token_usage.total_tokens`（跳过 `input == 0 && output == 0` 的纯状态事件），得到 **125,851 事件 / 17,501,293,111 token**——与我们 Swift parser 的输出一位不差。parser 是对的。**错的是我们没看 `~/.codex/archived_sessions/`**：70 个文件、7,228 个事件、954,673,982 token。

`TokenMeterPaths.defaultScanRoots` 只声明了 `.codex/sessions`。必须补上归档目录，`kind` 仍是 `.codexJSONL`，`provider_id` 仍归到 `codex`，因此 rollup 会自然合并。

**补之前必须先确认归档是"移动"而非"复制"。** codex 的事件没有 `messageId`，`UsageEvent.dedupeKey` 为 nil，`UsageEventDeduplicator` 会原样放行——若同一个 session 同时存在于两个目录，那 9.5 亿 token 会被计两遍。实测两目录文件名交集为 **0**，归档是移动。这个前提若在未来的 codex 版本里改变，去重必须改用 `source_session_key`。

这类缺陷单元测试永远发现不了：解析逻辑完全正确，错的是读哪里。只有拿一个独立实现在同一台机器的真实数据上跑一遍才会暴露。

#### 9.3.3 codex 事件缺一个身份键，于是重复被计两次

补上归档目录后，我们的总量变成 18,455,967,093，比 ccusage 多 **446,620**（0.0024%）。原因是 codex 有时把同一条 `token_count` 写两遍：**时间戳相同、`last_token_usage` 四个数全同、累积的 `total_token_usage` 不前进**。全语料里有 4 条这样的行，分布在 3 个文件。ccusage 按 `(timestamp, usage)` 去重，我们没有。**ccusage 是对的。**

codex 事件既无 `messageId` 也无 `requestId`，所以 `UsageEvent.dedupeKey` 恒为 nil，`UNIQUE(session_id, dedupe_key) WHERE dedupe_key IS NOT NULL` 这条索引对 codex 从不生效，`UsageEventDeduplicator` 也原样放行。

同一个缺口造成两个缺陷：

1. **同一 session 出现在两个 scan root** → `agent_sessions` upsert 成一行（同一个 `session_id`），但事件按 `source_file_id` 各挂各的，无人去重 → 计两次。今天不发生（归档是移动），但代码里没有任何东西保证它。
2. **同一文件内的重复日志行** → 就是上面那 446,620。

修法是给 codex 事件合成 `dedupe_key`，取值为 `observedEpochMilliseconds` 加 `last_token_usage` 的四个原始数（在我们做 `input - cached` 归一之前的值——键应当反映源行，而不是我们的加工）。那条既有的 UNIQUE 索引是按 `session_id` 建的，因而天然跨文件，两个洞一并堵上。

**一个方法论教训。** 我曾用一个"独立的" Python 脚本复现了 parser 在 `~/.codex/sessions` 上的输出——125,851 事件、17,501,293,111 token，一位不差——并据此断言 parser 没有问题。但那个脚本和 parser 一样逐行累加 `last_token_usage`，**它对这个缺陷并不独立**。两个共享同一盲点的实现互相印证，什么都证明不了。真正独立的第三方（ccusage）一比就出来了。挑选交叉验证的对象时，要问的不是"它是不是另一份代码"，而是"它会不会犯同一个错"。

#### 9.3.4 Claude 多算约 17.9%：缺 `requestId` 的事件从不参与去重

`UsageEvent.dedupeKey` 要求 `messageId` 与 `requestId` **同时**存在，否则为 nil。而 `UsageEventDeduplicator` 的第一遍循环把所有 nil 键的事件直接塞进 `passthrough`——它们再也不会参与任何去重。

本机真实数据里，**54,929 个 Claude 事件有 `messageId` 却没有 `requestId`**，合计 4,501,777,798 token：

| 文件类型 | 链路 | 事件数 | token |
|---|---|---:|---:|
| subagent | sidechain | 47,108 | 3,335,218,310 |
| 顶层 | main | 7,821 | 1,166,559,488 |

于是同一条 assistant 响应，在一处带 `requestId`、在另一处不带时，我们会计两次。一次 API 调用只计费一次。

| 口径 | claude token |
|---|---:|
| 现状（缺 requestId 的从不去重） | 12,166,805,198 |
| 按 `messageId` 去重 | 10,338,357,758 |
| ccusage | 10,244,861,237 |

**修法：Claude 的 `dedupeKey` 只用 `messageId`，`requestId` 不参与。** 三条实测支撑它是安全的：

1. **0 个 `messageId` 出现在多个 `requestId` 下**（原注释已记录）。`requestId` 对去重毫无贡献，只会因为时有时无而破坏匹配。
2. **0 个 `messageId` 跨越多个 `sessionId`**（41,482 个重复的 messageId 全在单个 session 内）。因此既有的 `UNIQUE(session_id, dedupe_key)` 足够，不需要全局唯一。这与 §11 记录的"subagent 转录里的 `sessionId` 就是父 session 的 UUID"互为印证。
3. **0 个 `messageId` 同时出现在顶层文件与 subagent 文件里。** 重复只发生在同类文件内部（resume / fork 复制）。所以去重不会把 subagent 的真实用量误删——去重后 subagent 仍保留 3,832,820,456 token。

`UsageEventDeduplicator` 的规则二（退化到只按 `messageId` 匹配，非 sidechain 胜过 sidechain）原本就是为这种情况写的。它失效的原因是位置：它跑在第二遍循环里，只处理**已经有 `dedupeKey`** 的事件，而缺 `requestId` 的事件在第一遍就被踢出去了。**我们为一个不存在的问题（一个 messageId 配多个 requestId）写了防御，却漏掉了真正存在的问题（requestId 时有时无）。**

修完后仍比 ccusage 多 93,496,521（0.91%），原因待查，留给 Task 17。

#### 9.3.5 「保留最早的副本」在流式日志下是系统性少算

`UsageEventDeduplicator` 规则一保留 `observedAt` 更早的那条，注释给的理由是"同一条 assistant 响应会因 resume / fork 出现在多个 session 文件里"。那个场景下两个副本逐字节相同，保留哪条都一样——"最早"只是一个无害的确定性 tiebreak。

但 Claude 的日志里还有第二种重复：**流式中间快照**。同一次 API 调用（同 `messageId`、**同 `requestId`**）在响应流式返回的过程中被反复写入，`output_tokens` 逐步增长：

```
msg_012PDPU2QeoHrDr1toE1sCuE   req_011CcB1cnW   input=10
   ts=2026-06-18T16:06:09.213Z   output=  4
   ts=2026-06-18T16:06:09.497Z   output=  4
   ts=2026-06-18T16:06:09.702Z   output=559
```

本机 52,711 个重复的 `messageId` 组里：**25,202 组的 `output` 不全相同**（流式 partial），27,509 组完全相同（纯复制）。同一个去重分支同时服务两种语义，而注释只描述了其中一种。

保留最早 = 保留最不完整的那一帧。实测三种策略在同一份数据上的总量：

| 策略 | claude token |
|---|---:|
| 不去重 | 24,413,320,065 |
| 保留最早（现状） | 10,354,005,122 |
| **保留最完整** | **10,371,228,835** |
| ccusage（同期采样） | 10,370,733,022 |

**规则改为：碰撞时保留 `tokensTotal` 最大的那条。** 流式过程中 `input` 与 `cache` 恒定、`output` 单调增，所以"最完整"等价于"最终帧"。纯复制的场景下所有副本相等，规则退化为任意选择，仍需 `observedAt` 与 `eventSeq` 补全全序以保证确定性。

**关于对账基线的一条纪律：** Claude 的语料是活的，用户随时在写。拿几小时前采集的 ccusage 数字去比对刚刚跑完的扫描，差值里混着语料增长，读不出任何结论。**必须在同一时刻采样两侧**，或者用一个 UTC 截断把两边都切到同一个时间点上。Codex 之所以能精确对到个位，是因为那份语料在对账期间没有变化。

**同一条规则被写在两个地方，其中一个改了、另一个没改。** `UsageEventDeduplicator`（内存去重）与 `UsageEventWriter.writeEvent`（数据库去重）各自实现了一次「碰撞时保留谁」。

全量扫描永远碰不到 writer 的那一份：一次流式响应的所有帧都在同一个文件、同一批解析里，deduplicator 在内存中就折叠掉了，writer 看不到冲突。**于是全量扫描的总数是对的，而缺陷仍在。**

它只在**增量续读**路径上发作：某次后台扫描恰好停在流式中间，把 `output=4` 的中间帧写进库；会话继续，文件追加 `output=559` 的最终帧；下次增量扫描读到它，writer 发现 `(session_id, dedupe_key)` 冲突，按「保留最早」丢弃了最终帧。那个 partial 从此固化，除非全量重扫。

而「常驻后台、每分钟增量刷新」正是这个应用的主路径——不是边角情形。

结论有两层：一是 writer 必须与 deduplicator 用**同一个**比较器（把全序抽成一个函数，两处共用，而不是各写一遍）；二是**一个漂亮的全量对账数字不能证明增量路径正确**，两条路径要分别验证。

#### 9.3.6 三个源的对账终局

**下表的绝对值是快照，会随语料增长而腐烂；可验收的是「差」那一列。** Codex 的 18,455,520,473 在几小时后就成了 18,455,910,425——而 delta 依然是 0。把某个具体数字写成验收标准，等于给未来的自己埋一个必然失败的断言。要断言的是**关系**：扫描总量等于同一时刻 ccusage 的总量。

三个源与 ccusage 在**同一分钟内**各采样一次（扫描前后各读一遍 ccusage，两次相同，证明期间语料未变动）：

| 源 | 我们 | ccusage | 差 |
|---|---:|---:|---|
| Codex | 18,455,910,425 | 18,455,910,425 | **0** |
| Claude Code | 10,399,075,664 | 10,399,336,816 | −261,152（0.0025%）|
| OpenCode | 1,572,548,852 | 1,572,519,757 | +29,095（0.0019%），待查 |
| omp | 4,968,233,477 | 不支持 | — |

OpenCode 的 `+29,095` 同样是快照：那次扫描读的是 16 小时前的数据库副本，而 ccusage 读的是活库——期间 OpenCode 自己重写或丢弃了约 29k token。真正的不变量只有一条：我们把 716 条 `output < reasoning` 反证过的 reasoning 全部计入 output（§4.3.1）。

omp 独立核对：42,372 事件与 parser 输出一致；`(timestamp, usage)` 重复为 **0**，不需要合成 `dedupe_key`。

OpenCode 的 `opencode.db` 全程以 `mode=ro&immutable=1` 打开，前后 md5 一致（`d27179d88a6ee5c9233541aee4708e0e`）。

三个源、三种缺陷、三个方向：codex 少算（漏目录）又多算（重复行），claude 多算（去重失效），opencode 少算（reasoning 未归一）。没有一个是解析逻辑写错了。**它们全部是语义假设的问题**，而语义假设只能靠真实数据和一个不共享你假设的第三方来证伪。

#### 9.3.7 codex 的 token 数据从 2026-04-16 才存在

本机 19,971 个 codex rollout 文件里，**96.7% 完全不含 `token_count` 行**（随机抽样 300 个，290 个为零）。按文件名日期分组后边界是干净的：2026-02 与 2026-03 的文件无一例外没有 token 记录，2026-05 之后无一例外都有，交界在 **2026-04-16**（当日 15 个有、1 个无）。

ccusage 独立给出的 codex 首日同样是 `2026-04-16`。两个实现从同一批文件得到同一个边界，说明这不是解析缺陷，而是旧版 codex 根本不把用量写进磁盘。这些会话的 token 数据**不可恢复**。

由此产生两个必须遵守的结论：

1. `agent_sessions` 与 `session_rollup` 的行数天然不等（实测 21,636 vs 2,141，差 19,495，绝大多数是 2026-04-16 之前的 codex 会话）。这个差不是 bug，不要试图"修复"。
2. **一切面向用户的"会话数"必须以 `session_rollup` 为准**，即只统计产生过用量的会话。若用 `count(*) FROM agent_sessions`，首页会显示两万多个会话，用户点进去看到的却是一片 0 token。Task 16 据此实现。

Overview 的历史趋势图在 2026-04-16 之前不会有 codex 数据。这是数据的真实形态，不需要在 UI 上特别标注——按 agent 分色的堆叠图里，codex 那一层自然从该日起才出现。

## 10. 分阶段实现

### Phase 1 — 数据层

schema v2；`LocalAgentSessionParser` 接口改为输出 `[UsageEvent]`；改造 4 个现有 adapter（Claude Code、Codex、omp、OpenCode）；pricing 资源与计价；rollup 重建；全量重扫按钮与进度 IPC；字节级预筛。

验收：与 ccusage 对账通过；增量扫描 < 500 ms；单元测试覆盖上述边界。

### Phase 1 — 已完成

18 个任务，外加对账过程中长出来的 7 个补丁（14b–14h）。终态：Swift 250 测试、Electron 51 测试全绿；`scripts/reconcile-with-ccusage.sh` 对四个源 PASS，codex 与 ccusage `delta = 0`。

**加法式迁移是对的。** Task 3 之后的每一步都在旧表旁边加新表、旧 parser 旁边加新 parser，因此每一个中间 commit 的 `swift test` 都是绿的。到 Task 18 时，旧代码已经可以用 `grep` 证明无人引用，删除是机械的。若当初在 Task 3 就删 v1 表，会有连续八个任务处在红色状态。

**两次「计划自己的 SQL 弄红计划自己的测试」。** Task 16 的 `dailyTrend` 多选了一列 `modelCount`，而同一节的测试断言 `toEqual` 不接受多余的键。Task 18 的 `v3Cleanup` 要 `DROP COLUMN model_provider / message_count / event_count`，而 `sessionsRepository.query` 正在读这三列——同一节的测试却只断言另外三列被删。两次都是：SQL 和测试分开写，各自看都对，放在一起矛盾。写计划时把「完整代码」写进每一步，防的正是这个；而它照样发生了两次，因为**我在写测试时看的是意图，在写 SQL 时看的是表结构**。

**计划漏掉了 `MenuBarSummaryRepository`。** 一段从未接进应用的 v1 死代码，查 `session_usage_latest` 与 `agent_sessions.model_name`。若按计划执行，它会活成"编译通过、一运行就 `no such column`"的查询。删除清单不能靠回忆，必须靠 `grep` 逐表反查。

### 数据库是纯派生物，因此没有 schema 迁移

**真相在磁盘上的会话文件里，不在数据库里。** 我们索引的一切都能靠一次全量重扫（274 秒）从 `~/.claude/projects`、`~/.codex/sessions`、`~/.omp/agent/sessions`、`opencode.db` 重建出来。

于是版本化的 schema 迁移是一套我们不需要的机器。取而代之：

- **配置表**（`settings`、`provider_config_overrides`、`scan_roots`）——用户设的东西，从文件重建不出来。`CREATE TABLE IF NOT EXISTS`，永不删。加列用幂等的 `ALTER TABLE ... ADD COLUMN`。
- **派生表**（`source_files`、`agent_sessions`、`projects`、`usage_events`、`daily_rollup`、`session_rollup`、`scan_runs`）——`PRAGMA user_version` 与 `derivedVersion` 不符时整体 `DROP` + 重建。

改 schema 从此零成本：动一个常量，下次启动自动重建，等一次全量重扫。**降级也安全**——版本不符就重建，方向无关，因为数据两个方向都能重建。

清空派生表时**必须同时清空 `scan_roots` 的扫描游标**（`last_successful_cursor` 等）。`scan_roots` 是配置表，却携带扫描状态。Task 15 已经踩过这个坑：`OpenCodeUsageEventAdapter.changedSessions(after:)` 用那个游标做 `time_updated > ?` 过滤，游标不清则 `usage_events` 清空后它返回空集，那批数据**永远不会重建**。「从未扫描过」必须对每一种源都成立，不能只对大多数成立。

**这个认识来得太晚，代价很具体。** Phase 1 从 Task 3 到 Task 18 的每一个任务都被「加法式迁移」约束着——新表必须与旧表并存、新 parser 必须与旧 parser 并存——只为让每个中间 commit 都能跑绿。那是十五个任务的额外约束，换来的是一个我们根本不需要的能力。

把数据库默认当作「真相来源」，是一个不假思索的前提。**先问一句「这里面有什么是丢了就找不回来的」，比设计任何迁移方案都值钱。** 本机的答案是：三张表、十二行。

### Phase 1 → Phase 2 之间：升级后的第一次打开

**本机的生产库仍是 `user_version = 1`**（`~/.token-meter/tokenmeter.sqlite`，36 MB，最后写入 2026-07-04）。Phase 1 全程都在临时库上验证，从未迁移过它。这意味着 Phase 1 记录的一切实测数字（2,202 个会话、35,260,164,417 token、9,603 条未知成本事件）都来自**扫描真实语料生成的临时库**，而不是用户正在读的那个。

v1 库与新流水线在同一批语料上的三个数字：

| | v1 生产库 | 新流水线 |
|---|---:|---:|
| 会话数 | 21,625 | 2,202 |
| token | 43,437,257,827 | 35,260,164,417 |
| 成本 | $2,391.60 | $32,320.81 |

三个数字，三个方向，各自对应 Phase 1 修掉的一类缺陷：

- **成本差 13.5 倍。** v1 只读 agent 自己写进日志的成本字段，而 Claude Code 早已不写 `costUSD`（§1），于是那两千多美元几乎全部来自唯一自带成本的 omp。新流水线用 LiteLLM 快照离线自算，且 cache 分档计价。
- **会话数差近 10 倍。** v1 把两万个零事件会话也列出来——它们是 2026-04-16 之前的 codex 记录，磁盘上根本没有 token 数据（§9.3.7）。
- **token 反而是 v1 更多（多 81.8 亿）。** 那是重复计数：缺 `requestId` 的 Claude 事件从不参与去重，多算 17.9%（§9.3.4）。

**升级路径的直接后果：** 迁移把 v1 表删掉，而 `usage_events` 是空的，`daily_rollup` 也是空的。用户打开应用会看到一片零，直到显式触发一次全量重扫（274 秒）。这是既定设计——不在启动时静默索引 12 GB（§10）——但**必须有一个能说清楚原因的空状态**。

界面要能区分两种「空」：

| 状态 | 判据 | 该说什么 |
|---|---|---|
| 从未用过 agent | `scan_roots` 无启用项，或语料目录不存在 | 「未检测到本地 agent 会话」 |
| 升级后尚未重扫 | `scan_roots` 有启用项，但 `usage_events` 为空 | 「数据结构已更新，需要重新索引一次」+ 重扫按钮 + 进度 |

一个显示 `0 tokens` 的首页，和一个显示「需要重新索引，点这里」的首页，是两个不同的产品。前者会让用户以为软件坏了。

### Phase 2 — 主界面

堆叠柱状图组件；年度热力图；概览页；用量页；会话/项目/模型页；响应式；自动刷新。

验收：常驻内存 < 200 MB 实测通过；三个断点手动验证；热力图 click 正确跳转并带上筛选。

### Phase 3 — 新 agent

按已定型的 adapter 接口新增：Gemini CLI、pi-agent、Kilo、Qwen、OpenClaw。

**本机数据可用性实测（2026-07-09，以 `ccusage <agent> daily --json` 的天数为准）：**

| agent | 目录 | 体积 | 可读出的天数 |
|---|---|---:|---:|
| pi-agent | `~/.pi` | 15 GB | 6 |
| Kilo | `~/.config/kilo` | 57 MB | 1 |
| Gemini CLI | `~/.gemini` | 3.6 MB | 3 |
| Qwen | `~/.qwen` | 40 KB | **0** |
| OpenClaw | `~/.openclaw` | 36 KB | **0** |

两件事因此改变：

1. **Qwen 与 OpenClaw 无法用真实数据验证。** 目录存在但不含任何用量记录。它们的 adapter 只能靠合成 fixture，而合成 fixture 的假设与实现出自同一处，正是最容易同时错的地方（omp 的 `session_meta` 就是这么错的）。这两个 adapter 应当排在最后，并在 spec 中显式标注"未经真实数据验证"，直到本机产生数据为止。宁可晚交付，也不要交付一个看起来能跑、数字却没人核对过的 adapter。
2. **pi-agent 一个源就有 15 GB**，超过当前四个源之和（12.8 GB）。全量扫描耗时预计从 177 s 增至 400 s 上下。这让 Task 15 的进度反馈从"锦上添花"变成必需品，也意味着 pi 的 adapter 必须严格流式——任何"先把文件读进内存"的写法都会在这里爆掉。

验收：每个有真实数据的 adapter 都有基于真实样本的单测；扫描后在 UI 中可见且数字合理。Qwen 与 OpenClaw 的验收标准降级为"单测通过且不会在扫描中抛异常"，并记入已知风险。

## 10.1 Phase 1 实测记录（Task 14 后）

首次全量扫描本机 12.8 GB 真实数据：

| 指标 | 值 |
|---|---|
| 全量扫描耗时 | 177 s（claude 46s / codex 75s / opencode 32s / omp 24s） |
| `usage_events` | 274,480 行 |
| `agent_sessions` | 21,636（其中仅 2,141 个有用量事件） |
| 峰值内存 | 3.85 GB |

按 provider 的事件数与 token：claude-code 90,863 / 12.04B，codex 125,851 / 17.50B，omp 42,372 / 4.97B，opencode 15,394 / 1.57B。`daily_rollup` 的汇总与 `usage_events` 精确一致。

**对账**：Codex 的 125,851 行精确等于「input 或 output 非零的 `token_count` 事件数」（总数 127,254，差值 1,403 正是设计上要跳过的纯状态事件）。Claude 的 90,863 与独立计算的 90,857 相差 ±1–18，原因是扫描期间本机仍在写入 Claude 会话文件；codex / omp / opencode 三者字节稳定，数字可精确复现。

**字节预筛（markers）是净收益。** Codex 全根扫描：开启 85 s / 9.7 GB，关闭 133.1 s / 12.2 GB。快 36%，省 20% 内存。注意 Task 13 在读取器隔离基准里测得 markers *更慢*（16.05 s vs 13.56 s）——那个基准的回调不做任何事，因而测不到跳过 22 万次 `JSONDictionary.object(from:)` 的收益。**微基准可以精确地测量一个无关紧要的量。**

**峰值内存的大头不是读取器缓冲。** 最大单行仅 5 MB。9.7 GB 来自 Foundation 的 autorelease 对象在 25.7 万行 × 2 万文件之间堆积；加一个 per-file `autoreleasepool` 后降至 3.85 GB。

### 三个在 Task 14 才暴露的设计缺陷

1. **`ParserState` 原本撑不住续读。** 它只带 `lastEventSeq` 与 `lastCumulative`。但续读时读到的字节块里没有 `session_meta` 行，`finish()` 会抛 `missingSessionKey`，并把 `project_id` / `session_updated_at` 覆盖成 NULL。`ParserState` 必须同时持久化会话元信息（`sessionKey` / `projectPath` / `modelName` / `cliVersion` / `startedAt` / `updatedAt`）。

2. **纯指纹跳过会让 v1→v2 升级永远扫不出数据。** 旧库里 `source_files` 全部标着 `parse_status = 'ok'`，指纹也没变，于是每个文件都被跳过，`usage_events` 永远为空。跳过条件必须同时要求 `usage_events` 里已有该文件的行（`lastSourceOffset(sourceFileId:) != nil`）。

3. **OpenCode 的多个会话会撞 `UNIQUE(source_file_id, event_seq)`。** 每个会话的 `event_seq` 都从 1 重新开始，而它们共用同一个 `opencode.db` 源文件。解法是给每个会话一个合成的 `source_files` 行（`opencode.db#<sessionKey>`）。

### 10.2 断点续读的三条真实不变量

Task 14 的代码审查用变异测试（把不变量对应的那一行改坏，看测试是否变红）暴露了三件事。它们共同定义了续读的安全边界。

**一、`UNIQUE(source_file_id, event_seq)` 不是重复计数的防线。** 一行若被重复消费，它会从 `parser_state.lastEventSeq` 拿到一个**全新的** `event_seq`，唯一约束根本看不见。真正的防线是 `resumeOffset` 精确、且 `parser_state` 与事件同步推进。`ON CONFLICT ... DO UPDATE` 的作用是让崩溃后的重放**幂等**，不是拦截重复。任何依赖唯一约束来论证"不会多算"的注释都是错的。

**二、`inode + dev + 尺寸增长` 不能证明"这是追加"。** 原地改写成更大的文件同样满足这三条（`Data.write(to:)` 保留 inode，已实测）。误判为追加的后果是三重的：新内容的前缀永不被解析、旧内容的事件因为走了续读路径而不被 `deleteEvents` 清除、解析器带着旧会话身份继续读。判据必须加上**内容指纹**。

指纹要回答的问题是"**旧的那段前缀是否原样还在**"，这决定了它的形状：

- `content_fingerprint` 存 `"<len>:<sha256-hex>"`，写入时 `len = min(4096, size)`。
- 比较时，从旧记录里取出 `oldLen`，去读**新文件**的前 `oldLen` 字节再哈希。

`len` 必须随 hash 一起存。若改用新文件的大小重新取样，取样窗口会随每次追加而变化，哈希必然不同，**追加就永远被误判成改写**。一个 467 字节的会话文件追加到 900 字节后，就会被整个重读——而每个会话文件在生命周期早期都小于 4 KB，那正是它被追加得最频繁的时候。这个错误由一个早已存在的测试（"续读消耗的字节必须少于全文件"）抓住。

**指纹缺失必须拒绝续读，而不是放行。** `content_fingerprint IS NULL`（v1 遗留行）、文件打不开、读到的字节少于预期、存的长度是负数——任何一种都走全量重读。特别注意 Swift 的 `Optional == Optional` 在两侧皆 `nil` 时返回 `true`：直接比较两个可选指纹，会让"读不出指纹"变成"指纹相同"，安全检查在无法判断时放行。

**指纹只在续读路径计算，不在跳过路径计算。** 这两条路径的风险不对称：

| 路径 | 触发条件 | 内容偷偷变了会怎样 |
|---|---|---|
| 跳过 | size 与 `mtime_ns` 都未变 | 沿用旧数字——**数据陈旧** |
| 续读 | 文件变大 | 新字节被接到旧解析状态与旧会话身份上——**数字错误，且看起来合理，并逐次累积** |

只有后者值得为它付出 I/O。把指纹放进 `fileMetadata`（一个"文件属性"结构）会让它在每条路径上被求值——一次无变化的增量扫描要 open 两万个文件、哈希 80 MB，而这个应用要常驻并每分钟自动刷新一次。指纹不是属性，是一次 I/O。

代价是明确的：一次同时保持字节长度与 `mtime_ns` 不变的改写会被跳过，数字陈旧到下次全量重扫。没有任何往会话日志追加的程序会这么做。这段注释的存在是为了拦住后来那个想"加固"它的人。

**三、游标必须在事件之后落库。** 原实现先 autocommit `parse_status='ok'` 与新 `resumeOffset`，再由 `UsageEventWriter` 在自己的事务里提交事件。两次提交之间崩溃，文件恰好满足跳过条件（ok + 尺寸/mtime 最新 + 已有事件），游标又已越过增量区——该文件**永远不会再被读**，那段增量永久丢失。正确顺序是：建行（`pending`）→ 写事件 → 推游标并标 `ok`。任何时刻崩溃都只留下 `pending`，下次扫描全量重读、`deleteEvents` 清场、重写。代价是一次白读，换取绝不丢数。

不要用一个大事务去解决第三条：全量扫描 177 秒、27 万行，长写事务会锁住整个库并让 WAL 膨胀到明细表大小。顺序本身就是正确性论证。

崩溃后的恢复路径是**确定性的全量重解析**：`pending` 行不满足跳过条件，也不满足 `shouldResume`，于是 `startOffset = 0`、`deleteEvents` 清场、`event_seq` 从 1 重新开始。重放因此写出与一次干净扫描完全相同的 `(source_file_id, event_seq)`。`ON CONFLICT ... DO UPDATE` 让这个重放幂等——它的职责是这个，不是拦截重复计数（见上文第一条）。

### 10.3 增量扫描的稳态成本

一次"什么都没变"的增量扫描，代价必须与**变化的**文件数成正比，而不是与文件总数成正比。这条被破坏过一次：为续读安全加的指纹一度放在 `fileMetadata` 里，于是每个文件在跳过判据生效之前就被 open + 读 4 KB + 哈希。

跳过判据最终是 `parse_status = 'ok'` ∧ size 未变 ∧ `mtime_ns` 未变 ∧ `parser_state IS NOT NULL`。最后一项一石二鸟：它精确表达"v2 的 scanner 完整解析过这个文件"，因而既能识别 v1 遗留行（旧格式解不成 v2 的 `ParserState`）要重扫，又让 19,211 个零事件的 codex 文件（§9.3.7）终于能被跳过——旧判据用"`usage_events` 里有没有这个文件的行"，把"没有事件"和"没解析过"混为一谈。

真实 codex 根，第二遍空扫：

| | 指纹 open 次数 | `files_changed` | 耗时 |
|---|---:|---:|---:|
| 改前 | ~19,971 | 19,211 | 40.2 s |
| 改后 | 0 | 0 | **3.2 s** |

### 10.4 峰值内存的真正来源：读取块，不是解析出的对象

扫描的峰值 RSS 曾是 3.52 GiB，约等于最大单个 codex 文件的大小（3.28 GB）。直觉的解释是"每行 `JSONSerialization` 产生的 autoreleased 桥接对象堆积到文件读完"。**这个解释是错的**，而且照它去改会让内存翻倍。

三种配置在真实 codex 根上的实测（`/usr/bin/time -l`，两次取优）：

| 配置 | 峰值 RSS | 耗时 |
|---|---:|---:|
| 每文件一个 `autoreleasepool` | 3.52 GiB | 82.4 s |
| 把 pool 移进 `onLine` 回调 | **7.20 GiB** | 87.4 s |
| 每文件 pool + 在 reader 的块循环里每 512 行排空 | **311.6 MiB** | **76.0 s** |

真正的大头是 `FileHandle.read(upToCount:)` 返回的 autoreleased 块 `Data`。codex 的字节预筛让大多数行根本到不了 `JSONSerialization`，所以按行解析的对象并不多。而那些块 `Data` 是在 **reader 的循环里**分配的，位于 `onLine` 之外——把 pool 移进 `onLine`，就没有任何 pool 在排它，块会跨整个 root 堆积，于是 7.74 GB。

**要在对象被分配的地方排空，不是在它被使用的地方。** 最终方案把排空放进 reader 的块循环，每 512 行一次：峰值降 91.4%，耗时反而更短。

这条只能靠测量得到。三个配置里排名第二的那个，是任何人凭直觉都会先写的那个。

### 10.5 全量重扫不开事务，靠自愈

`fullRescan` 的清理语句跑完之后（删事件与 rollup、`parser_state = NULL`、`parse_status = 'pending'`、`last_successful_cursor = NULL`），数据库的状态与「从未扫描过」**逐字节不可区分**。跳过判据和 `shouldResume` 都要求 `parse_status = 'ok'`，所以 pending 的文件必定被完整重读。因此 275 秒的重扫中途任何一刻崩溃，留下的只是"下次增量扫描要重做的工作"，没有任何数据损失。

这就是不开事务的许可证。反过来说：若 `testInterruptedFullRescanSelfHealsOnNextIncrementalScan` 变红，`fullRescan` 就必须改用事务或影子表——一个跨越几分钟、写入 26 万行的写事务会锁死整个库，并把 WAL 撑到明细表那么大。

**清空 `last_successful_cursor` 是必需的，但理由只对 OpenCode 成立。** JSONL 的续读靠 `source_files.parser_state`，那个游标是惰性的、清不清都一样。而 `OpenCodeUsageEventAdapter.changedSessions(after:)` 用它做 `time_updated > ?` 过滤：`usage_events` 被删空后若游标还在，它会返回空集，`.db` 的指纹也没变——**那些被删掉的 OpenCode 事件就再也不会被重建**。「从未扫描过」这个状态必须对每一种源都成立，否则自愈只是部分成立。

实测：真实语料 11.15 GiB / 26,374 个文件，耗时 274.7 s，发出 **102** 条进度事件（上限约 201），峰值 RSS 1116 MiB。事件总数与同一时刻的普通增量扫描相差 +7，正是这几分钟里语料自身的增长——两条路径收敛。

### 10.6 文件分类属于 parser，不属于 scanner

`sawClaudeUsage` 曾用裸子串 `line.text.contains("\"usage\"")` 在 scanner 里判断：一个没有 `sessionId` 的 Claude 文件，究竟是辅助文件（跳过）还是坏掉的会话文件（失败，把整根拖成 partial）。正文里碰巧出现这个字面量就会误判。

而 parser 本来就把每一行解析成了字典，它准确知道自己有没有见过 `message.usage` 对象。判断被下沉进 `ClaudeCodeUsageEventParser.finish`：

- 见过 `sessionId` → 正常返回会话。
- 没见过 `sessionId`，也没见过 `usage` 对象 → 辅助文件，返回 `nil`。
- 没见过 `sessionId`，但见过 `usage` 对象 → 坏掉的会话文件，抛 `missingSessionKey`。

`finish` 的返回类型因此变成 `(session: ParsedSession?, state: ParserState)`。`nil` 就是"这不是会话文件"——`ParsedSession.sessionKey` 是非可选的，不该为了表达"没有会话"去编造一个哨兵 key。

"见过 usage" 的标志在时间戳／角色／token 数的守卫**之前**置位：一个 token 全为零、甚至没有时间戳的 `usage` 对象，仍然说明这个文件是会话形状的。放宽的方向必须是 fail-closed。

这次放宽的护栏是"坏会话文件仍然必须失败"。该测试对当时的代码本来就是绿的——它守的是未来的回归，不是当下的缺陷。证明它有牙的办法不是硬凑一个失败，而是注入那个真正危险的实现（任何缺 `sessionId` 的文件都返回 `nil`），确认它变红。

## 11. 已知取舍与风险

- **不做数据迁移**，首次升级需一次全量重扫（12.8 GB，分钟级）。已通过显式按钮与进度反馈缓解。
- **成本写入时计算**，pricing 更新后需手动触发「重算成本」。选择理由是查询频率远高于 pricing 更新频率。
- **`cost_source = 'unknown'` 时成本记 NULL**，UI 需处理「部分成本未知」的汇总展示，不能静默按 0 累加。
- **手写图表组件**的工作量与渲染细节风险（tooltip 定位、坐标轴刻度、响应式重绘）由我们承担，换取零依赖与最低常驻内存。若实现中发现复杂度失控，退路是引入 uPlot。
- **subagent 归属：两家语义相反，各自照实处理。**
  - **Claude Code** 的 subagent 转录（`<父sessionId>/subagents/agent-*.jsonl`）里，`sessionId` 字段就是**父 session 的 UUID**。这些事件计入父 session，标记 `is_sidechain = 1`；一个逻辑 session 因此对应多个源文件——这正是 `usage_events.source_file_id` 存在的理由。
  - **omp** 的子 agent 转录（`<项目>/<时间戳>_<父UUID>/<名字>.jsonl`）里，`session` 行带的是**它自己的 UUID**，与父目录名中的 UUID 在 20/20 个抽样里无一相同。每个 omp 子 agent 是独立 session。

  把任一方的假设套到另一方，都会让用量归错会话。不做 turn 级归属。
- **Codex `service_tier` 倍率未实现**，本机配置未启用该字段，无法验证。
- **每个 parser 各自构造 `ISO8601DateFormatter`**，实测约 171 µs / 次，12,447 个 Claude 文件合计约 2.13 秒。改成 `static let` 能省掉，但 Apple 从未在文档里承诺 `ISO8601DateFormatter` 对并发 `date(from:)` 是线程安全的（`DateFormatter` 有此承诺，它没有）。全量重扫本身是分钟级，2 秒占比不足 2%——不为一个具体的小收益换一个抽象的并发风险。若将来改成并行扫描，这个决定不必回头看。
- **subagent 的 `agentId` / `attributionAgent` 字段未被采集。** 它们能支持「按子 agent 归因成本」，但 Phase 1 不需要。真要做时，parser 加两个字段即可。
- **全量重扫的峰值内存 1116 MiB，且同一进程内连跑两次会到 1897 MiB。** 后者说明内存**没有在两次扫描之间归还**。单根冷扫 codex 的峰值是 311.6 MiB（§10.4），四根 11.15 GiB 全量重扫是 1116 MiB——大致随语料线性增长，而不是被 pool 边界压住。全量重扫是罕见的显式操作，不是常驻路径，所以不阻塞 Phase 1；但"跑第二次更高"这一点值得单独查，它指向某个跨根存活的引用。
- **`OpenCodeUsageEventAdapter.changedMessageRows` 没有 `LIMIT`，一次把整张 `message` 表读进内存。** 实测行数 18,121，`data` 列合计 **168 MB**，单行最大 12.1 MB。`opencode.db` 文件确实有 1.9 GB，但绝大部分是其他表、索引与空闲页——**「1.9 GB 的数据库」不等于「1.9 GB 进内存」**，早先的记录夸大了这一点。168 MB 加上 Swift 字符串开销仍会把扫描峰值推高（codex 根已优化到 311 MB），值得改成按 `id` 分页游标，但不属于正确性问题。
