# Phase 2A：概览页 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付一个能用的概览页——KPI 行、用量趋势堆叠柱状图、年度活动热力图、模型排行、右侧会话列表，带自动刷新与响应式。

**Architecture:** 垂直切片。每个任务都往「能看见的界面」推进一步，而不是先堆一层查询再堆一层组件。数据契约先于组件定型：repository 返回什么，组件就画什么，两者由类型和测试钉死。所有聚合在 SQL 里完成，renderer 只接 KB 级的结果。

**Tech Stack:** better-sqlite3（主进程只读查询）、React 19、手写 SVG 图表（不引图表库，见 spec §7.6）、vitest + @testing-library/react。

---

## 前置事实（已核实，不要重新假设）

- `daily_rollup` 有全部五个 token 列（`tokens_input` / `tokens_output` / `tokens_cache_read` / `tokens_cache_write_5m` / `tokens_cache_write_1h`）、`cost_usd_micros`、`cost_unknown_events`、`sessions_count`、`events_count`、`model_canonical`、`project_id`、`provider_id`、`usage_date`（**本地日期**）。
- **`daily_rollup.sessions_count` 不可跨行相加**（spec §4.2）。同一会话跨天或换模型会占多行。任何「总会话数」走 `session_rollup` 的 `count(*)`，或 `usage_events` 的 `count(distinct session_id)`。
- **小时粒度不查 `daily_rollup`**，它只有天。走 `usage_events` + `strftime('%Y-%m-%d %H', observed_epoch_ms/1000, 'unixepoch', 'localtime')`（spec §4.2：单日几百条明细，带索引聚合即可）。
- **成本的「未知」在写入 rollup 时就被抹平了。** `usage_events.cost_usd_micros` 可为 NULL（模型无定价），但 `daily_rollup.cost_usd_micros` 是 `NOT NULL DEFAULT 0`、`session_rollup.cost_usd_micros` 是 `NOT NULL`——`RollupBuilder` 把 NULL 折成了 0。

  所以 UI 从 rollup 读到的成本**永远是个数字**，看不出它是否完整。`cost_unknown_events` 是**唯一**能区分「这个模型免费」和「我们不知道这个模型多少钱」的信号。本机实测有 **9,603** 条这样的事件。

  一个显示 `$32,320.81` 却不提「其中 9,603 条事件的价格未知」的界面，是在用精确的小数点撒谎。**每一处展示成本的地方，都要同时能表达「部分未知」。**
- 现有 renderer 只有 530 行，`TokenTrendChart.tsx` 是 7 行占位。路由是 `useState<RouteName>`，**没有 URL query**。
- Electron 依赖里没有图表库，也没有 router。本计划不引入任何新的运行时依赖。

---

## File Structure

**主进程（查询）**

| 文件 | 职责 |
|---|---|
| `Electron/src/main/overviewRepository.ts` | 概览页的全部查询：KPI、最近活动、趋势、热力图、模型排行、会话列表 |
| `Electron/src/main/granularity.ts` | 粒度与范围的联动约束（纯函数，与 SQL 无关） |

**Renderer（组件）**

| 文件 | 职责 |
|---|---|
| `Electron/src/renderer/charts/scale.ts` | 对数色阶、Y 轴 nice ticks（纯函数） |
| `Electron/src/renderer/charts/stackedBarLayout.ts` | 堆叠柱状图的布局计算（纯函数，不含 JSX） |
| `Electron/src/renderer/charts/StackedBarChart.tsx` | SVG 堆叠柱状图 + tooltip + ResizeObserver |
| `Electron/src/renderer/charts/YearHeatmap.tsx` | 53×7 DOM 热力图 + tooltip + click |
| `Electron/src/renderer/charts/BarRanking.tsx` | 横条排行（纯 div） |
| `Electron/src/renderer/components/KpiCard.tsx` | KPI 卡 |
| `Electron/src/renderer/components/ActivityCard.tsx` | 「最近活动」卡（spec §7.2.1） |
| `Electron/src/renderer/components/SessionRail.tsx` | 右侧会话列表；窄屏时由浮层承载 |
| `Electron/src/renderer/routes/Overview.tsx` | 概览页组装 |
| `Electron/src/renderer/hooks/useAutoRefresh.ts` | 自动刷新（事件驱动 + 轮询兜底 + 窗口隐藏暂停） |

**布局计算与绘制分离**是刻意的：`stackedBarLayout.ts` 和 `scale.ts` 是纯函数，可以直接单测；`.tsx` 只负责把算好的坐标变成元素。图表的 bug 几乎都在算坐标，而不是在画矩形。

---

## Task 1: 粒度与范围的联动约束

范围越长、粒度越细，柱子越多。1180px 窗口下主区约 840px，画不下 720 根柱子。与其产出一张读不了的图，不如禁掉该组合（spec §7.2）。

这是纯函数，与数据库无关，先做——后面每个查询都要用它校验入参。

**Files:**
- Create: `Electron/src/main/granularity.ts`
- Test: `Electron/src/main/granularity.test.ts`

- [ ] **Step 1: 写失败的测试**

```typescript
import { describe, it, expect } from 'vitest';
import { allowedGranularities, isAllowed, barCount, type Granularity } from './granularity.js';

describe('allowedGranularities', () => {
  it('opens hour only for ranges of at most 2 days', () => {
    expect(allowedGranularities('2026-07-09', '2026-07-10')).toContain('hour');
    expect(allowedGranularities('2026-07-08', '2026-07-10')).not.toContain('hour');
  });

  it('opens month only for ranges of at least 90 days', () => {
    expect(allowedGranularities('2026-04-11', '2026-07-10')).toContain('month');
    expect(allowedGranularities('2026-04-12', '2026-07-10')).not.toContain('month');
  });

  it('drops day once it would exceed the readable bar ceiling', () => {
    expect(allowedGranularities('2026-07-10', '2026-07-10')).toContain('day');
    expect(allowedGranularities('2020-01-01', '2026-07-10')).not.toContain('day');  // 2383 根柱子
  });

  it('always offers at least one granularity, however wide the range', () => {
    // 这条与 barCount 的上限测试互为约束：任何范围都得有一个能画的粒度，
    // 且每个被放行的粒度都得画得下。两条一起把「约束表」钉死。
    for (const [from, to] of [['2026-07-10','2026-07-10'], ['2026-07-08','2026-07-10'],
                              ['2026-06-11','2026-07-10'], ['2020-01-01','2026-07-10']] as const) {
      expect(allowedGranularities(from, to).length).toBeGreaterThan(0);
    }
  });

  it('rejects an inverted range rather than silently swapping it', () => {
    expect(() => allowedGranularities('2026-07-10', '2026-07-09')).toThrow(/from.*after.*to/i);
  });
});

describe('barCount', () => {
  it('counts inclusive days', () => {
    expect(barCount('2026-07-10', '2026-07-10', 'day')).toBe(1);
    expect(barCount('2026-07-08', '2026-07-10', 'day')).toBe(3);
  });

  it('counts hours across a 2-day span', () => {
    expect(barCount('2026-07-09', '2026-07-10', 'hour')).toBe(48);
  });

  it('never exceeds the readable ceiling for an allowed combination', () => {
    // 任何被 allowedGranularities 放行的组合，柱子数都必须画得下。
    // 这条把「约束表」与「可读性上限」绑在一起：改了任何一个，另一个会红。
    const ranges: Array<[string, string]> = [
      ['2026-07-09', '2026-07-10'],  // 2 天
      ['2026-06-11', '2026-07-10'],  // 30 天
      ['2026-04-11', '2026-07-10'],  // 91 天
      ['2020-01-01', '2026-07-10']   // 多年
    ];
    for (const [from, to] of ranges) {
      for (const g of allowedGranularities(from, to)) {
        expect(barCount(from, to, g)).toBeLessThanOrEqual(120);
      }
    }
  });
});

describe('isAllowed', () => {
  it('rejects hour over a 30-day range', () => {
    expect(isAllowed('2026-06-11', '2026-07-10', 'hour')).toBe(false);
  });
});
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd Electron && npx vitest run src/main/granularity.test.ts`
Expected: FAIL，`Failed to resolve import "./granularity.js"`

