# 子代理归并到主会话 设计文档

**日期**：2026-07-11
**状态**：已与用户确认，待写实现计划
**目标**：把 coding agent 派发的子代理（sub-agent）的 token/花费归并到它所属的主会话，主会话卡片显示合计与子代理数量，可点开浮窗下钻看每个子代理明细；"进行中（isLive）"判断纳入子代理活动。

---

## 1. 背景与问题

OMP、Claude Code、Codex、OpenCode 这四家 coding agent 在执行任务时会派发子代理（subagent / spawned session）。用户观察到的问题：会话列表里子代理各占一条、token 分散、会话数被子代理灌水，而不是归到发起它的主会话名下。

### 1.1 关键认知：总量类统计早已包含子代理

必须先纠正一个直觉误区：**总 token、用量趋势、年度热力图这些数字，本来就已经包含子代理**。它们是对 `usage_events` 直接 `sum` 出来的（见 `RollupBuilder.rebuildDailyRollup`），只按日期/模型分组，**不看事件属于哪个会话**。子代理的事件一直都在总量里。

因此本设计**只**改"以会话为单位"的呈现，不碰总量类统计：
- 会话列表（sessionRail）里子代理各占一条 → 归到主会话
- 点开一个主会话看不到它子代理的贡献 → 下钻浮窗
- 会话数被子代理灌水 → 只算主会话
- isLive 不反映子代理活动 → 纳入子代理

`daily_rollup` / `trend` / `heatmap` / 总 token / 总成本一行都不改。

---

## 2. 四家的子代理数据结构（真实磁盘调研结论）

四家的子代理**物理上都是独立文件/独立记录**，没有任何一家把子代理塞进主会话文件。区别只在"怎么标明父是谁"和"是否已归并"。以下均为对本机真实数据的调研结论。

| Agent | 子代理存储 | 父子关联信号 | 覆盖率 | 层级 | 子代理可读名字 | 当前归属状态 |
|---|---|---|---|---|---|---|
| **Claude Code** | 独立文件 `<sessionId>/subagents/agent-<agentId>.jsonl` + `.meta.json` 边车 | 行内 `sessionId`==父；兼有目录结构 | 边车 100% 有 `agentType`；`toolUseId`↔`Agent` 调用 55/55 命中 | spawnDepth 1–5，但扁平存放 | 边车 `.meta.json` 的 `agentType`（`general-purpose`/`Explore`） | **已归并**：事件已挂在父 `session_id` 上，`is_sidechain=1` |
| **OMP** | 独立文件，按父会话**递归嵌套**：`<mainUUID>.jsonl` 旁 `<mainUUID>/` 目录放子文件 | 文件系统路径：子文件所在目录名 == 父文件 basename（去 `.jsonl`） | 950/950（100%），零例外 | 多级（899 一层 + 51 两层） | 文件名（如 `Developer-X`） | **独立会话**，未记父 |
| **OpenCode** | SQLite 独立 `session` 行 | 原生 `session.parent_id` 列（带索引 `session_parent_idx`） | 49/221=22.2% 子会话，零孤儿 | 单层 | `session.agent` 列 | **独立会话**，未记父 |
| **Codex** | 独立文件（平铺 `rollout-*.jsonl`，无嵌套） | `session_meta.payload.parent_thread_id`（或 `payload.source.subagent.thread_spawn.parent_thread_id`） | 420 子代理会话，45 父 id 全命中 | 单层（`depth`=1） | `agent_role`（worker/explorer/default）+ `agent_nickname` | **独立会话**，`isSidechain` 硬编码 false，未记父 |

### 2.1 Codex 的重要注意点

本机 `~/.codex` 是重度定制的 multi-agent 版（`multi_agent_version: v1`）。`thread_spawn`/`agent_role`/`parent_thread_id` 这些字段来自多 agent 能力的 Codex 构建；**vanilla codex CLI 可能不发这些字段**。设计必须容忍这一点：字段缺失时子代理无法关联，**退化成当前行为（独立会话），不报错、不丢数据**。

---

## 3. 核心决策：查询层归并 + Claude 不动

用户拍板的两个关键取舍：

### 3.1 归并放在查询层（不碰核心汇总逻辑）

