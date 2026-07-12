import fs from 'node:fs';
import type Database from 'better-sqlite3';
import { isAllowed, type Granularity } from './granularity.js';
import { localBucketKeys, pad2 } from '../shared/calendar.js';

/// 概览页的三种数据状态。空的两种必须分开表达（spec「升级后的第一次打开」）：
/// 显示 0 tokens 会让刚升级的用户以为软件坏了，而真相是「还没扫过」。
export type OverviewDataState = 'ready' | 'never-used' | 'needs-reindex';

const defaultCorpusExists = (rootPath: string): boolean => {
  try {
    return fs.existsSync(rootPath);
  } catch {
    return false;
  }
};

/// 2 分钟内消耗过 token 的会话打实心脉冲点（OpenDesign 稿：「运行中判定：
/// 2 分钟内有新事件写入日志」）。
///
/// 这【不是】「正在运行」。没有可靠的非侵入方法回答那个问题（spec §7.2.1）：
/// 本机 14 个并发 agent 进程里，进程存在、CPU、子进程数三个信号全无区分度；
/// 网络连接数只对 claude 有效，持有 session 文件只对 codex 有效，且两者都是
/// 实现细节，agent 改版即静默失效。这里只陈述磁盘上的事实。
const LIVE_WINDOW_MS = 2 * 60_000;

export interface ActivityRow {
  sessionId: number;
  providerId: string;
  projectName: string;
  primaryModel: string | null;
  /// 主会话自己用过的所有模型（去重，排除子代理），供卡片以 tag 展示。
  models: string[];
  tokensTotal: number;
  firstEventEpochMs: number;
  costUsdMicros: number;
  costUnknownEvents: number;
  msSinceLastEvent: number;
  isLive: boolean;
  subagentCount: number;
}

/// 主会话下钻浮窗里每个子代理一行。两种数据形态（Claude 的 sidechain 事件 / 其他三家的
/// 独立子会话）都投影成这个统一结构，差异封装在 subagentBreakdown 内。
export interface SubagentRow {
  label: string;
  tokens: number;
  costUsdMicros: number;
  durationMs: number;
  model: string | null;
  lastEventMs: number;
}

type ActivityQueryRow = Omit<ActivityRow, 'msSinceLastEvent' | 'isLive' | 'models'>
  & { lastEventEpochMs: number; models: string | null };

const ACTIVITY_SELECT =
  `SELECT sr.session_id AS sessionId,
          coalesce(s.provider_id, s.source_kind) AS providerId,
          coalesce(p.display_name, '未知项目') AS projectName,
          sr.primary_model AS primaryModel,
          sr.tokens_total AS tokensTotal,
          sr.first_event_epoch_ms AS firstEventEpochMs,
          sr.cost_usd_micros AS costUsdMicros,
          sr.cost_unknown_events AS costUnknownEvents,
          sr.last_event_epoch_ms AS lastEventEpochMs
     FROM session_rollup sr
     JOIN agent_sessions s ON s.id = sr.session_id
LEFT JOIN projects p ON p.id = s.project_id
    WHERE s.status != 'deleted'`;

export interface OverviewKpis {
  todayTokens: number;
  yesterdayTokens: number;
  todaySessions: number;
  todayCostUsdMicros: number;
  todayCostUnknownEvents: number;
  monthCostUsdMicros: number;
}

export interface TrendBucket {
  bucket: string;
  input: number;
  cacheWrite: number;
  cacheRead: number;
  output: number;
}

/// 按 agent（provider）分组的趋势行（OpenDesign 稿：趋势图按 Claude Code /
/// Codex / OMP / OpenCode 堆叠，Token/花费/会话三指标由前端本地切换）。
export interface AgentTrendRow {
  bucket: string;
  providerId: string;
  tokens: number;
  costUsdMicros: number;
  sessions: number;
}

export interface AgentTrendSeries {
  granularity: Granularity;
  from: string;
  to: string;
  /// 完整桶轴（含无数据的空桶），rows 是稀疏的，前端按 buckets 铺 x 轴。
  buckets: string[];
  rows: AgentTrendRow[];
}

export interface HeatmapDay {
  date: string;
  tokens: number;
  costUsdMicros: number;
  sessions: number;
  events: number;
}

export interface ModelRank {
  model: string;
  tokens: number;
  costUsdMicros: number;
  costUnknownEvents: number;
}

