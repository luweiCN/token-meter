import type Database from 'better-sqlite3';

export interface DailyUsageFilter {
  from: string;
  to: string;
  providerId?: string;
  projectId?: number;
}

export interface DailyUsageRow {
  usageDate: string;
  providerId: string;
  projectId: number | null;
  sourceKind: string;
  tokensTotal: number;
  sessionsCount: number;
  costUsdMicros: number;
}

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


  dailyUsage(filter: unknown): DailyUsageRow[] {
    const validatedFilter = validateDailyUsageFilter(filter);
    return this.db
      .prepare(
        `SELECT usage_date AS usageDate,
                provider_id AS providerId,
                project_id AS projectId,
                source_kind AS sourceKind,
                tokens_input + tokens_output + tokens_reasoning + tokens_cache_read + tokens_cache_write AS tokensTotal,
                sessions_count AS sessionsCount,
                total_cost_usd_micros AS costUsdMicros
         FROM provider_daily_usage
         WHERE usage_date BETWEEN ? AND ?
           AND (? IS NULL OR provider_id = ?)
           AND (? IS NULL OR project_id = ?)
         ORDER BY usage_date ASC, provider_id ASC, source_kind ASC`
      )
      .all(
        validatedFilter.from,
        validatedFilter.to,
        validatedFilter.providerId ?? null,
        validatedFilter.providerId ?? null,
        validatedFilter.projectId ?? null,
        validatedFilter.projectId ?? null
      ) as DailyUsageRow[];
  }
}

function validateDailyUsageFilter(filter: unknown): DailyUsageFilter {
  if (typeof filter !== 'object' || filter === null || Array.isArray(filter)) {
    throw new Error('dailyUsage filter must be an object');
  }

  const candidate = filter as Record<string, unknown>;
  if (!isISODate(candidate.from) || !isISODate(candidate.to)) {
    throw new Error('dailyUsage filter requires YYYY-MM-DD from/to dates');
  }
  if (candidate.from > candidate.to) {
    throw new Error('dailyUsage filter from date must be before or equal to to date');
  }
  if (candidate.providerId !== undefined && (typeof candidate.providerId !== 'string' || candidate.providerId.length === 0)) {
    throw new Error('dailyUsage filter providerId must be a non-empty string');
  }
  if (candidate.projectId !== undefined && (!Number.isInteger(candidate.projectId) || (candidate.projectId as number) <= 0)) {
    throw new Error('dailyUsage filter projectId must be a positive integer');
  }

  return {
    from: candidate.from,
    to: candidate.to,
    providerId: candidate.providerId,
    projectId: candidate.projectId
  } as DailyUsageFilter;
}

function isISODate(value: unknown): value is string {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const date = new Date(`${value}T00:00:00.000Z`);
  return !Number.isNaN(date.getTime()) && date.toISOString().slice(0, 10) === value;
}
