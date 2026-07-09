import type Database from 'better-sqlite3';

export interface DashboardModelBreakdownRow {
  modelName: string;
  sessionsCount: number;
  tokensTotal: number;
  costUsdMicros: number;
}

export interface DashboardProviderBreakdownRow {
  providerId: string;
  sessionsCount: number;
  tokensTotal: number;
}

export interface DashboardDailyTrendRow {
  usageDate: string;
  tokensTotal: number;
  sessionsCount: number;
}

export interface DashboardOverview {
  sessionCount: number;
  totalTokens: number;
  activeModelCount: number;
  totalCostUsdMicros: number;
  costUnknownEvents: number;
  modelBreakdown: DashboardModelBreakdownRow[];
  providerBreakdown: DashboardProviderBreakdownRow[];
  dailyTrend: DashboardDailyTrendRow[];
}

interface OverviewTotalsRow {
  sessionCount: number;
  totalTokens: number;
  activeModelCount: number;
  totalCostUsdMicros: number;
  costUnknownEvents: number;
}


export class DashboardRepository {
  constructor(private readonly db: Database.Database) {}
  overview(): DashboardOverview {
    // Grand totals come from session_rollup: sessions_count in daily_rollup is a distinct
    // count *within its own group* (date × provider × source × project × model), so a
    // session that spans days or models appears in several rows — summing it double-counts.
    // count(*) over session_rollup is the only correct total. cost_usd_micros can be NULL
    // per event, so cost_unknown_events (from daily_rollup) is surfaced too, letting the UI
    // eventually flag a total as partial instead of reading a silently-low number as exact.
    const totals = this.db
      .prepare(
        `SELECT (SELECT count(*) FROM session_rollup) AS sessionCount,
                coalesce((SELECT sum(tokens_total) FROM session_rollup), 0) AS totalTokens,
                (SELECT count(DISTINCT model_canonical) FROM daily_rollup) AS activeModelCount,
                coalesce((SELECT sum(cost_usd_micros) FROM session_rollup), 0) AS totalCostUsdMicros,
                coalesce((SELECT sum(cost_unknown_events) FROM daily_rollup), 0) AS costUnknownEvents`
      )
      .get() as OverviewTotalsRow;

    // sessionsCount here is a per-model approximation: summing across models double-counts
    // a session that used more than one. It is fine for a breakdown but must never be the
    // grand total, which comes from session_rollup above.
    const modelBreakdown = this.db
      .prepare(
        `SELECT model_canonical AS modelName,
                sum(sessions_count) AS sessionsCount,
                sum(tokens_input + tokens_output + tokens_cache_read + tokens_cache_write_5m + tokens_cache_write_1h) AS tokensTotal,
                sum(cost_usd_micros) AS costUsdMicros
         FROM daily_rollup
         GROUP BY model_canonical
         ORDER BY tokensTotal DESC, modelName ASC
         LIMIT 8`
      )
      .all() as DashboardModelBreakdownRow[];

    const providerBreakdown = this.db
      .prepare(
        `SELECT provider_id AS providerId,
                sum(sessions_count) AS sessionsCount,
                sum(tokens_input + tokens_output + tokens_cache_read + tokens_cache_write_5m + tokens_cache_write_1h) AS tokensTotal
         FROM daily_rollup
         GROUP BY provider_id
         ORDER BY tokensTotal DESC, providerId ASC`
      )
      .all() as DashboardProviderBreakdownRow[];

    // sessionsCount is max(), not sum(): a session that used two models lands in two rows
    // for the day, so summing would double-count. max() reports the largest single-model
    // group rather than pretending to be a distinct daily total.
    const dailyTrend = this.db
      .prepare(
        `SELECT usage_date AS usageDate,
                sum(tokens_input + tokens_output + tokens_cache_read + tokens_cache_write_5m + tokens_cache_write_1h) AS tokensTotal,
                max(sessions_count) AS sessionsCount
         FROM daily_rollup
         GROUP BY usage_date
         ORDER BY usage_date ASC
         LIMIT 30`
      )
      .all() as DashboardDailyTrendRow[];

    return { ...totals, modelBreakdown, providerBreakdown, dailyTrend };
  }
}