/// 概览页默认展示的时间范围。趋势与排行走最近 30 天（30 根 ≤ 120 可读上限，day 粒度合法）；
/// 热力图走一年（371 天，与 YearHeatmap 的默认格数一致）。
const TREND_DAYS = 30;
const HEATMAP_DAYS = 371;

/// agent 趋势的三档粒度各配固定范围（桶数分别为 30/12/12，全在可读上限内），
/// 三档一次性随 payload 返回，前端切粒度零 IPC。
const AGENT_TREND_DAYS: Record<'day' | 'week' | 'month', number> = { day: 30, week: 84, month: 365 };
// 实时会话区只做「最新动态」，不做「全部会话」——那是「会话」页要做的事。
// 固定取 10 条（OpenDesign 稿：最新 10 个）：sessionRail 已经按 isLive 置顶、
// 组内按最近事件倒序排好，不需要滚动、也不需要按屏幕高度猜数量。
const SESSION_RAIL_LIMIT = 10;

export interface OverviewReady {
  dataState: 'ready';
  today: string;
  kpis: OverviewKpis;
  trend: TrendBucket[];
  trendRange: { from: string; to: string; granularity: Granularity };
  agentTrend: { day: AgentTrendSeries; week: AgentTrendSeries; month: AgentTrendSeries };
  heatmap: HeatmapDay[];
  heatmapLastDay: string;
  heatmapDays: number;
  modelRanking: ModelRank[];
  sessionRail: ActivityRow[];
}

export interface OverviewEmpty {
  dataState: 'never-used' | 'needs-reindex';
}

export type OverviewPayload = OverviewReady | OverviewEmpty;

/// `now` 可注入，否则测试会在午夜前后随机变红。
export class OverviewRepository {
  constructor(private readonly db: Database.Database, private readonly now: () => number = Date.now) {}

  /// 区分两种「空」：
  ///   never-used   —— 无启用扫描源，或启用的扫描源语料目录都不在磁盘上。
  ///   needs-reindex —— 有启用扫描源、语料在，但 usage_events 为空（升级后尚未重扫）。
  /// 只要 usage_events 有一行就是 ready，语料判据不再咨询。
  ///
  /// 必须容忍 v1 库：迁移由 Swift 触发，Electron 直接打开尚未迁移的 v1 库时
  /// usage_events / rollup 表尚不存在，这里按「空」处理，绝不能抛 no such table。
  /// 本机生产库（user_version=1）正是这个状态，落点为 needs-reindex。
  dataState(corpusExists: (rootPath: string) => boolean = defaultCorpusExists): OverviewDataState {
    if (this.hasUsageRows()) return 'ready';
    return this.enabledScanRootPaths().some(corpusExists) ? 'needs-reindex' : 'never-used';
  }

  /// 组装整页负载。空状态下【短路】——绝不触碰 kpis/trend/heatmap，因为升级前的
  /// v1 库里那些表尚不存在，跑了就 no such table。renderer 只接这一个 KB 级结果。
  buildOverview(corpusExists: (rootPath: string) => boolean = defaultCorpusExists): OverviewPayload {
    const state = this.dataState(corpusExists);
    if (state !== 'ready') return { dataState: state };

    const to = this.localDate(0);
    const trendFrom = this.localDate(-(TREND_DAYS - 1));
    const heatmapFrom = this.localDate(-(HEATMAP_DAYS - 1));

    return {
      dataState: 'ready',
      today: to,
      kpis: this.kpis(),
      trend: this.trend(trendFrom, to, 'day'),
      trendRange: { from: trendFrom, to, granularity: 'day' },
      agentTrend: {
        day: this.agentTrend(this.localDate(-(AGENT_TREND_DAYS.day - 1)), to, 'day'),
        week: this.agentTrend(this.localDate(-(AGENT_TREND_DAYS.week - 1)), to, 'week'),
        month: this.agentTrend(this.localDate(-(AGENT_TREND_DAYS.month - 1)), to, 'month')
      },
      heatmap: this.heatmap(heatmapFrom, to),
      heatmapLastDay: to,
      heatmapDays: HEATMAP_DAYS,
      modelRanking: this.modelRanking(trendFrom, to, 'cost'),
      sessionRail: this.sessionRail(SESSION_RAIL_LIMIT)
    };
  }