- [ ] **Step 3: 实现**

`Electron/src/main/granularity.ts`：

```typescript
export type Granularity = 'hour' | 'day' | 'week' | 'month';

const DAY_MS = 86_400_000;

/// 一屏能读的柱子上限。1180px 窗口下主区约 840px，120 根柱子已是每根 7px。
/// barCount 的测试把这个数与 allowedGranularities 绑在一起。
export const MAX_BARS = 120;

function parseDay(iso: string): number {
  const ms = Date.parse(`${iso}T00:00:00Z`);
  if (Number.isNaN(ms)) throw new Error(`invalid date: ${iso}`);
  return ms;
}

/// 含首尾的天数：7-08..7-10 是 3 天，不是 2 天。
export function inclusiveDays(from: string, to: string): number {
  const a = parseDay(from);
  const b = parseDay(to);
  if (a > b) throw new Error(`from (${from}) is after to (${to})`);
  return Math.round((b - a) / DAY_MS) + 1;
}

/// 每个粒度的开放条件，都由「柱子数 ≤ MAX_BARS」推导，而不是拍脑袋定的：
///   hour  : days ≤ 2    → ≤ 48 根
///   day   : days ≤ 120  → ≤ 120 根
///   week  : days ≤ 840  → ≤ 120 根；下限 7 天，否则只有 1 根柱子
///   month : days ≥ 91   → ≥ 3 根柱子，少于 3 个点的趋势没有意义；上限交给 MAX_BARS 兜底
///           （`days` 是 inclusiveDays，含首尾。「至少 90 天跨度」= inclusiveDays ≥ 91。
///            写成 `>= 90` 会让 04-12..07-10 这个 90 天的范围也开放月粒度，与测试相悖。）
///
/// 上限与下限必须让任意范围至少剩一个粒度，否则用户会看到一个空的粒度选择器。
/// `always offers at least one granularity` 与 `barCount ≤ MAX_BARS` 两条测试
/// 从两侧把这张表夹死：放宽任何一条，另一条就红。
export function allowedGranularities(from: string, to: string): Granularity[] {
  const days = inclusiveDays(from, to);
  const out: Granularity[] = [];
  if (days <= 2) out.push('hour');
  if (days <= MAX_BARS) out.push('day');
  if (days >= 7 && Math.ceil(days / 7) <= MAX_BARS) out.push('week');
  if (days >= 91) out.push('month');
  return out;
}

export function isAllowed(from: string, to: string, g: Granularity): boolean {
  return allowedGranularities(from, to).includes(g);
}

export function barCount(from: string, to: string, g: Granularity): number {
  const days = inclusiveDays(from, to);
  switch (g) {
    case 'hour': return days * 24;
    case 'day': return days;
    case 'week': return Math.ceil(days / 7);
    case 'month': return Math.ceil(days / 30);
  }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd Electron && npx vitest run src/main/granularity.test.ts`
Expected: `Tests  7 passed`

若 `month` 在极宽的范围上也超过 `MAX_BARS`（约 10 年 = 122 个月），`barCount ≤ MAX_BARS` 会红。那时**不要放宽这条测试**——给 `month` 也加一条上限，并检查是否还有粒度剩下。真到那一步就该引入 `year` 粒度了。

- [ ] **Step 5: 提交**

```bash
git add Electron/src/main/granularity.ts Electron/src/main/granularity.test.ts
git commit -m "feat: constrain chart granularity by range width"
```

---

## Task 2: 概览查询 —— KPI 与最近活动

「最近活动」只陈述磁盘上的事实：哪些会话在多久之前消耗过 token。**不声称判断运行状态**（spec §7.2.1，本机 14 个 agent 进程的实测表明没有可靠的非侵入判据）。

**Files:**
- Create: `Electron/src/main/overviewRepository.ts`
- Test: `Electron/src/main/overviewRepository.test.ts`

- [ ] **Step 1: 写失败的测试**

