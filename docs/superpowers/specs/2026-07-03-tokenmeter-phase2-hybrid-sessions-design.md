# TokenMeter 第二阶段混合架构与本地会话索引设计

## 背景

TokenMeter MVP 已经完成 macOS 原生菜单栏、provider quota 查询、多额度卡片、通知和本地配置。第二阶段不再只是把本地 coding agent session 以轻量摘要塞进现有浮窗，而是进入长期架构里的“原生常驻层 + 按需主界面”阶段。

本阶段要解决两个问题：

1. 全量覆盖本机 coding agent 的会话 token 使用情况。
2. 提供一个更适合图表、筛选、设置和导入状态的主界面，同时保证 Electron 中修改的设置能实时影响 Swift 菜单栏。

因此第二阶段采用混合架构：Swift 原生菜单栏继续常驻，Electron/React 作为按需打开的主界面，SQLite 作为共享事实源和增量索引库。

## 目标

本阶段交付一个本地优先的会话 usage 数据底座和主界面框架：

- Swift 菜单栏继续独立常驻，Electron 关闭后仍能刷新、扫描、通知和显示摘要。
- Electron/React 主界面负责图表、设置、供应商接入、agent 可见性、扫描状态和历史明细。
- SQLite 统一存储设置、扫描游标、source 文件状态、agent session、token usage 和聚合摘要。
- Electron 中修改设置后，Swift 菜单栏在秒级内热应用。
- 覆盖第一批本机 coding agent 数据源：Claude Code、Codex、OpenCode、OMP。
- 大 session 不跳过。所有 session 都必须记录，但通过流式解析和增量索引避免每次全量扫描。
- 索引器只保存元数据和 token usage，不保存 prompt、assistant response、tool output 或 reasoning 正文。

## 非目标

本阶段不做：

- 云同步。
- 账号系统。
- 上传会话数据。
- 读取或展示消息正文。
- 让 Electron renderer 直接访问 SQLite、Keychain 或文件系统。
- 把 Electron 变成常驻扫描进程。
- 复杂权限沙盒化发布流程。
- Cursor、Cline、Gemini CLI、Continue 等未确认本机格式的 adapter。

后续 agent 接入必须通过同一 SourceAdapter 协议扩展，不能为单个 agent 在 UI 或数据库里写特殊通道。

## 架构

推荐架构：Swift 常驻 app + Electron 按需主界面 + 共享 SQLite + 本机 IPC 控制面。

```mermaid
flowchart LR
  Swift[Swift Menu Bar App] -->|单写扫描事实表| DB[(TokenMeter SQLite)]
  Swift -->|读菜单栏摘要| DB
  ElectronMain[Electron Main] -->|读图表/写设置| DB
  Renderer[React Renderer] -->|preload 白名单 API| ElectronMain
  ElectronMain -->|settingsChanged(version)| Swift
  Swift -->|settingsApplied / scanStatus| ElectronMain
```

### Swift 常驻层职责

Swift 是后台事实写入者和菜单栏体验所有者：

- 创建和维护菜单栏 `NSStatusItem`。
- 保留现有原生轻量浮窗，用于快速摘要、错误提示和打开主界面。
- 执行 provider quota 刷新。
- 执行本地 agent session 扫描。
- 写入 SQLite 事实表：source files、projects、sessions、usage、daily rollups、summary、scan runs。
- 读取 SQLite settings 并热应用：
  - provider 启停。
  - agent 可见性。
  - 扫描 root。
  - 刷新频率。
  - 菜单栏 primary provider 和 summary mode。
- 向 Electron 回传设置应用结果和扫描状态。

Swift 不负责大型图表、复杂筛选器、设置表单或导入日志详情。

### Electron 主界面职责

Electron 是按需打开的控制台和分析界面：

- 展示 Dashboard、Sessions、Index Status、Settings。
- 查询 SQLite 中的会话 usage、聚合统计和扫描状态。
- 修改设置表：provider 接入、agent 可见性、扫描根目录、刷新策略、菜单栏展示偏好。
- 通过本机 IPC 通知 Swift 设置已变更。
- 接收 Swift 的 `settingsApplied`、`scanStatusChanged` 事件。

Electron main 是本地能力网关。React renderer 只能通过 preload 暴露的白名单 API 和 Electron main 通信。

### Renderer 安全边界