  private tableExists(name: string): boolean {
    return this.db
      .prepare(`SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?`)
      .get(name) !== undefined;
  }

  private hasUsageRows(): boolean {
    if (!this.tableExists('usage_events')) return false;
    return (this.db.prepare(`SELECT EXISTS(SELECT 1 FROM usage_events) AS n`).get() as { n: number }).n === 1;
  }

  private enabledScanRootPaths(): string[] {
    if (!this.tableExists('scan_roots')) return [];
    return (this.db
      .prepare(`SELECT root_path AS rootPath FROM scan_roots WHERE enabled = 1 AND scan_mode != 'disabled'`)
      .all() as Array<{ rootPath: string }>).map(r => r.rootPath);
  }

  private localDate(offsetDays = 0): string {
    const d = new Date(this.now() + offsetDays * 86_400_000);
    const pad = (n: number) => String(n).padStart(2, '0');
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
  }

  recentActivity(limit: number): ActivityRow[] {
    const now = this.now();
    const rows = this.db.prepare(
      `${ACTIVITY_SELECT} ORDER BY sr.last_event_epoch_ms DESC LIMIT ?`
    ).all(limit) as ActivityQueryRow[];
    return rows.map(r => this.toActivityRow(r, now));
  }

  /// 右栏会话列表（spec §7.2）：进行中的置顶高亮，各组内按最近事件倒序。
  /// 就是 recentActivity 加上时长（firstEventEpochMs）与成本，只是把 live 的钉在最前。
  /// 用同一个 `now` 算阈值与 isLive，边界不会因两次读表而漂移。
  /// 右栏会话列表（spec §7.2）+ 子代理归并（spec §6）：只列主会话（root_session_key IS NULL），
  /// 每条 token/cost = 自己 + 所有指向它的子会话之和，isLive 与排序用归并后的最近活动时间，并带子代理数量。
  /// 子会话按 (source_kind, root_session_key) 聚合，匹配父的 (source_kind, source_session_key)。
  /// Claude 子代理不是独立会话（root_session_key 全 NULL）→ 子会话集为空、退化成自己（其 rollup
  /// 已含 sidechain 事件）；Claude 的 subagentCount 由 subagentBreakdown 走 source_file 分组另算。
  sessionRail(limit: number): ActivityRow[] {
    const now = this.now();
    const rows = this.db.prepare(
      `SELECT sr.session_id AS sessionId,
              coalesce(s.provider_id, s.source_kind) AS providerId,
              coalesce(p.display_name, '未知项目') AS projectName,
              sr.primary_model AS primaryModel,
              (SELECT group_concat(DISTINCT e2.model_canonical) FROM usage_events e2
                 WHERE e2.session_id = sr.session_id AND e2.is_sidechain = 0) AS models,
              sr.tokens_total + coalesce(sub.tokens, 0) AS tokensTotal,
              sr.first_event_epoch_ms AS firstEventEpochMs,
              coalesce(sr.cost_usd_micros, 0) + coalesce(sub.cost, 0) AS costUsdMicros,
              sr.cost_unknown_events AS costUnknownEvents,
              max(sr.last_event_epoch_ms, coalesce(sub.last_event, 0)) AS lastEventEpochMs,
              coalesce(sub.cnt, 0) + coalesce(sc.cnt, 0) AS subagentCount
         FROM session_rollup sr
         JOIN agent_sessions s ON s.id = sr.session_id
    LEFT JOIN projects p ON p.id = s.project_id
    LEFT JOIN (
           SELECT cs.source_kind AS sk, cs.root_session_key AS rk,
                  sum(csr.tokens_total) AS tokens,
                  sum(csr.cost_usd_micros) AS cost,
                  max(csr.last_event_epoch_ms) AS last_event,
                  count(*) AS cnt
             FROM agent_sessions cs
             JOIN session_rollup csr ON csr.session_id = cs.id
            WHERE cs.root_session_key IS NOT NULL AND cs.status != 'deleted'
         GROUP BY cs.source_kind, cs.root_session_key
         ) sub ON sub.sk = s.source_kind AND sub.rk = s.source_session_key
    LEFT JOIN (
           -- Claude 的子代理是父会话里的 sidechain 事件，按 source_file 分组数个数。
           -- 只贡献 subagentCount，不加 token/cost：那些已在自己 session_rollup 里、含 sidechain。
           SELECT e.session_id AS sid, count(DISTINCT e.source_file_id) AS cnt
             FROM usage_events e
            WHERE e.is_sidechain = 1
         GROUP BY e.session_id
         ) sc ON sc.sid = sr.session_id
        WHERE s.status != 'deleted' AND s.root_session_key IS NULL
     ORDER BY (max(sr.last_event_epoch_ms, coalesce(sub.last_event, 0)) > ?) DESC,
              max(sr.last_event_epoch_ms, coalesce(sub.last_event, 0)) DESC
        LIMIT ?`
    ).all(now - LIVE_WINDOW_MS, limit) as ActivityQueryRow[];
    return rows.map(r => this.toActivityRow(r, now));
  }