```typescript
import { describe, it, expect, beforeEach } from 'vitest';
import Database from 'better-sqlite3';
import { OverviewRepository } from './overviewRepository.js';

// 固定「现在」，否则测试会在午夜前后随机变红。
const NOW = Date.parse('2026-07-10T12:00:00+08:00');

let db: Database.Database;

beforeEach(() => {
  db = new Database(':memory:');
  db.exec(`
    CREATE TABLE agent_sessions (
      id INTEGER PRIMARY KEY, source_kind TEXT NOT NULL, source_session_key TEXT NOT NULL,
      scan_root_id INTEGER NOT NULL, project_id INTEGER, provider_id TEXT,
      status TEXT NOT NULL DEFAULT 'active', source_revision TEXT NOT NULL DEFAULT 'r'
    );
    CREATE TABLE projects (id INTEGER PRIMARY KEY, canonical_path TEXT NOT NULL, display_name TEXT NOT NULL,
      project_key TEXT NOT NULL DEFAULT 'k', first_seen_at TEXT NOT NULL DEFAULT '', last_seen_at TEXT NOT NULL DEFAULT '');
    CREATE TABLE session_rollup (
      session_id INTEGER PRIMARY KEY, first_event_epoch_ms INTEGER NOT NULL, last_event_epoch_ms INTEGER NOT NULL,
      events_count INTEGER NOT NULL, tokens_total INTEGER NOT NULL, cost_usd_micros INTEGER,
      cost_unknown_events INTEGER NOT NULL DEFAULT 0, primary_model TEXT
    );
    CREATE TABLE daily_rollup (
      usage_date TEXT NOT NULL, provider_id TEXT NOT NULL, source_kind TEXT NOT NULL, project_id INTEGER,
      model_canonical TEXT NOT NULL, sessions_count INTEGER NOT NULL DEFAULT 0, events_count INTEGER NOT NULL DEFAULT 0,
      tokens_input INTEGER NOT NULL DEFAULT 0, tokens_output INTEGER NOT NULL DEFAULT 0,
      tokens_reasoning INTEGER NOT NULL DEFAULT 0, tokens_cache_read INTEGER NOT NULL DEFAULT 0,
      tokens_cache_write_5m INTEGER NOT NULL DEFAULT 0, tokens_cache_write_1h INTEGER NOT NULL DEFAULT 0,
      cost_usd_micros INTEGER NOT NULL DEFAULT 0, cost_unknown_events INTEGER NOT NULL DEFAULT 0
    );
    -- 唯一性用【单独的索引】表达，不能写成 PRIMARY KEY(..., coalesce(project_id,-1), ...)：
    -- SQLite 禁止在 PRIMARY KEY / UNIQUE 约束里出现表达式。生产 schema 也是这么建的。
    CREATE UNIQUE INDEX idx_daily_rollup_unique ON daily_rollup(
      usage_date, provider_id, source_kind, coalesce(project_id, -1), model_canonical);
  `);
});

function seedSession(id: number, provider: string, project: string, lastEventMsAgo: number, tokens: number) {
  db.prepare(`INSERT OR IGNORE INTO projects(id, canonical_path, display_name) VALUES (?,?,?)`)
    .run(id, `/p/${project}`, project);
  db.prepare(`INSERT INTO agent_sessions(id, source_kind, source_session_key, scan_root_id, project_id, provider_id)
              VALUES (?,?,?,1,?,?)`).run(id, `${provider}_jsonl`, `s${id}`, id, provider);
  const last = NOW - lastEventMsAgo;
  db.prepare(`INSERT INTO session_rollup(session_id, first_event_epoch_ms, last_event_epoch_ms, events_count,
              tokens_total, cost_usd_micros, primary_model) VALUES (?,?,?,?,?,?,?)`)
    .run(id, last - 60_000, last, 3, tokens, 1000, 'claude-fable-5');
}

describe('recentActivity', () => {
  it('orders by last event descending and marks only fresh sessions as live', () => {
    seedSession(1, 'claude-code', 'token-meter', 12_000, 500);      // 12 秒前
    seedSession(2, 'codex', 'health', 13 * 60_000, 300);            // 13 分钟前
    seedSession(3, 'claude-code', 'vainglory', 3 * 3600_000, 100);  // 3 小时前

    const rows = new OverviewRepository(db, () => NOW).recentActivity(5);

    expect(rows.map(r => r.projectName)).toEqual(['token-meter', 'health', 'vainglory']);
    expect(rows.map(r => r.isLive)).toEqual([true, false, false]);
    expect(rows[0].providerId).toBe('claude-code');
    expect(rows[0].msSinceLastEvent).toBe(12_000);
  });

  it('treats exactly 5 minutes as not live', () => {
    // 边界必须钉死，否则「5 分钟内」会在实现里漂成 <= 或 <
    seedSession(1, 'claude-code', 'p', 5 * 60_000, 1);
    expect(new OverviewRepository(db, () => NOW).recentActivity(5)[0].isLive).toBe(false);
  });

  it('returns an empty list rather than throwing when nothing was ever indexed', () => {
    expect(new OverviewRepository(db, () => NOW).recentActivity(5)).toEqual([]);
  });
});

describe('kpis', () => {
  it('sums today from daily_rollup and counts sessions from session_rollup', () => {
    // 同一个会话当天用了两个模型 → daily_rollup 两行；会话数必须是 1，不是 2。
    db.exec(`
      INSERT INTO daily_rollup(usage_date, provider_id, source_kind, project_id, model_canonical,
                               sessions_count, events_count, tokens_input, tokens_output, cost_usd_micros)
      VALUES ('2026-07-10','claude-code','claude_jsonl',NULL,'claude-fable-5', 1, 1, 100, 10, 500),
             ('2026-07-10','claude-code','claude_jsonl',NULL,'claude-opus-4-8', 1, 1, 200, 20, 700),
             ('2026-07-09','claude-code','claude_jsonl',NULL,'claude-fable-5', 1, 1,  50,  5, 100);
    `);
    seedSession(1, 'claude-code', 'p', 1000, 330);

    const k = new OverviewRepository(db, () => NOW).kpis();

    expect(k.todayTokens).toBe(330);        // 100+10+200+20
    expect(k.todayCostUsdMicros).toBe(1200);
    expect(k.todaySessions).toBe(1);        // NOT sum(sessions_count) = 2
    expect(k.yesterdayTokens).toBe(55);
  });

  it('reports unknown-cost events, because a zero cost is indistinguishable from an unknown one', () => {
    // RollupBuilder 已经把 usage_events 里的 NULL 成本 coalesce 成了 0，
    // 所以 rollup 表里的 cost_usd_micros 永远是数字。「这个模型免费」和
    // 「我们不知道这个模型多少钱」在这一列里长得一模一样。
    // cost_unknown_events 是唯一的区分信号——KPI 不暴露它，界面就在用精确的小数点撒谎。
    db.exec(`
      INSERT INTO daily_rollup(usage_date, provider_id, source_kind, project_id, model_canonical,
                               sessions_count, events_count, tokens_input, cost_usd_micros, cost_unknown_events)
      VALUES ('2026-07-10','codex','codex_jsonl',NULL,'gpt-5.5', 1, 5, 100, 0, 5);
    `);
    const k = new OverviewRepository(db, () => NOW).kpis();
    expect(k.todayCostUsdMicros).toBe(0);
    expect(k.todayCostUnknownEvents).toBe(5);
  });
});
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd Electron && npx vitest run src/main/overviewRepository.test.ts`
Expected: FAIL，`Failed to resolve import "./overviewRepository.js"`

- [ ] **Step 3: 实现**

`Electron/src/main/overviewRepository.ts`：