Electron renderer 禁止：

- `nodeIntegration`。
- 直接 `require('fs')`。
- 直接打开 SQLite 连接。
- 直接访问 Keychain。
- 直接读取任意本地文件。

preload 只暴露最小 API：

```ts
type TokenMeterAPI = {
  settings: {
    get(): Promise<SettingsSnapshot>
    update(patch: SettingsPatch, expectedVersion: number): Promise<SettingsApplyRequest>
    subscribe(listener: (event: SettingsEvent) => void): Unsubscribe
  }
  dashboard: {
    queryOverview(filter: OverviewFilter): Promise<OverviewData>
    queryDailyUsage(filter: UsageFilter): Promise<DailyUsagePoint[]>
  }
  sessions: {
    query(filter: SessionFilter): Promise<SessionPage>
    get(id: string): Promise<SessionDetail>
  }
  index: {
    status(): Promise<IndexStatus>
    startFullReindex(rootId?: string): Promise<ScanRunSummary>
    subscribe(listener: (event: ScanEvent) => void): Unsubscribe
  }
  shell: {
    openMenuBarPreferences(): Promise<void>
  }
}
```

这些 API 只能返回元数据、usage、状态和设置，不返回消息正文。

## 技术选择

### 主界面

采用 Electron + React。

理由：

- Electron 适合承载复杂表格、图表、设置页和本地桌面控制台。
- React 对外部 store 订阅有成熟模式，可用 `useSyncExternalStore` 封装 Electron IPC-backed state。
- Electron 只按需打开，Swift 仍是常驻进程，避免把菜单栏常驻体验绑定到 Chromium。

不选择 Taro UI 作为本阶段主路径，因为本阶段的宿主是 macOS 桌面控制台。Taro 可在后续需要多端复用时再评估，但它仍需要 Electron、WebView 或其他桌面宿主承载。

### SQLite

SQLite 是共享事实源和增量索引库。

必须启用：

```sql
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA foreign_keys = ON;
PRAGMA temp_store = MEMORY;
PRAGMA busy_timeout = 5000;
```

原因：

- Swift 后台写入时，Electron 需要并发读取。
- 本地缓存库可接受 `synchronous=NORMAL` 的性能取舍。
- 所有关系必须有外键和约束，避免扫描失败留下孤儿数据。
- 查询需要通过索引和物化汇总支撑菜单栏低延迟与 Electron 图表首屏。

## 设置同步

设置的持久真源是 SQLite，不再以 JSON 配置文件作为运行时真源。现有 JSON 配置保留为导入、导出和调试兼容格式。

### 实时更新流程

Electron 修改设置后：

1. React renderer 提交设置 patch。
2. preload 转发给 Electron main。
3. Electron main 校验 patch 和 `expectedVersion`。
4. Electron main 在事务中写 SQLite settings 表，并递增 `settings.version`。
5. Electron main 通过本机 IPC 通知 Swift：`settingsChanged(version)`。
6. Swift 读取完整 settings snapshot。
7. Swift 比对差异并热应用：
   - provider 接入变化：重建 provider registry。
   - agent 可见性变化：重算菜单栏摘要查询并更新扫描过滤。
   - 扫描根目录变化：更新文件观察器和 scan roots。
   - 刷新频率变化：重置 timer 和 refresh gate。
   - primary provider 变化：立即刷新菜单栏标题。
8. Swift 写入 `settings_applied_version`。
9. Swift 通过 IPC 回传 `settingsApplied(version)` 或结构化错误。
10. Electron UI 显示“已应用”、“应用失败”或“需要重扫”。

Swift 同时轻量轮询或监听 `settings.updated_at` / `settings.version`，防止 IPC 丢包或 Electron 异常退出。

### IPC 选择

近期落地建议：SQLite + Unix domain socket 或 loopback HTTP + settings version 兜底。

长期最佳方案：SQLite + XPC + settings version 兜底。

自定义 URL scheme 只用于打开主界面特定页面，例如从菜单栏打开 Settings 或 Session Detail，不承担设置同步。

## SQLite schema

本阶段使用一个本地数据库，例如：

```text
~/.token-meter/tokenmeter.sqlite
```

### schema 版本

```sql
CREATE TABLE schema_migrations (
  version INTEGER PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
```

同时使用 `PRAGMA user_version` 做快速版本判断。

