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