底层 `usage_events` / `daily_rollup` / `session_rollup` 三张派生表**一列都不加、语义不变**（仍是"每会话/每天一行"）。归并只发生在概览查询时（`overviewRepository`）。理由：不碰 `RollupBuilder` 那套精细的、注释里全是踩坑记录的汇总逻辑，也不碰各家已验证的 token 采集/去重逻辑。风险最低。

### 3.2 Claude Code 保持现状，不改解析

Claude 的子代理**已经**归并进主会话（事件挂在父 `session_id`，统计现在就是对的）。它信号最全（目录结构 + 行内父 id + 边车名字），归并是"免费的正确"。**不为了"四家数据形态整齐"去改它那处已经正确的解析**——这符合外科手术式修改原则。

代价：Claude 的子代理在数据里不是"独立会话"，而是父会话里 `is_sidechain=1` 的事件。因此下钻与数量对 Claude 走一条按来源文件分组的分支（见 §6）。当前需求（合计+数量+下钻+名字）这条分支完全够用；将来若要把子代理当"独立会话"单独筛选/展示才需要再改。

---

## 4. 数据模型改动

只加三列。这三列由派生数据填充，因此**直接写进 `derivedTables` 的 `CREATE TABLE` 语句**、并 bump `derivedVersion`（`TokenMeterDatabaseSchema`）——derivedTables 的机制就是"schema 版本一变即 DROP + CREATE 派生表、下次启动全量重扫重建"，数据真相在会话文件里，重建零成本。**不走** `ALTER TABLE ADD COLUMN`（那是 configTables 那三张永不删除的配置表才用的加列方式）。

### 4.1 `agent_sessions` 加两列

```sql
root_session_key TEXT   -- 指向根主会话的 source_session_key。NULL = 本身是主会话。
                        -- 存"根"而非"直接父"：一次 WHERE root_session_key=? 取全部子孙，
                        -- 无需递归（OMP 的多级 spawn 在填值时就拍平到根）。
                        -- 仅 OMP/Codex/OpenCode 的子会话填此列；Claude 不填。
subagent_label TEXT     -- 子代理的可读名字，供下钻浮窗显示。主会话为 NULL。
                        -- 仅 OMP/Codex/OpenCode 的子会话填。
```

### 4.2 `source_files` 加一列（Claude 专用）

```sql
subagent_label TEXT     -- Claude 子代理文件（agent-<agentId>.jsonl）的名字，
                        -- 由 scanner 读同名 .meta.json 边车的 agentType 得到。
                        -- 非 Claude 子代理文件为 NULL。
```

**为什么 `subagent_label` 出现在两张表**：因为两种数据形态。OMP/Codex/OpenCode 的子代理是"独立会话"，名字属于会话（`agent_sessions`）；Claude 的子代理是"独立文件里的事件"，名字属于文件（`source_files`）。这是 §3.2"Claude 不动"决策的直接后果，是有意的、被封装在 repository 层的差异（§6）。

---

## 5. 各家填值逻辑

### 5.1 OMP（`OmpUsageEventParser` + `LocalAgentScanner`）

父子关系只能从**文件路径**推导（文件内容无父引用，见 §2）。路径信息在 scanner 层，不在 parser 层。

- **关键约束**：`root_session_key` 必须等于根主会话在 `agent_sessions` 里的 `source_session_key`，否则 §6 的 join 匹配不上。OMP 主会话的 `source_session_key` 是 `session` 行的 **UUID**（`OmpUsageEventParser.finish` 取 `session.id`），而主会话**文件名**形如 `<ISO时间戳>_<UUID>.jsonl` —— 两者不相等，不能直接拿文件名/目录名当 key。
- scanner 拿到子文件相对 root 的路径后：
  - `root_session_key` = 从路径**最顶层**那段目录名 `<ISO时间戳>_<UUID>` 里**提取出的 `<UUID>` 段**（末尾的标准 UUID）。多级 spawn 的孙代理也一路指向这个根 UUID。
  - `subagent_label` = 子文件的 basename（去 `.jsonl`），如 `Developer-X`。