### 设置表

```sql
CREATE TABLE settings (
  key TEXT PRIMARY KEY,
  value_json TEXT NOT NULL,
  value_type TEXT NOT NULL CHECK (value_type IN ('string', 'int', 'bool', 'json')),
  version INTEGER NOT NULL,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_by TEXT NOT NULL CHECK (updated_by IN ('swift', 'electron', 'migrator', 'importer'))
);
```

关键设置：

- `menuBar.primaryProviderId`
- `menuBar.summaryMode`
- `scan.autoRefreshSeconds`
- `filters.enabledAgentKinds`
- `ui.chartWindow`
- `settings.appliedVersion`

### provider 覆盖设置

```sql
CREATE TABLE provider_config_overrides (
  provider_id TEXT PRIMARY KEY,
  enabled INTEGER CHECK (enabled IN (0,1)),
  display_name TEXT,
  menu_rank INTEGER,
  show_in_menu_bar INTEGER CHECK (show_in_menu_bar IN (0,1)),
  show_in_charts INTEGER CHECK (show_in_charts IN (0,1)),
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
```

凭据不进 SQLite。SQLite 只存 credential reference，例如环境变量名、Keychain item id 或文件 alias。

### 扫描根目录

```sql
CREATE TABLE scan_roots (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('claude_jsonl', 'codex_jsonl', 'omp_jsonl', 'opencode_sqlite')),
  root_path TEXT NOT NULL,
  display_name TEXT NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0,1)),
  scan_mode TEXT NOT NULL DEFAULT 'incremental' CHECK (scan_mode IN ('incremental', 'full', 'disabled')),
  file_glob TEXT,
  source_db_path TEXT,
  stable_source_key TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_scan_started_at TEXT,
  last_scan_finished_at TEXT,
  last_successful_cursor TEXT,
  last_error TEXT,
  UNIQUE(kind, root_path),
  UNIQUE(stable_source_key)
);
```

默认 roots：

- Claude Code：`~/.claude/projects`
- Codex：`~/.codex/sessions`
- OpenCode：`~/.local/share/opencode/opencode.db`
- OMP：`~/.omp/agent/sessions`

### source 文件状态

```sql
CREATE TABLE source_files (
  id INTEGER PRIMARY KEY,
  scan_root_id INTEGER NOT NULL REFERENCES scan_roots(id) ON DELETE CASCADE,
  relative_path TEXT NOT NULL,
  canonical_path TEXT NOT NULL,
  file_type TEXT NOT NULL CHECK (file_type IN ('jsonl_session', 'sqlite_db')),
  size_bytes INTEGER NOT NULL,
  mtime_ns INTEGER NOT NULL,
  inode INTEGER,
  dev INTEGER,
  content_fingerprint TEXT,
  parser_state TEXT,
  first_seen_run_id INTEGER REFERENCES scan_runs(id) ON DELETE SET NULL,
  last_seen_run_id INTEGER REFERENCES scan_runs(id) ON DELETE SET NULL,
  last_parsed_run_id INTEGER REFERENCES scan_runs(id) ON DELETE SET NULL,
  disappeared_at TEXT,
  parse_status TEXT NOT NULL DEFAULT 'pending' CHECK (parse_status IN ('pending', 'ok', 'partial', 'failed')),
  parse_error TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(scan_root_id, relative_path),
  UNIQUE(scan_root_id, canonical_path)
);
```

### projects

```sql
CREATE TABLE projects (
  id INTEGER PRIMARY KEY,
  project_key TEXT NOT NULL UNIQUE,
  canonical_path TEXT NOT NULL,
  display_name TEXT NOT NULL,
  first_seen_at TEXT NOT NULL,
  last_seen_at TEXT NOT NULL
);
```

### agent sessions