```typescript
import type Database from 'better-sqlite3';

/// 5 分钟内消耗过 token 的会话打实心脉冲点。
///
/// 这【不是】「正在运行」。没有可靠的非侵入方法回答那个问题（spec §7.2.1）：
/// 本机 14 个并发 agent 进程里，进程存在、CPU、子进程数三个信号全无区分度；
/// 网络连接数只对 claude 有效，持有 session 文件只对 codex 有效，且两者都是
/// 实现细节，agent 改版即静默失效。这里只陈述磁盘上的事实。
const LIVE_WINDOW_MS = 5 * 60_000;

export interface ActivityRow {
  sessionId: number;
  providerId: string;
  projectName: string;
  primaryModel: string | null;
  tokensTotal: number;
  msSinceLastEvent: number;
  isLive: boolean;
}

export interface OverviewKpis {
  todayTokens: number;
  yesterdayTokens: number;
  todaySessions: number;
  todayCostUsdMicros: number;
  todayCostUnknownEvents: number;
  monthCostUsdMicros: number;
}

/// `now` 可注入，否则测试会在午夜前后随机变红。
export class OverviewRepository {
  constructor(private readonly db: Database.Database, private readonly now: () => number = Date.now) {}

  private localDate(offsetDays = 0): string {
    const d = new Date(this.now() + offsetDays * 86_400_000);
    const pad = (n: number) => String(n).padStart(2, '0');
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
  }

  recentActivity(limit: number): ActivityRow[] {
    const now = this.now();
    const rows = this.db.prepare(
      `SELECT sr.session_id AS sessionId,
              coalesce(s.provider_id, s.source_kind) AS providerId,
              coalesce(p.display_name, '未知项目') AS projectName,
              sr.primary_model AS primaryModel,
              sr.tokens_total AS tokensTotal,
              sr.last_event_epoch_ms AS lastEventEpochMs
         FROM session_rollup sr
         JOIN agent_sessions s ON s.id = sr.session_id
    LEFT JOIN projects p ON p.id = s.project_id
        WHERE s.status != 'deleted'
     ORDER BY sr.last_event_epoch_ms DESC
        LIMIT ?`
    ).all(limit) as Array<Omit<ActivityRow, 'msSinceLastEvent' | 'isLive'> & { lastEventEpochMs: number }>;

    return rows.map(r => {
      const msSinceLastEvent = now - r.lastEventEpochMs;
      const { lastEventEpochMs, ...rest } = r;
      return { ...rest, msSinceLastEvent, isLive: msSinceLastEvent < LIVE_WINDOW_MS };
    });
  }

  kpis(): OverviewKpis {
    const today = this.localDate(0);
    const yesterday = this.localDate(-1);
    const monthPrefix = today.slice(0, 7);

    const tokensOf = (date: string): number =>
      (this.db.prepare(
        `SELECT coalesce(sum(tokens_input + tokens_output + tokens_cache_read
                             + tokens_cache_write_5m + tokens_cache_write_1h), 0) AS n
           FROM daily_rollup WHERE usage_date = ?`
      ).get(date) as { n: number }).n;

    const todayRow = this.db.prepare(
      `SELECT coalesce(sum(cost_usd_micros), 0) AS cost,
              coalesce(sum(cost_unknown_events), 0) AS unknown
         FROM daily_rollup WHERE usage_date = ?`
    ).get(today) as { cost: number; unknown: number };

    const monthCost = (this.db.prepare(
      `SELECT coalesce(sum(cost_usd_micros), 0) AS n
         FROM daily_rollup WHERE usage_date LIKE ?`
    ).get(`${monthPrefix}-%`) as { n: number }).n;

    // 会话数必须 count(distinct)，绝不能 sum(daily_rollup.sessions_count)：
    // 同一会话当天用了两个模型会占两行（spec §4.2）。
    const dayStart = Date.parse(`${today}T00:00:00`);
    const todaySessions = (this.db.prepare(
      `SELECT count(*) AS n FROM session_rollup WHERE last_event_epoch_ms >= ?`
    ).get(dayStart) as { n: number }).n;

    return {
      todayTokens: tokensOf(today),
      yesterdayTokens: tokensOf(yesterday),
      todaySessions,
      todayCostUsdMicros: todayRow.cost,
      todayCostUnknownEvents: todayRow.unknown,
      monthCostUsdMicros: monthCost
    };
  }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd Electron && npx vitest run src/main/overviewRepository.test.ts`
Expected: `Tests  5 passed`

- [ ] **Step 5: 提交**

```bash
git add Electron/src/main/overviewRepository.ts Electron/src/main/overviewRepository.test.ts
git commit -m "feat: query overview kpis and recent activity"
```

---

## Task 3: 趋势查询（四段堆叠 + 小时走明细表）

**Files:**
- Modify: `Electron/src/main/overviewRepository.ts`
- Modify: `Electron/src/main/overviewRepository.test.ts`

- [ ] **Step 1: 写失败的测试**

```typescript
describe('trend', () => {
  it('returns four stack segments per bucket, cache split from input', () => {
    db.exec(`
      INSERT INTO daily_rollup(usage_date, provider_id, source_kind, project_id, model_canonical,
        sessions_count, events_count, tokens_input, tokens_output, tokens_cache_read,
        tokens_cache_write_5m, tokens_cache_write_1h, cost_usd_micros)
      VALUES ('2026-07-09','claude-code','claude_jsonl',NULL,'m',1,1, 100, 10, 900, 5, 3, 1),
             ('2026-07-10','claude-code','claude_jsonl',NULL,'m',1,1, 200, 20,   0, 0, 0, 1);
    `);

    const rows = new OverviewRepository(db, () => NOW).trend('2026-07-09', '2026-07-10', 'day');

    expect(rows).toEqual([
      { bucket: '2026-07-09', input: 100, cacheWrite: 8, cacheRead: 900, output: 10 },
      { bucket: '2026-07-10', input: 200, cacheWrite: 0, cacheRead: 0, output: 20 }
    ]);
  });

  it('fills gaps with zero buckets so the x axis has no holes', () => {
    db.exec(`INSERT INTO daily_rollup(usage_date, provider_id, source_kind, project_id, model_canonical,
      sessions_count, events_count, tokens_input, cost_usd_micros)
      VALUES ('2026-07-08','c','k',NULL,'m',1,1,10,1), ('2026-07-10','c','k',NULL,'m',1,1,20,1);`);

    const rows = new OverviewRepository(db, () => NOW).trend('2026-07-08', '2026-07-10', 'day');

    expect(rows.map(r => r.bucket)).toEqual(['2026-07-08', '2026-07-09', '2026-07-10']);
    expect(rows[1]).toEqual({ bucket: '2026-07-09', input: 0, cacheWrite: 0, cacheRead: 0, output: 0 });
  });

  it('rejects a granularity the range does not allow', () => {
    const repo = new OverviewRepository(db, () => NOW);
    expect(() => repo.trend('2026-06-11', '2026-07-10', 'hour')).toThrow(/hour.*not allowed/i);
  });
});
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd Electron && npx vitest run src/main/overviewRepository.test.ts`
Expected: FAIL，`repo.trend is not a function`

- [ ] **Step 3: 实现**

在 `OverviewRepository` 增加。注意 `hour` 走 `usage_events`——`daily_rollup` 只有天（spec §4.2）。

```typescript
import { isAllowed, type Granularity } from './granularity.js';

export interface TrendBucket {
  bucket: string;
  input: number;
  cacheWrite: number;
  cacheRead: number;
  output: number;
}

  trend(from: string, to: string, g: Granularity): TrendBucket[] {
    if (!isAllowed(from, to, g)) {
      throw new Error(`granularity ${g} is not allowed for ${from}..${to}`);
    }

    const rows = g === 'hour' ? this.trendByHour(from, to) : this.trendByDate(from, to, g);
    return fillGaps(rows, from, to, g);
  }

  /// 小时粒度只在 ≤ 2 天的范围里开放，最多 48 根柱子、几百条明细。
  /// daily_rollup 没有小时维度，硬做物化表得不偿失（spec §4.2）。
  private trendByHour(from: string, to: string): TrendBucket[] {
    return this.db.prepare(
      `SELECT strftime('%Y-%m-%d %H', e.observed_epoch_ms / 1000, 'unixepoch', 'localtime') AS bucket,
              coalesce(sum(e.tokens_input), 0) AS input,
              coalesce(sum(e.tokens_cache_write_5m + e.tokens_cache_write_1h), 0) AS cacheWrite,
              coalesce(sum(e.tokens_cache_read), 0) AS cacheRead,
              coalesce(sum(e.tokens_output), 0) AS output
         FROM usage_events e
        WHERE date(e.observed_epoch_ms / 1000, 'unixepoch', 'localtime') BETWEEN ? AND ?
     GROUP BY bucket ORDER BY bucket`
    ).all(from, to) as TrendBucket[];
  }

  private trendByDate(from: string, to: string, g: Granularity): TrendBucket[] {
    // week 以周一为起点；month 取 YYYY-MM。两者都由 SQLite 的 strftime 完成，
    // 不在 TypeScript 里重算日期——两套日历实现必然漂移。
    const bucketExpr =
      g === 'week' ? `date(usage_date, 'weekday 0', '-6 days')`
      : g === 'month' ? `strftime('%Y-%m', usage_date)`
      : `usage_date`;

    return this.db.prepare(
      `SELECT ${bucketExpr} AS bucket,
              coalesce(sum(tokens_input), 0) AS input,
              coalesce(sum(tokens_cache_write_5m + tokens_cache_write_1h), 0) AS cacheWrite,
              coalesce(sum(tokens_cache_read), 0) AS cacheRead,
              coalesce(sum(tokens_output), 0) AS output
         FROM daily_rollup
        WHERE usage_date BETWEEN ? AND ?
     GROUP BY bucket ORDER BY bucket`
    ).all(from, to) as TrendBucket[];
  }
```