  private toActivityRow(r: ActivityQueryRow, now: number): ActivityRow {
    const msSinceLastEvent = now - r.lastEventEpochMs;
    const { lastEventEpochMs, models, ...rest } = r;
    // recentActivity 走 ACTIVITY_SELECT 不带 subagentCount/models → 兜默认；sessionRail 归并查询带真实值。
    // models 从 group_concat 的逗号串拆成数组（主会话自己用过的所有模型，排除子代理）。
    return {
      ...rest,
      models: models ? models.split(',') : [],
      subagentCount: r.subagentCount ?? 0,
      msSinceLastEvent,
      isLive: msSinceLastEvent < LIVE_WINDOW_MS
    };
  }

  /// 主会话的子代理明细下钻（spec §6.3）。两种数据形态、对外统一结构：
  /// - Claude：子代理是父会话里 is_sidechain=1 的事件，按 source_file 分组，名字取 source_files.subagent_label。
  /// - 其他三家：子代理是独立子会话（root_session_key 指向本会话），名字取 agent_sessions.subagent_label。
  /// token 口径与别处一致：不含 reasoning。
  subagentBreakdown(sessionId: number): SubagentRow[] {
    const session = this.db.prepare(
      `SELECT source_kind AS sourceKind, source_session_key AS sourceSessionKey FROM agent_sessions WHERE id = ?`
    ).get(sessionId) as { sourceKind: string; sourceSessionKey: string } | undefined;
    if (!session) return [];

    if (session.sourceKind === 'claude_jsonl') {
      return this.db.prepare(
        `SELECT coalesce(f.subagent_label, '子代理') AS label,
                sum(e.tokens_input + e.tokens_output + e.tokens_cache_read
                    + e.tokens_cache_write_5m + e.tokens_cache_write_1h) AS tokens,
                coalesce(sum(e.cost_usd_micros), 0) AS costUsdMicros,
                max(e.observed_epoch_ms) - min(e.observed_epoch_ms) AS durationMs,
                max(e.model_canonical) AS model,
                max(e.observed_epoch_ms) AS lastEventMs
           FROM usage_events e
           JOIN source_files f ON f.id = e.source_file_id
          WHERE e.session_id = ? AND e.is_sidechain = 1
          GROUP BY e.source_file_id
          ORDER BY lastEventMs DESC`
      ).all(sessionId) as SubagentRow[];
    }

    return this.db.prepare(
      `SELECT coalesce(cs.subagent_label, cs.source_session_key) AS label,
              csr.tokens_total AS tokens,
              coalesce(csr.cost_usd_micros, 0) AS costUsdMicros,
              csr.last_event_epoch_ms - csr.first_event_epoch_ms AS durationMs,
              csr.primary_model AS model,
              csr.last_event_epoch_ms AS lastEventMs
         FROM agent_sessions cs
         JOIN session_rollup csr ON csr.session_id = cs.id
        WHERE cs.source_kind = ? AND cs.root_session_key = ? AND cs.status != 'deleted'
        ORDER BY lastEventMs DESC`
    ).all(session.sourceKind, session.sourceSessionKey) as SubagentRow[];
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
    // 只数主会话：子代理会话（root_session_key 非空）归到主会话，不单独计入今日会话数，
    // 否则 OMP 一天几百个子代理会把这个数字灌爆。
    const dayStart = Date.parse(`${today}T00:00:00`);
    const todaySessions = (this.db.prepare(
      `SELECT count(*) AS n FROM session_rollup sr
         JOIN agent_sessions s ON s.id = sr.session_id
        WHERE sr.last_event_epoch_ms >= ? AND s.root_session_key IS NULL AND s.status != 'deleted'`
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

  trend(from: string, to: string, g: Granularity): TrendBucket[] {
    if (!isAllowed(from, to, g)) {
      throw new Error(`granularity ${g} is not allowed for ${from}..${to}`);
    }

    const rows = g === 'hour' ? this.trendByHour(from, to) : this.trendByDate(from, to, g);
    return fillGaps(rows, from, to, g);
  }

  /// 按 agent 分组的趋势。tokens/花费从 daily_rollup 聚合；会话数必须回
  /// usage_events 数 distinct——rollup 的 sessions_count 按模型分行，求和会重复
  /// （同 kpis 的教训）。distinct 键取「归并后的主会话」：子代理会话通过
  /// coalesce(root_session_key, source_session_key) 折回主会话，口径与 sessionRail 一致。
  agentTrend(from: string, to: string, g: 'day' | 'week' | 'month'): AgentTrendSeries {
    if (!isAllowed(from, to, g)) {
      throw new Error(`granularity ${g} is not allowed for ${from}..${to}`);
    }

    // week 以周一为起点、month 取 YYYY-MM，跟 trendByDate 的桶键完全一致，
    // 由 SQLite 完成——不在 TypeScript 里重算日期。
    const rollupBucket =
      g === 'week' ? `date(usage_date, 'weekday 0', '-6 days')`
      : g === 'month' ? `strftime('%Y-%m', usage_date)`
      : `usage_date`;
    const eventDay = `date(e.observed_epoch_ms / 1000, 'unixepoch', 'localtime')`;
    const eventBucket =
      g === 'week' ? `date(e.observed_epoch_ms / 1000, 'unixepoch', 'localtime', 'weekday 0', '-6 days')`
      : g === 'month' ? `strftime('%Y-%m', e.observed_epoch_ms / 1000, 'unixepoch', 'localtime')`
      : eventDay;

    const usage = this.db.prepare(
      `SELECT ${rollupBucket} AS bucket,
              provider_id AS providerId,
              coalesce(sum(tokens_input + tokens_output + tokens_cache_read
                           + tokens_cache_write_5m + tokens_cache_write_1h), 0) AS tokens,
              coalesce(sum(cost_usd_micros), 0) AS costUsdMicros
         FROM daily_rollup
        WHERE usage_date BETWEEN ? AND ?
     GROUP BY bucket, providerId`
    ).all(from, to) as Array<Omit<AgentTrendRow, 'sessions'>>;

    const sessions = this.db.prepare(
      `SELECT ${eventBucket} AS bucket,
              s.provider_id AS providerId,
              count(DISTINCT s.source_kind || ':' || coalesce(s.root_session_key, s.source_session_key)) AS sessions
         FROM usage_events e
         JOIN agent_sessions s ON s.id = e.session_id
        WHERE ${eventDay} BETWEEN ? AND ?
     GROUP BY bucket, providerId`
    ).all(from, to) as Array<{ bucket: string; providerId: string; sessions: number }>;

    const byKey = new Map<string, AgentTrendRow>();
    for (const u of usage) {
      byKey.set(`${u.bucket}|${u.providerId}`, { ...u, sessions: 0 });
    }
    for (const s of sessions) {
      const key = `${s.bucket}|${s.providerId}`;
      const row = byKey.get(key);
      if (row) {
        row.sessions = s.sessions;
      } else {
        byKey.set(key, { bucket: s.bucket, providerId: s.providerId, tokens: 0, costUsdMicros: 0, sessions: s.sessions });
      }
    }

    return {
      granularity: g,
      from,
      to,
      buckets: agentTrendBuckets(from, to, g),
      rows: [...byKey.values()].sort((a, b) =>
        a.bucket === b.bucket ? a.providerId.localeCompare(b.providerId) : a.bucket.localeCompare(b.bucket))
    };
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

  /// 一格一天。`sessions` 走 usage_events 的 count(distinct session_id)，
  /// 【不能】对 daily_rollup.sessions_count 求和——同一会话当天用两个模型会占两行
  /// （RollupBuilder.swift L44-49）。热力图不补空洞：没数据的那天就是 level 0，
  /// 由组件按日历网格摆放，无需 repository 造零行。
  ///
  /// sessions 曾用「按 d.usage_date 相关的子查询」逐天现算，371 天 × usage_events
  /// 全表扫描一遍——生产库 26 万行事件时实测单次查询 6 秒多，同步卡住 Electron 主进程，
  /// 点一下刷新整个应用能卡住好几秒。改成子查询先按天一次性 GROUP BY 聚合、
  /// 再 LEFT JOIN 回来，usage_events 只扫一遍：同一份生产数据从 6113ms 降到 160ms。
  heatmap(from: string, to: string): HeatmapDay[] {
    return this.db.prepare(
      `SELECT d.usage_date AS date,
              coalesce(sum(d.tokens_input + d.tokens_output + d.tokens_cache_read
                           + d.tokens_cache_write_5m + d.tokens_cache_write_1h), 0) AS tokens,
              coalesce(sum(d.cost_usd_micros), 0) AS costUsdMicros,
              coalesce(max(s.sessions), 0) AS sessions,
              coalesce(sum(d.events_count), 0) AS events
         FROM daily_rollup d
         LEFT JOIN (
              SELECT date(e.observed_epoch_ms / 1000, 'unixepoch', 'localtime') AS usage_date,
                     count(DISTINCT e.session_id) AS sessions
                FROM usage_events e
               WHERE date(e.observed_epoch_ms / 1000, 'unixepoch', 'localtime') BETWEEN ? AND ?
            GROUP BY usage_date
         ) s ON s.usage_date = d.usage_date
        WHERE d.usage_date BETWEEN ? AND ?
     GROUP BY d.usage_date ORDER BY d.usage_date`
    ).all(from, to, from, to) as HeatmapDay[];
  }

  /// `sortBy` 是联合类型，orderBy 由它派生——不拼接用户输入的排序列。
  /// 每个模型都带上 costUnknownEvents：成本 0 到底是免费还是未定价，UI 必须能区分。
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
}

const ZERO = { input: 0, cacheWrite: 0, cacheRead: 0, output: 0 };

/// 空桶必须补齐：缺一天不是「那天不存在」，是「那天用量为零」，X 轴不能有洞。
/// 逐桶推进走共享的 localBucketKeys（本地日历，DST 安全），不在这里重算日期。
/// agentTrend 的完整桶轴。day 复用共享的 localBucketKeys（DST 安全）；
/// week 从 from 所在周一起每 7 天一桶（本地日历步进，与 SQL 的
/// 'weekday 0','-6 days' 同锚）；month 是纯 YYYY-MM 字符串数学，无时区参与。
function agentTrendBuckets(from: string, to: string, g: 'day' | 'week' | 'month'): string[] {
  if (g === 'day') return [...localBucketKeys(from, to, 'day')];

  if (g === 'week') {
    const [fy, fm, fd] = from.split('-').map(Number);
    const cursor = new Date(fy, fm - 1, fd);
    // getDay(): 0=周日 → 回退 6 天；1=周一 → 回退 0 天。
    cursor.setDate(cursor.getDate() - ((cursor.getDay() + 6) % 7));
    const out: string[] = [];
    for (;;) {
      const key = `${cursor.getFullYear()}-${pad2(cursor.getMonth() + 1)}-${pad2(cursor.getDate())}`;
      if (key > to) break;
      out.push(key);
      cursor.setDate(cursor.getDate() + 7);
    }
    return out;
  }

  const out: string[] = [];
  let [y, m] = from.slice(0, 7).split('-').map(Number);
  const end = to.slice(0, 7);
  for (;;) {
    const key = `${y}-${pad2(m)}`;
    out.push(key);
    if (key >= end) break;
    m += 1;
    if (m > 12) {
      m = 1;
      y += 1;
    }
  }
  return out;
}

function fillGaps(rows: TrendBucket[], from: string, to: string, g: Granularity): TrendBucket[] {
  if (g === 'week' || g === 'month') return rows;   // 周/月的桶键不是连续日期，交给 SQL 的结果原样返回
  const byBucket = new Map(rows.map(r => [r.bucket, r]));
  const out: TrendBucket[] = [];
  for (const key of localBucketKeys(from, to, g)) {
    out.push(byBucket.get(key) ?? { bucket: key, ...ZERO });
  }
  return out;
}