```sql
CREATE TABLE agent_sessions (
  id INTEGER PRIMARY KEY,
  source_kind TEXT NOT NULL,
  source_session_key TEXT NOT NULL,
  scan_root_id INTEGER NOT NULL REFERENCES scan_roots(id) ON DELETE CASCADE,
  source_file_id INTEGER REFERENCES source_files(id) ON DELETE SET NULL,
  project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL,
  provider_id TEXT,
  agent_name TEXT,
  model_provider TEXT,
  model_name TEXT,
  cli_version TEXT,
  session_started_at TEXT,
  session_updated_at TEXT,
  session_closed_at TEXT,
  cwd_path TEXT,
  worktree_path TEXT,
  title TEXT,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'closed', 'deleted', 'orphaned')),
  message_count INTEGER,
  event_count INTEGER,
  total_cost_usd_micros INTEGER,
  source_revision TEXT NOT NULL,
  first_seen_run_id INTEGER REFERENCES scan_runs(id) ON DELETE SET NULL,
  last_seen_run_id INTEGER REFERENCES scan_runs(id) ON DELETE SET NULL,
  last_indexed_run_id INTEGER REFERENCES scan_runs(id) ON DELETE SET NULL,
  deleted_at TEXT,
  raw_meta_json TEXT,
  UNIQUE(source_kind, source_session_key)
);
```

`raw_meta_json` 只能存白名单元数据。禁止存储 message content、tool output、reasoning 或 credential。

### session usage

```sql
CREATE TABLE session_usage (
  id INTEGER PRIMARY KEY,
  session_id INTEGER NOT NULL REFERENCES agent_sessions(id) ON DELETE CASCADE,
  observed_at TEXT NOT NULL,
  usage_seq INTEGER NOT NULL,
  metric_scope TEXT NOT NULL DEFAULT 'session' CHECK (metric_scope IN ('session', 'window', 'total')),
  window_label TEXT,
  tokens_input INTEGER,
  tokens_output INTEGER,
  tokens_reasoning INTEGER,
  tokens_cache_read INTEGER,
  tokens_cache_write INTEGER,
  tokens_total INTEGER GENERATED ALWAYS AS (
    coalesce(tokens_input,0) +
    coalesce(tokens_output,0) +
    coalesce(tokens_reasoning,0) +
    coalesce(tokens_cache_read,0) +
    coalesce(tokens_cache_write,0)
  ) VIRTUAL,
  cost_usd_micros INTEGER,
  source_event_id TEXT,
  source_offset INTEGER,
  source_hash TEXT,
  is_cumulative INTEGER NOT NULL DEFAULT 1 CHECK (is_cumulative IN (0,1)),
  UNIQUE(session_id, usage_seq),
  UNIQUE(session_id, source_event_id),
  UNIQUE(session_id, source_offset)
);
```

### latest usage

```sql
CREATE TABLE session_usage_latest (
  session_id INTEGER PRIMARY KEY REFERENCES agent_sessions(id) ON DELETE CASCADE,
  session_usage_id INTEGER NOT NULL UNIQUE REFERENCES session_usage(id) ON DELETE CASCADE,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
```

该表服务菜单栏与 Electron 首屏，避免每次从历史 usage 表排序聚合。

### daily rollup

```sql
CREATE TABLE provider_daily_usage (
  usage_date TEXT NOT NULL,
  provider_id TEXT NOT NULL,
  project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL,
  source_kind TEXT NOT NULL,
  sessions_count INTEGER NOT NULL,
  tokens_input INTEGER NOT NULL DEFAULT 0,
  tokens_output INTEGER NOT NULL DEFAULT 0,
  tokens_reasoning INTEGER NOT NULL DEFAULT 0,
  tokens_cache_read INTEGER NOT NULL DEFAULT 0,
  tokens_cache_write INTEGER NOT NULL DEFAULT 0,
  total_cost_usd_micros INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (usage_date, provider_id, project_id, source_kind)
);
```

### scan runs

```sql
CREATE TABLE scan_runs (
  id INTEGER PRIMARY KEY,
  scan_root_id INTEGER REFERENCES scan_roots(id) ON DELETE CASCADE,
  run_kind TEXT NOT NULL CHECK (run_kind IN ('discover', 'incremental', 'full', 'repair')),
  started_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  finished_at TEXT,
  status TEXT NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'ok', 'partial', 'failed')),
  files_seen INTEGER NOT NULL DEFAULT 0,
  files_changed INTEGER NOT NULL DEFAULT 0,
  files_deleted INTEGER NOT NULL DEFAULT 0,
  sessions_added INTEGER NOT NULL DEFAULT 0,
  sessions_updated INTEGER NOT NULL DEFAULT 0,
  sessions_deleted INTEGER NOT NULL DEFAULT 0,
  usage_rows_added INTEGER NOT NULL DEFAULT 0,
  bytes_read INTEGER NOT NULL DEFAULT 0,
  cursor_before TEXT,
  cursor_after TEXT,
  error_summary TEXT
);
```