补一个模块级函数。**空桶必须补齐**：缺一天不是「那天不存在」，是「那天用量为零」，X 轴不能有洞。

```typescript
const ZERO = { input: 0, cacheWrite: 0, cacheRead: 0, output: 0 };

function fillGaps(rows: TrendBucket[], from: string, to: string, g: Granularity): TrendBucket[] {
  if (g === 'week' || g === 'month') return rows;   // 周/月的桶键不是连续日期，交给 SQL 的结果原样返回
  const byBucket = new Map(rows.map(r => [r.bucket, r]));
  const out: TrendBucket[] = [];
  const step = g === 'hour' ? 3_600_000 : 86_400_000;
  const start = Date.parse(`${from}T00:00:00`);
  const end = Date.parse(`${to}T23:59:59`);
  for (let t = start; t <= end; t += step) {
    const d = new Date(t);
    const pad = (n: number) => String(n).padStart(2, '0');
    const key = g === 'hour'
      ? `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}`
      : `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
    out.push(byBucket.get(key) ?? { bucket: key, ...ZERO });
  }
  return out;
}
```

测试里 `trendByHour` 会查 `usage_events`，而测试 fixture 没建这张表。**在 `beforeEach` 里补上它**，列与 spec §4.1 一致。

- [ ] **Step 4: 运行测试确认通过**

Run: `cd Electron && npx vitest run src/main/overviewRepository.test.ts`
Expected: `Tests  8 passed`

- [ ] **Step 5: 提交**

```bash
git add Electron/src/main/
git commit -m "feat: query stacked token trend by bucket"
```

---

## Task 4: 热力图查询与对数色阶

**强度用对数映射，不用线性。** token 用量是长尾——本机存在 3.28 GB 的单个 session，某天用量可能是中位数的数十倍。线性映射会让 364 天挤在最浅色而 1 天全黑（spec §7.2）。

**Files:**
- Modify: `Electron/src/main/overviewRepository.ts`
- Create: `Electron/src/renderer/charts/scale.ts`
- Test: `Electron/src/renderer/charts/scale.test.ts`

- [ ] **Step 1: 写失败的测试（色阶）**

```typescript
import { describe, it, expect } from 'vitest';
import { logBucket, niceTicks, HEATMAP_LEVELS } from './scale.js';

describe('logBucket', () => {
  it('maps zero to level 0 and the max to the top level', () => {
    expect(logBucket(0, 1000)).toBe(0);
    expect(logBucket(1000, 1000)).toBe(HEATMAP_LEVELS - 1);
  });

  it('separates a long tail that a linear scale would flatten', () => {
    // 中位数 1000、峰值 100000。线性映射下 1000 会落在 level 0（1000/100000 = 1%）。
    const linear = Math.floor((1000 / 100000) * (HEATMAP_LEVELS - 1));
    expect(linear).toBe(0);
    expect(logBucket(1000, 100000)).toBeGreaterThan(0);
  });

  it('is monotonic', () => {
    let prev = -1;
    for (const v of [0, 1, 10, 100, 1000, 10000, 100000]) {
      const b = logBucket(v, 100000);
      expect(b).toBeGreaterThanOrEqual(prev);
      prev = b;
    }
  });

  it('never divides by zero when every day is empty', () => {
    expect(logBucket(0, 0)).toBe(0);
  });

  it('clamps a value above max rather than overflowing the palette', () => {
    expect(logBucket(2000, 1000)).toBe(HEATMAP_LEVELS - 1);
  });
});

describe('niceTicks', () => {
  it('produces round numbers covering the max', () => {
    expect(niceTicks(0, 4)).toEqual([0]);
    const t = niceTicks(2300, 4);
    expect(t[0]).toBe(0);
    expect(t[t.length - 1]).toBeGreaterThanOrEqual(2300);
    expect(t.every(v => Number.isInteger(v))).toBe(true);
  });

  it('never returns duplicate ticks for tiny maxima', () => {
    expect(new Set(niceTicks(3, 4)).size).toBe(niceTicks(3, 4).length);
  });
});
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd Electron && npx vitest run src/renderer/charts/scale.test.ts`
Expected: FAIL，`Failed to resolve import "./scale.js"`

- [ ] **Step 3: 实现**

`Electron/src/renderer/charts/scale.ts`：

```typescript
export const HEATMAP_LEVELS = 5;

/// 把用量映射到 0..HEATMAP_LEVELS-1 的色阶档位。
///
/// 用 log1p 而不是线性：token 用量是长尾分布。本机某天的用量是中位数的几十倍，
/// 线性映射会把 364 天压进最浅的一档、只有 1 天是深色——那张图什么也没说。
/// log1p 保证 0 仍然映射到 0（log1p(0) = 0），不必对零值特判。
export function logBucket(value: number, max: number): number {
  if (max <= 0 || value <= 0) return 0;
  const clamped = Math.min(value, max);
  const ratio = Math.log1p(clamped) / Math.log1p(max);
  return Math.min(HEATMAP_LEVELS - 1, Math.max(0, Math.round(ratio * (HEATMAP_LEVELS - 1))));
}

