import type Database from 'better-sqlite3';
import { isAllowed, type Granularity } from './granularity.js';

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

export interface TrendBucket {
  bucket: string;
  input: number;
  cacheWrite: number;
  cacheRead: number;
  output: number;
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
}

const ZERO = { input: 0, cacheWrite: 0, cacheRead: 0, output: 0 };

/// 空桶必须补齐：缺一天不是「那天不存在」，是「那天用量为零」，X 轴不能有洞。
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