### 索引

```sql
CREATE INDEX idx_source_files_active
ON source_files(scan_root_id, disappeared_at, mtime_ns, size_bytes);

CREATE INDEX idx_source_files_inode
ON source_files(scan_root_id, dev, inode)
WHERE inode IS NOT NULL;

CREATE INDEX idx_sessions_project_updated
ON agent_sessions(project_id, session_updated_at DESC);

CREATE INDEX idx_sessions_provider_updated
ON agent_sessions(provider_id, session_updated_at DESC);

CREATE INDEX idx_sessions_source_file
ON agent_sessions(source_file_id);

CREATE INDEX idx_sessions_status_updated
ON agent_sessions(status, session_updated_at DESC);

CREATE INDEX idx_usage_session_observed
ON session_usage(session_id, observed_at DESC);

CREATE INDEX idx_daily_provider_date
ON provider_daily_usage(provider_id, usage_date DESC);

CREATE INDEX idx_daily_project_provider_date
ON provider_daily_usage(project_id, provider_id, usage_date DESC);

CREATE INDEX idx_settings_updated
ON settings(updated_at DESC);
```

## 数据源覆盖

### Claude Code

路径：

```text
~/.claude/projects/**/*.jsonl
```

提取字段：

- session id
- cwd / project path
- timestamp
- model（若源文件有结构化字段）
- cli version（若源文件有结构化字段）
- token usage 字段

风险：Claude Code JSONL 中混有正文、工具结果和内部事件。parser 必须字段白名单抽取，不可保存正文。

### Codex

路径：

```text
~/.codex/sessions/YYYY/MM/DD/*.jsonl
```

提取字段：

- `session_meta` 中的 session id、timestamp、cwd。
- `turn_context` 中的 cwd、model。
- `event_msg` / `token_count` 中的 usage。

聚合规则：优先使用最新 cumulative total。若同时存在 last delta 和 total，total 是展示真源，delta 只用于校验或追加判断。

### OpenCode

路径：

```text
~/.local/share/opencode/opencode.db
```

核心字段：

- `session.id`
- `session.directory`
- `session.time_created`
- `session.time_updated`
- `session.model`
- `session.agent`
- `session.cost`
- `session.tokens_input`
- `session.tokens_output`
- `session.tokens_reasoning`
- `session.tokens_cache_read`
- `session.tokens_cache_write`

增量策略：观察 `opencode.db` 和 `opencode.db-wal`，用 `session.time_updated` 和 `event.seq/id` 高水位找受影响 session，只重算受影响 session。

### OMP

路径：

```text
~/.omp/agent/sessions/**/*.jsonl
```

补充源：

```text
~/.omp/agent/agent.db
~/.omp/agent/history.db
```

JSONL 提取：

- session id
- cwd
- timestamp
- model change
- assistant usage 元数据

SQLite 补充库只用于运行统计、模型使用和历史索引，不作为消息正文来源。

## 增量扫描算法

### JSONL 文件源

每个 source file 保存：

- canonical path
- relative path
- inode
- dev
- size bytes
- mtime ns
- content fingerprint
- parser state
- tail hash
- last offset
- last complete line number
- last usage seq

判定规则：

1. 未变：inode/dev、size、mtime 都相同，跳过。
2. 追加：同 inode，size 增长，tail hash 匹配，从 last offset 续扫。
3. 重写：size 变小或 tail hash 不匹配，对单 session 替换式重建。
4. 移动：inode/dev 相同但路径变化，只更新路径，不创建重复 session。
5. 删除：本轮未见先标记 `disappeared_at`，连续缺失后标记 session deleted。
6. 复制：inode 不同但 session id 和首事件时间相同，按同一 session 去重。

大文件处理：

- 禁止一次性读入内存。
- 必须按字节流或行流解析。
- 尾部半截 JSON 行保留到下一轮。
- 每个 session 可以分批提交事务，避免单次扫描持有超长写事务。

### SQLite 源

每个 SQLite 源保存：

- db path
- db mtime ns
- wal mtime ns
- max session updated at
- max event id / seq
- last successful cursor

扫描流程：