/// Y 轴刻度：0 起步，末位 ≥ max，全是整数且互不相同。
export function niceTicks(max: number, count: number): number[] {
  if (max <= 0) return [0];
  const rawStep = max / Math.max(1, count);
  const magnitude = Math.pow(10, Math.floor(Math.log10(rawStep)));
  const normalized = rawStep / magnitude;
  const niceStep = (normalized <= 1 ? 1 : normalized <= 2 ? 2 : normalized <= 5 ? 5 : 10) * magnitude;
  const step = Math.max(1, Math.round(niceStep));
  const out: number[] = [];
  for (let v = 0; v < max + step; v += step) out.push(v);
  return out;
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd Electron && npx vitest run src/renderer/charts/scale.test.ts`
Expected: `Tests  7 passed`

- [ ] **Step 5: 写失败的测试（热力图查询）**

追加到 `overviewRepository.test.ts`：

```typescript
describe('heatmap', () => {
  it('returns one row per day that has data, with three switchable metrics', () => {
    db.exec(`INSERT INTO daily_rollup(usage_date, provider_id, source_kind, project_id, model_canonical,
      sessions_count, events_count, tokens_input, tokens_output, cost_usd_micros)
      VALUES ('2026-07-09','c','k',NULL,'m1', 1, 3, 100, 10, 500),
             ('2026-07-09','c','k',NULL,'m2', 1, 2,  50,  5, 300),
             ('2026-07-10','c','k',NULL,'m1', 1, 1,  20,  2, 100);`);

    const rows = new OverviewRepository(db, () => NOW).heatmap('2026-07-09', '2026-07-10');

    expect(rows).toEqual([
      { date: '2026-07-09', tokens: 165, costUsdMicros: 800, sessions: 2, events: 5 },
      { date: '2026-07-10', tokens: 22, costUsdMicros: 100, sessions: 1, events: 1 }
    ]);
  });

  it('does not sum sessions_count across models on the same day', () => {
    // 同一会话当天用了两个模型 → 两行、各 sessions_count=1。
    // 热力图的「会话数」维度必须 count(distinct)，不能求和成 2。
    db.exec(`INSERT INTO agent_sessions(id, source_kind, source_session_key, scan_root_id, provider_id)
             VALUES (7,'k','s7',1,'c');
             INSERT INTO session_rollup(session_id, first_event_epoch_ms, last_event_epoch_ms,
               events_count, tokens_total, cost_usd_micros) VALUES (7, 0, 0, 2, 150, 800);`);
    // 见 Step 7：实现必须从 usage_events 取 distinct session。
  });
});
```

- [ ] **Step 6: 运行测试确认失败**

Run: `cd Electron && npx vitest run src/main/overviewRepository.test.ts`
Expected: FAIL，`repo.heatmap is not a function`

- [ ] **Step 7: 实现**

```typescript
export interface HeatmapDay {
  date: string;
  tokens: number;
  costUsdMicros: number;
  sessions: number;
  events: number;
}

  /// 一格一天。`sessions` 走 usage_events 的 count(distinct session_id)，
  /// 【不能】对 daily_rollup.sessions_count 求和——同一会话当天用两个模型会占两行。
  heatmap(from: string, to: string): HeatmapDay[] {
    return this.db.prepare(
      `SELECT d.usage_date AS date,
              coalesce(sum(d.tokens_input + d.tokens_output + d.tokens_cache_read
                           + d.tokens_cache_write_5m + d.tokens_cache_write_1h), 0) AS tokens,
              coalesce(sum(d.cost_usd_micros), 0) AS costUsdMicros,
              coalesce(sum(d.events_count), 0) AS events,
              (SELECT count(DISTINCT e.session_id) FROM usage_events e
                WHERE date(e.observed_epoch_ms / 1000, 'unixepoch', 'localtime') = d.usage_date) AS sessions
         FROM daily_rollup d
        WHERE d.usage_date BETWEEN ? AND ?
     GROUP BY d.usage_date ORDER BY d.usage_date`
    ).all(from, to) as HeatmapDay[];
  }
```

热力图**不补空洞**：没有数据的那天就是 level 0，由组件按日历网格摆放，无需 repository 造零行。

- [ ] **Step 8: 运行测试确认通过 + 提交**

Run: `cd Electron && npx vitest run src/main/overviewRepository.test.ts`

```bash
git add Electron/src/
git commit -m "feat: query year heatmap with a log colour scale"
```

---

## Task 5: 模型排行与会话列表查询

**Files:**
- Modify: `Electron/src/main/overviewRepository.ts`
- Modify: `Electron/src/main/overviewRepository.test.ts`

- [ ] **Step 1: 写失败的测试**

```typescript
describe('modelRanking', () => {
  it('ranks by cost or by tokens, and reports unknown-cost events per model', () => {
    db.exec(`INSERT INTO daily_rollup(usage_date, provider_id, source_kind, project_id, model_canonical,
      sessions_count, events_count, tokens_input, cost_usd_micros, cost_unknown_events)
      VALUES ('2026-07-10','c','k',NULL,'cheap-but-huge', 1, 1, 1000, 100, 0),
             ('2026-07-10','c','k',NULL,'pricey-but-small', 1, 1,  10, 900, 0),
             ('2026-07-10','c','k',NULL,'unpriced',        1, 4,  50, NULL, 4);`);

    const repo = new OverviewRepository(db, () => NOW);

    expect(repo.modelRanking('2026-07-10', '2026-07-10', 'cost').map(m => m.model))
      .toEqual(['pricey-but-small', 'cheap-but-huge', 'unpriced']);
    expect(repo.modelRanking('2026-07-10', '2026-07-10', 'tokens').map(m => m.model))
      .toEqual(['cheap-but-huge', 'unpriced', 'pricey-but-small']);

    const unpriced = repo.modelRanking('2026-07-10', '2026-07-10', 'tokens')
      .find(m => m.model === 'unpriced')!;
    expect(unpriced.costUsdMicros).toBe(0);
    expect(unpriced.costUnknownEvents).toBe(4);   // 成本是 0 还是「不知道」，UI 必须能区分
  });
});
```

- [ ] **Step 2: 运行确认失败，然后实现**

```typescript
export interface ModelRank {
  model: string;
  tokens: number;
  costUsdMicros: number;
  costUnknownEvents: number;
}

  modelRanking(from: string, to: string, sortBy: 'cost' | 'tokens'): ModelRank[] {
    const orderBy = sortBy === 'cost' ? 'costUsdMicros DESC, tokens DESC' : 'tokens DESC, costUsdMicros DESC';
    return this.db.prepare(
      `SELECT model_canonical AS model,
              coalesce(sum(tokens_input + tokens_output + tokens_cache_read
                           + tokens_cache_write_5m + tokens_cache_write_1h), 0) AS tokens,
              coalesce(sum(cost_usd_micros), 0) AS costUsdMicros,
              coalesce(sum(cost_unknown_events), 0) AS costUnknownEvents
         FROM daily_rollup
        WHERE usage_date BETWEEN ? AND ?
     GROUP BY model_canonical
     ORDER BY ${orderBy}`
    ).all(from, to) as ModelRank[];
  }
```

`sortBy` 是联合类型且 `orderBy` 由它派生，不拼接用户输入——**不要**把排序列做成字符串参数。

- [ ] **Step 3: 会话列表**

右栏只放会话列表（spec §7.2）：进行中的置顶高亮，下方最近结束的若干条。它就是 `recentActivity` 加上时长与成本。扩展 `ActivityRow`，加 `firstEventEpochMs` 与 `costUsdMicros`，测试断言按 `isLive` 分组后各自按时间倒序。

- [ ] **Step 4: 提交**

```bash
git add Electron/src/main/
git commit -m "feat: query model ranking and the session rail"
```

---

## Task 6: 堆叠柱状图（布局纯函数先行）

图表的 bug 几乎都在算坐标，不在画矩形。所以布局先写成纯函数，单测覆盖；`.tsx` 只把坐标变成元素。

**Files:**
- Create: `Electron/src/renderer/charts/stackedBarLayout.ts`
- Create: `Electron/src/renderer/charts/StackedBarChart.tsx`
- Test: `Electron/src/renderer/charts/stackedBarLayout.test.ts`

- [ ] **Step 1: 写失败的测试**

```typescript
import { describe, it, expect } from 'vitest';
import { layoutStackedBars, SEGMENTS } from './stackedBarLayout.js';

const bars = [
  { bucket: 'a', input: 10, cacheWrite: 0, cacheRead: 20, output: 10 },   // 40
  { bucket: 'b', input: 0, cacheWrite: 0, cacheRead: 0, output: 0 }       // 0
];

describe('layoutStackedBars', () => {
  it('stacks segments bottom-up and never exceeds the plot height', () => {
    const { rects, maxTotal } = layoutStackedBars(bars, { width: 200, height: 100, padding: 0 });
    expect(maxTotal).toBe(40);
    const first = rects.filter(r => r.bucket === 'a');
    expect(first.map(r => r.segment)).toEqual(SEGMENTS);            // 顺序固定，图例才对得上
    expect(Math.min(...first.map(r => r.y))).toBeGreaterThanOrEqual(0);
    expect(Math.max(...first.map(r => r.y + r.height))).toBeLessThanOrEqual(100);
  });

  it('emits no rect for a zero segment rather than a zero-height one', () => {
    // 高度为 0 的 <rect> 在某些渲染器上仍会画出 1px 的线
    const { rects } = layoutStackedBars(bars, { width: 200, height: 100, padding: 0 });
    expect(rects.filter(r => r.bucket === 'b')).toEqual([]);
    expect(rects.every(r => r.height > 0)).toBe(true);
  });

  it('survives an all-zero dataset without dividing by zero', () => {
    const { rects, maxTotal } = layoutStackedBars([bars[1]], { width: 200, height: 100, padding: 0 });
    expect(maxTotal).toBe(0);
    expect(rects).toEqual([]);
  });

  it('keeps bars inside the width regardless of count', () => {
    const many = Array.from({ length: 120 }, (_, i) => ({ ...bars[0], bucket: `b${i}` }));
    const { rects } = layoutStackedBars(many, { width: 840, height: 100, padding: 0 });
    expect(Math.max(...rects.map(r => r.x + r.width))).toBeLessThanOrEqual(840);
    expect(rects.every(r => r.width > 0)).toBe(true);
  });
});
```

- [ ] **Step 2: 运行确认失败，然后实现**

```typescript
import type { TrendBucket } from '../../main/overviewRepository.js';

/// 自下而上的堆叠顺序。图例、颜色、tooltip 全部依赖它，改这里就要一起改。
export const SEGMENTS = ['input', 'cacheWrite', 'cacheRead', 'output'] as const;
export type Segment = (typeof SEGMENTS)[number];

export interface Rect {
  bucket: string; segment: Segment;
  x: number; y: number; width: number; height: number;
}

export interface LayoutBox { width: number; height: number; padding: number; }

export function layoutStackedBars(bars: TrendBucket[], box: LayoutBox): { rects: Rect[]; maxTotal: number } {
  const totals = bars.map(b => b.input + b.cacheWrite + b.cacheRead + b.output);
  const maxTotal = Math.max(0, ...totals);
  if (maxTotal === 0 || bars.length === 0) return { rects: [], maxTotal };

  const slot = box.width / bars.length;
  const barWidth = Math.max(1, slot - box.padding);
  const rects: Rect[] = [];

  bars.forEach((bar, i) => {
    let cursorY = box.height;                       // 自底向上堆
    for (const segment of SEGMENTS) {
      const value = bar[segment];
      if (value <= 0) continue;                     // 零段不产出 rect：0 高的 <rect> 会被画成 1px 的线
      const height = (value / maxTotal) * box.height;
      cursorY -= height;
      rects.push({ bucket: bar.bucket, segment, x: i * slot, y: cursorY, width: barWidth, height });
    }
  });

  return { rects, maxTotal };
}
```

- [ ] **Step 3: 组件**

`StackedBarChart.tsx` 的职责仅有四件：用 `ResizeObserver` 拿宽度、调 `layoutStackedBars`、把 `rects` 渲染成 `<rect>`、`niceTicks(maxTotal, 4)` 画 Y 轴。X 轴标签稀疏化：`bars.length > 12` 时每 `ceil(n/12)` 个显示一个。

hover 用一个覆盖整根柱子的透明 `<rect>` 接事件（逐段接会导致段间缝隙丢事件），把 `bucket` 传给 tooltip。

组件测试用 `@testing-library/react` 断言：给定 2 根柱子渲染出 6 个 `<rect>`（4 段非零 + 1 段 + hover 层），tooltip 在 `mouseEnter` 后出现且含桶名。

- [ ] **Step 4: 提交**

```bash
git add Electron/src/renderer/charts/
git commit -m "feat: add a hand-rolled stacked bar chart"
```

---

## Task 7: 年度热力图

53 列 × 7 行，一格一天。hover 出 tooltip，click 跳到用量页并带上日期筛选（spec §7.2）。

**Files:**
- Create: `Electron/src/renderer/charts/YearHeatmap.tsx`
- Create: `Electron/src/renderer/charts/calendar.ts`
- Test: `Electron/src/renderer/charts/calendar.test.ts`

- [ ] **Step 1: 日历网格是纯函数，先测**

```typescript
import { describe, it, expect } from 'vitest';
import { buildCalendarGrid } from './calendar.js';

describe('buildCalendarGrid', () => {
  it('starts each column on the same weekday', () => {
    const grid = buildCalendarGrid('2026-07-10', 371);
    for (const col of grid) expect(col.length).toBeLessThanOrEqual(7);
    const firstDays = grid.filter(c => c.length === 7).map(c => new Date(c[0].date).getDay());
    expect(new Set(firstDays).size).toBe(1);
  });

  it('ends on the requested last day', () => {
    const grid = buildCalendarGrid('2026-07-10', 371);
    const flat = grid.flat();
    expect(flat[flat.length - 1].date).toBe('2026-07-10');
  });

  it('covers exactly the requested number of days', () => {
    expect(buildCalendarGrid('2026-07-10', 371).flat()).toHaveLength(371);
  });

  it('handles a DST-free timezone shift without dropping or duplicating a day', () => {
    // 用本地日期字符串推进，不用 epoch 加 86400000——后者在 DST 切换日会少一天或多一天。
    const dates = buildCalendarGrid('2026-07-10', 371).flat().map(d => d.date);
    expect(new Set(dates).size).toBe(371);
  });
});
```

- [ ] **Step 2: 实现日历网格**

用**本地日期字符串**逐日推进（`new Date(y, m, d - 1)`），**不要**用 epoch 加 `86_400_000`——DST 切换那天会少一天或多一天。本机在 UTC+8 无 DST，但这行代码没理由只在中国正确。

- [ ] **Step 3: 组件**

每格一个 `<div>`，`data-level={logBucket(value, max)}`，颜色由 CSS 变量 `--heat-0..4` 提供。整张图 371 个 div，在 React 里是一次渲染，不需要虚拟化。

- **hover**：整张网格挂一个 `mouseover`，用 `event.target.dataset.date` 取日期（事件委托，371 个监听器换成 1 个）。
- **click**：`onSelectDate(date)`，由概览页转成路由跳转（用量页 `from = to = date`，粒度 `hour`）。

组件测试断言：371 个格子、level 分布与 `logBucket` 一致、click 触发回调带正确日期。

- [ ] **Step 4: 提交**

```bash
git add Electron/src/renderer/charts/
git commit -m "feat: add the year activity heatmap"
```

---

## Task 8: 自动刷新

用户要求：后台每隔几秒或一分钟刷新一次，频率可配，另有手动刷新按钮。

**Files:**
- Create: `Electron/src/renderer/hooks/useAutoRefresh.ts`
- Test: `Electron/src/renderer/hooks/useAutoRefresh.test.ts`

- [ ] **Step 1: 写失败的测试**

```typescript
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { useAutoRefresh } from './useAutoRefresh.js';

function setVisibility(state: 'visible' | 'hidden') {
  Object.defineProperty(document, 'visibilityState', { value: state, configurable: true });
  document.dispatchEvent(new Event('visibilitychange'));
}

beforeEach(() => { vi.useFakeTimers(); setVisibility('visible'); });
afterEach(() => { vi.useRealTimers(); vi.restoreAllMocks(); });

describe('useAutoRefresh', () => {
  it('polls on the configured interval while visible', () => {
    const refresh = vi.fn().mockResolvedValue(undefined);
    renderHook(() => useAutoRefresh(refresh, { intervalMs: 60_000 }));
    expect(refresh).toHaveBeenCalledTimes(1);          // 挂载时先取一次，否则首屏是空的
    act(() => { vi.advanceTimersByTime(60_000); });
    expect(refresh).toHaveBeenCalledTimes(2);
  });

  it('does not poll while the window is hidden', () => {
    const refresh = vi.fn().mockResolvedValue(undefined);
    renderHook(() => useAutoRefresh(refresh, { intervalMs: 60_000 }));
    refresh.mockClear();
    act(() => { setVisibility('hidden'); vi.advanceTimersByTime(5 * 60_000); });
    expect(refresh).not.toHaveBeenCalled();            // 常驻应用隐藏时不该继续查库
  });

  it('refreshes once immediately when the window becomes visible again', () => {
    const refresh = vi.fn().mockResolvedValue(undefined);
    renderHook(() => useAutoRefresh(refresh, { intervalMs: 60_000 }));
    act(() => { setVisibility('hidden'); vi.advanceTimersByTime(5 * 60_000); });
    refresh.mockClear();
    act(() => { setVisibility('visible'); });
    expect(refresh).toHaveBeenCalledTimes(1);          // 补上隐藏期间跳过的，但只补一次
  });

  it('does not start a second refresh while one is still in flight', () => {
    let resolveIt: () => void = () => {};
    const refresh = vi.fn(() => new Promise<void>(r => { resolveIt = r; }));
    renderHook(() => useAutoRefresh(refresh, { intervalMs: 1_000 }));
    act(() => { vi.advanceTimersByTime(5_000); });
    expect(refresh).toHaveBeenCalledTimes(1);          // 一次慢查询不该堆出五次并发
    act(() => { resolveIt(); });
  });

  it('stops the timer on unmount', () => {
    const refresh = vi.fn().mockResolvedValue(undefined);
    const { unmount } = renderHook(() => useAutoRefresh(refresh, { intervalMs: 1_000 }));
    unmount();
    refresh.mockClear();
    act(() => { vi.advanceTimersByTime(10_000); });
    expect(refresh).not.toHaveBeenCalled();            // 不清理的 interval 会在热重载里堆积
  });
});
```

第四条是这里最容易被写漏的一条：`scan.finished` 事件和定时轮询会撞在一起，若不去重，一次慢查询期间能堆出五个并发查询。第五条在开发期尤其明显——热重载会把 interval 叠起来，页面看着正常，CPU 却在空转。

- [ ] **Step 2: 实现**

事件驱动为主、轮询兜底：Swift 扫描完成时 Electron 主进程收到 `scan.finished`（Task 15 已铺好通道），转成 `dashboard:invalidate` 发给 renderer；renderer 同时挂一个 `setInterval` 兜底。

`document.visibilityState === 'hidden'` 时**暂停轮询**——这是常驻工具应用降低空闲开销最直接的一招。

- [ ] **Step 3: 提交**

---

## Task 9: 概览页组装与响应式

**Files:**
- Create: `Electron/src/renderer/routes/Overview.tsx`
- Modify: `Electron/src/renderer/components/Layout.tsx`
- Modify: `Electron/src/renderer/styles.css`
- Modify: `Electron/src/main/main.ts`（`minWidth: 720`）

断点（spec §7.5）：

| 断点 | 行为 |
|---|---|
| ≥ 1600px | 容器 max-width 1720px 居中，右栏固定 300px |
| 1180px（默认） | 主区约 840px，KPI 4 列，热力图与模型排行并排 |
| < 960px | 全部单列，**右侧会话列表隐藏**，导航栏出现带数字的脉冲徽标按钮，点开浮层 |

用 CSS Grid + 容器查询，不写 JS 断点监听——窗口 resize 时的 re-render 是常驻内存与 CPU 的主要来源之一。

- [ ] **Step 1: 组装页面，断言四个区块都渲染**
- [ ] **Step 2: 窄屏浮层的测试**：`< 960px` 时会话列表不在文档流里，点击徽标后出现。
- [ ] **Step 3: 提交**

---

## Task 10: 常驻内存实测

**验收：常驻内存 < 200 MB。** 这是用户的原始要求（「这是个工具类型的东西，我会常驻打开」）。

- [ ] **Step 1: 打包 dev app，打开概览页，静置 10 分钟**
- [ ] **Step 2: 用 `process.getProcessMemoryInfo()` 记录主进程与 renderer 的 `private` 值**
- [ ] **Step 3: 记录数字**

若超标，先查这三处，按嫌疑排序：热力图的 371 个 DOM 节点（应无问题）、`setInterval` 是否在窗口隐藏时真的停了、better-sqlite3 的 statement 是否被反复 prepare 而非缓存。

**不要为了达标而猜测优化。** 先测出是谁占的（Chrome DevTools 的 heap snapshot），再动手。Phase 1 的教训：我曾断定内存大头是逐行 JSON 解析产生的对象，实测发现是文件读取块，而按我的假设改会让内存翻倍。

---

## 完成标准

- `cd Electron && npm test` 全绿，`npm run typecheck` 通过。
- 概览页在 1180px 下四个区块齐备；拖到 900px 会话列表收进浮层；拖到 1600px 主区变宽而右栏不变。
- 热力图点击某天 → 跳到用量页且日期筛选已设为该天。
- 静置 10 分钟后常驻内存 < 200 MB，且窗口隐藏时不再有数据库查询。
- `bash scripts/reconcile-with-ccusage.sh` 仍然 PASS——本阶段不碰写入路径，数字不该动。