- 判定"这是子代理文件"：该 `.jsonl` 位于某个 `.jsonl` 同名目录之下（路径深度 > 顶层）。顶层文件是主会话，`root_session_key` 留 NULL。
- 归组只认 `.jsonl`：父目录里混有 `.md`、`local/`、`.bash.log` 等非会话文件，忽略。
- **假设与退化**：依赖"根主会话文件有带 UUID 的 `session` 行、其 `source_session_key` 即该 UUID"。若某根主会话缺 `session` 行 UUID（`OmpUsageEventParser` 会 fallback 到文件名 basename 当 key），则提取出的 UUID 段匹配不上 → 该子代理关联失败、退化成独立会话（不报错）。测试须覆盖这条退化路径。

### 5.2 Codex（`CodexUsageEventParser`）

- 读 `session_meta.payload`：
  - 若 `parent_thread_id`（顶层或 `source.subagent.thread_spawn.parent_thread_id`）存在 → `root_session_key` = 该值（单层，父即根）。
  - `subagent_label` = `agent_role` + `agent_nickname`（如 `worker · <nickname>`）。
  - 顺带修正 `isSidechain`：`thread_source=="subagent"`（或 `parent_thread_id` 存在）时置 `true`。
- 字段缺失（vanilla codex）→ 全部留空 → 退化成独立主会话（现状），不报错。

### 5.3 OpenCode（`OpenCodeUsageEventAdapter`）

- 从 `session` 表读：`parent_id` → `root_session_key`（单层）；`agent` 列 → `subagent_label`。
- `parent_id` 为空 → 主会话，`root_session_key` 留 NULL。
- 全程只读 `session` 表结构列，不碰 `message.data` 正文。

### 5.4 Claude Code（`LocalAgentScanner`，解析归属不变）

- **不改** `ClaudeCodeUsageEventParser` 的会话归属：子代理文件的事件仍归父 `session_id`、`is_sidechain=1`。
- scanner 解析一个 Claude 子代理文件（路径含 `/subagents/agent-<agentId>.jsonl`）时，读同名 `.meta.json` 边车的 `agentType`，写入该文件的 `source_files.subagent_label`。
- 边车缺失或读取失败 → `subagent_label` 留 NULL，下钻回退到"子代理 #N / 短 agentId"（不阻断）。

---

## 6. 归并查询（`overviewRepository`）

### 6.1 统一的"主会话合计"

大部分归并能用一个统一查询覆盖两种形态，因为 **Claude 的子代理已在自己的 `session_rollup` 里、且没有独立子会话**：

> 主会话合计 = 自己的 `session_rollup` + Σ(`root_session_key` 指向它的子会话的 `session_rollup`)

- Claude：子会话集为空，Σ=0，退化成"自己"（其 rollup 已含子代理事件）——正确。
- OMP/Codex/OpenCode：自己 + 所有子会话之和——正确。

适用于：token 合计、成本合计、`isLive`（= max(自己 last_event, 子会话 last_event)；Claude Σ 空 → 自己，其已含子代理时间）。

### 6.2 主会话列表与会话数

- 会话列表只列主会话：`WHERE root_session_key IS NULL`。
  - Claude 所有 session 都满足（它不填此列）；OMP/Codex/OpenCode 的子会话被排除。
- 今日会话数：`count(*) WHERE root_session_key IS NULL AND last_event >= 今日零点`。

### 6.3 子代理数量与下钻明细（此处分派两种形态）

repository 提供一个方法 `subagentBreakdown(mainSessionId)`，内部按主会话的 `source_kind` 分派，返回**统一结构** `[{ label, tokens, costUsdMicros, durationMs, model, lastEventMs }]`：

- **OMP/Codex/OpenCode**（子会话形态）：
  ```sql
  SELECT s.subagent_label AS label, r.tokens_total AS tokens, r.cost_usd_micros, ...
  FROM agent_sessions s JOIN session_rollup r ON r.session_id = s.id
  WHERE s.root_session_key = (主会话的 source_session_key)
  ```
- **Claude**（sidechain 事件形态）：按 `source_file_id` 分组父会话的 `is_sidechain=1` 事件，join `source_files.subagent_label`：
  ```sql
  SELECT f.subagent_label AS label, sum(e.tokens_total) AS tokens, sum(e.cost_usd_micros), ...
  FROM usage_events e JOIN source_files f ON f.id = e.source_file_id
  WHERE e.session_id = ? AND e.is_sidechain = 1
  GROUP BY e.source_file_id
  ```