1. 检查 db 与 wal 文件是否变化。
2. 未变则跳过。
3. 变化后按高水位拉取 session/event。
4. 得到受影响 session 集合。
5. 只重算受影响 session。
6. 若发现 event 高水位不单调或 schema 变化，标记 partial 并进入 repair scan。

### 解析器升级

parser 版本变化时，受影响 source root 进入 repair scan。

repair scan 不清空整库，而是按 session 替换式重建：删除该 session 的 usage 历史，重写 session 和 latest usage，更新 source revision。

## 查询模式

### 菜单栏摘要查询

菜单栏读取 `session_usage_latest` 与设置表，不跑大聚合。

```sql
WITH chosen_provider AS (
  SELECT json_extract(value_json, '$') AS provider_id
  FROM settings
  WHERE key = 'menuBar.primaryProviderId'
)
SELECT s.provider_id, s.model_name, u.tokens_total, s.session_updated_at
FROM chosen_provider cp
JOIN agent_sessions s ON s.provider_id = cp.provider_id AND s.status = 'active'
JOIN session_usage_latest ul ON ul.session_id = s.id
JOIN session_usage u ON u.id = ul.session_usage_id
ORDER BY s.session_updated_at DESC
LIMIT 1;
```

### Electron 图表查询

Electron 图表优先查 `provider_daily_usage`。

```sql
SELECT usage_date, provider_id,
       tokens_input, tokens_output, tokens_reasoning,
       tokens_cache_read, tokens_cache_write,
       total_cost_usd_micros
FROM provider_daily_usage
WHERE usage_date BETWEEN ? AND ?
  AND (? IS NULL OR provider_id = ?)
  AND (? IS NULL OR project_id = ?)
ORDER BY usage_date ASC;
```

### Sessions 明细查询

```sql
SELECT s.id, p.display_name, s.provider_id, s.agent_name, s.model_name,
       s.cwd_path, s.session_started_at, s.session_updated_at,
       u.tokens_total, u.cost_usd_micros
FROM agent_sessions s
LEFT JOIN projects p ON p.id = s.project_id
LEFT JOIN session_usage_latest ul ON ul.session_id = s.id
LEFT JOIN session_usage u ON u.id = ul.session_usage_id
WHERE (? IS NULL OR s.project_id = ?)
  AND (? IS NULL OR s.provider_id = ?)
  AND (? IS NULL OR s.agent_name = ?)
  AND s.status != 'deleted'
ORDER BY s.session_updated_at DESC
LIMIT ? OFFSET ?;
```

## UI 信息架构

### Swift 菜单栏

菜单栏继续克制，保留原生体验：

- 菜单栏标题显示主 provider 或主 agent 摘要。
- 浮窗展示：
  - 顶部状态。
  - provider quota 摘要。
  - 本地会话索引摘要。
  - 最近扫描时间。
  - 简短错误提示。
  - 打开详细界面按钮。

不在菜单栏浮窗里放：

- 历史折线图。
- 大型 session 表格。
- provider 接入表单。
- 扫描 root 管理。
- 大型导入日志。

### Electron 主界面

Electron 主界面四个一级区域：

1. Dashboard
   - provider quota 总览。
   - 今日、近 7 天、近 30 天 token usage。
   - agent 分布。
   - 模型分布。
   - 异常扫描源和告警。

2. Sessions
   - 按 agent、provider、project、model、date 过滤。
   - session usage 明细。
   - 主会话与子代理会话层级。
   - 不展示正文。

3. Index Status
   - scan roots。
   - 增量扫描进度。
   - 最近 scan runs。
   - 失败文件计数和错误分类。
   - 手动 repair scan / full reindex 入口。

4. Settings
   - provider 接入。
   - agent 可见性。
   - scan roots。
   - refresh intervals。
   - menu bar preferences。
   - data privacy 说明。

## 视觉方向

Electron 主界面是“本地使用仪表盘”，不是营销后台。设计应偏产品工具：信息密度高、层级清晰、图表克制。

场景句：用户在开发间隙打开主界面，想快速知道哪些 agent、项目和模型消耗了 token，并调整菜单栏与扫描设置。

视觉策略：

- 主界面采用 restrained product UI。
- 背景使用轻微冷调系统中性色，避免纯黑纯白。
- 数据图表使用少量稳定语义色：正常、警告、异常、选中。
- 表格和图表优先清晰，不用装饰性 glassmorphism。
- 数字使用等宽字体，便于 token 和成本扫描。
- 图表默认展示聚合趋势，点击后下钻到 session。

## 隐私与安全

硬约束：索引库不保存正文。

允许保存：

- session id
- source kind
- project path
- timestamps
- model/provider/version
- token usage
- cost
- scan status
- parser version

禁止保存：

- prompt text
- assistant response text
- reasoning content
- tool output
- attachments content
- credentials
- cookies
- raw API keys

错误日志也不能输出正文片段或凭据。

## 失败与空状态

- 没找到某个默认目录：显示“未找到本地会话目录”，不报错。
- 单个文件解析失败：scan run 标 partial，其他文件继续。
- SQLite 源锁定：等待 busy timeout，失败后标 partial，下轮重试。
- parser 版本不兼容：要求 repair scan。
- 设置已保存但 Swift 未应用：Electron 显示“待应用”或“应用失败”，不能只显示保存成功。

## 性能要求

- 重复扫描未变文件时，不读取文件正文。
- 大 JSONL 文件必须流式处理。
- 单次扫描事务不能覆盖整个 root 的长时间解析过程。
- 菜单栏摘要查询必须使用 latest / materialized summary，不跑大范围 group by。
- Electron 图表默认查 daily rollup，不触发原始文件扫描。
- OpenCode SQLite 不全库重扫，用 high-water mark 找受影响 session。

## 测试策略

实现必须测试先行。

核心测试：

- schema migration 创建所有表、约束和索引。
- settings 写入版本递增，冲突版本会拒绝。
- Electron 设置变更能被 Swift 设置 reader 识别。
- JSONL 文件未变时 scanner 跳过。
- JSONL 文件追加时 scanner 从 offset 续扫。
- JSONL 文件截断/重写时触发单 session 重建。
- 大 JSONL 用流式 reader，测试不一次性读入完整文件。
- Codex parser 从 `session_meta`、`turn_context`、`token_count` 提取 usage。
- Claude Code parser 只抽取 usage 白名单字段，不保存正文。
- OMP parser 只抽取 session/model/usage 元数据，不保存正文。
- OpenCode adapter 按 `time_updated` / event high-water mark 做增量。
- `session_usage_latest` 更新正确。
- `provider_daily_usage` rollup 正确。
- 菜单栏摘要查询在空库、错误库、正常库下都有确定结果。

## 迁移策略

现有 `~/.token-meter/config.json` 作为导入源：

- 首次启动第二阶段版本时，读取 JSON 配置。
- 写入 SQLite `settings` 与 `provider_config_overrides`。
- 保留 JSON 文件，不删除。
- 后续运行时以 SQLite 为真源。
- 提供导出 JSON 的调试能力。

现有 `~/.token-meter/cache/provider-snapshots.json` 只作为旧版本回退数据。第二阶段缓存迁移到 SQLite summary 表。

## 验收标准

第二阶段完成时必须满足：

- `swift test` 通过。
- `swift build` 通过。
- Electron 主界面能打开 Dashboard、Sessions、Index Status、Settings。
- Swift 菜单栏在 Electron 关闭时仍能独立常驻、刷新、扫描和显示摘要。
- Electron 修改 primary provider 后，Swift 菜单栏秒级更新。
- Electron 启停某个 agent 后，Swift 扫描和菜单栏摘要按新设置工作。
- Electron 修改扫描根目录后，Swift 无需重启即可更新扫描范围。
- 重复扫描未变 JSONL 文件不会重读。
- 大 JSONL session 能完整记录，不一次性加载进内存。
- OpenCode SQLite 用高水位增量，不每次全库重扫。
- Electron 图表查询 SQLite rollup，不触发原始文件扫描。
- 索引库不包含消息正文、tool output、reasoning 或凭据。
- 单个数据源失败不影响其他数据源。
- 失败状态在 Electron Index Status 和菜单栏轻量状态中可见。

## 后续扩展

第二阶段之后可继续扩展：

- Cursor / Cline / Gemini CLI / Continue adapters。
- 更细粒度成本计算。
- 项目级预算和告警。
- 模型维度趋势。
- 手动数据导出。
- XPC 替换近期 socket IPC。
- Web 控制台更复杂的可视化和 drill-down。