子代理数量 = 上述结果的行数（同样分派）。

UI 与上层只看到统一的 `subagentBreakdown` 结构，两种形态的差异封装在此方法内。

---

## 7. UI

- **会话卡片（`SessionRail` item）**：显示的 token/成本已是合计（§6.1）。若该主会话有子代理，挂一个数量徽标（如"⑫"或"12 个子代理"）。
- **下钻浮窗**：点卡片/徽标 → 浮层列出 `subagentBreakdown` 的每一项（名字、token、成本、时长、模型）。复用现有浮层样式（参考热力图卡片浮窗）。多级 spawn（OMP/Claude）因为 `root_session_key` 存的是根，自动拍平平铺列出所有后代，不做树形展开。

---

## 8. 测试策略

- **各家填值**（每家一个 fixture）：
  - OMP：嵌套目录 fixture → 断言子文件 `root_session_key` = 顶层 UUID、多级孙代理也指向根、`subagent_label` = 文件名。
  - Codex：带 `parent_thread_id` 的 session_meta fixture → 断言 `root_session_key`、`subagent_label`、`isSidechain=true`；无该字段的 fixture → 断言退化成主会话、不报错。
  - OpenCode：`session.parent_id` fixture → 断言 `root_session_key`、`subagent_label` 取自 `agent` 列。
  - Claude：子代理文件 + `.meta.json` 边车 fixture → 断言 `source_files.subagent_label` = 边车 `agentType`；解析归属不变（事件仍归父 `session_id`、`is_sidechain=1`）；边车缺失 → `subagent_label` NULL、不阻断。
- **归并查询**（父子 fixture）：断言主会话合计 = 自己 + 子；子代理数量正确；`isLive` 纳入子代理；会话数只算主会话；下钻返回每个子代理明细。
- **Claude 下钻分支**：断言按 `source_file_id` 分组、配上边车名字、行数=子代理数。
- **回归护栏**：`daily_rollup` token 逐日总量在本次改动前后一致（本次不碰总量，用它守住"没把总量算错"）。Codex 修正 `isSidechain` 不改变任何 token 数字（只改标记）。

---

## 9. 非目标（YAGNI）

- **不改 Claude 解析归属**（§3.2）。
- **不做树形下钻**：多级 spawn 一律拍平到根主会话，浮窗平铺列出所有后代。
- **不把子代理当"独立会话"做筛选/单独展示**：本次子代理只作为主会话的下钻明细存在（Claude 的甚至不是独立会话行）。将来有此需求再演进。
- **不改总量类统计**：`daily_rollup`/trend/heatmap/总 token/总成本本来就含子代理，一行不动。
- **不追求四家数据形态完全统一**：接受 Claude（sidechain 事件形态）与其余三家（独立子会话形态）的差异，封装在 `subagentBreakdown` 一个方法里。

---

## 10. 涉及文件一览

- `Sources/TokenMeterCore/TokenMeterDatabaseSchema.swift`：`agent_sessions` 加 `root_session_key`/`subagent_label`，`source_files` 加 `subagent_label`，bump `derivedVersion`。
- `Sources/TokenMeterCore/OmpUsageEventParser.swift` + `LocalAgentScanner.swift`：OMP 路径推导填值。
- `Sources/TokenMeterCore/CodexUsageEventParser.swift`：读 `parent_thread_id`、修正 `isSidechain`、填 label。
- `Sources/TokenMeterCore/OpenCodeUsageEventAdapter.swift`：读 `parent_id`、`agent` 填值。
- `Sources/TokenMeterCore/LocalAgentScanner.swift`：Claude 读 `.meta.json` 边车 `agentType` 填 `source_files.subagent_label`。
- `Sources/TokenMeterCore/UsageEventWriter.swift`：写入新列。
- `Electron/src/main/overviewRepository.ts`：归并查询、会话数、isLive、`subagentBreakdown`。
- `Electron/src/renderer/components/SessionRail.tsx` + 新浮窗组件 + `styles.css`：数量徽标 + 下钻浮窗。
- 各 parser/repository 的测试文件。
