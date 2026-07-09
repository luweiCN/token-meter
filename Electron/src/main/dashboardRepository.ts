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
  modelBreakdown: DashboardModelBreakdownRow[];
  providerBreakdown: DashboardProviderBreakdownRow[];
  dailyTrend: DashboardDailyTrendRow[];
}

interface OverviewTotalsRow {
  sessionCount: number;
  totalTokens: number;
  activeModelCount: number;
  totalCostUsdMicros: number;
}


export class DashboardRepository {
  constructor(private readonly db: Database.Database) {}
  overview(): DashboardOverview {
    const totals = this.db
      .prepare(
        `SELECT count(*) AS sessionCount,
                coalesce(sum(u.tokens_total), 0) AS totalTokens,
                count(DISTINCT coalesce(nullif(s.model_name, ''), '未知模型')) AS activeModelCount,
                coalesce(sum(u.cost_usd_micros), 0) AS totalCostUsdMicros
         FROM agent_sessions s
         LEFT JOIN session_usage_latest latest ON latest.session_id = s.id
         LEFT JOIN session_usage u ON u.id = latest.session_usage_id
         WHERE s.status != 'deleted'`
      )
      .get() as OverviewTotalsRow;

    const modelBreakdown = this.db
      .prepare(
        `SELECT coalesce(nullif(s.model_name, ''), '未知模型') AS modelName,
                count(*) AS sessionsCount,
                coalesce(sum(u.tokens_total), 0) AS tokensTotal,
                coalesce(sum(u.cost_usd_micros), 0) AS costUsdMicros
         FROM agent_sessions s
         LEFT JOIN session_usage_latest latest ON latest.session_id = s.id
         LEFT JOIN session_usage u ON u.id = latest.session_usage_id
         WHERE s.status != 'deleted'
         GROUP BY modelName
         ORDER BY tokensTotal DESC, sessionsCount DESC, modelName ASC
         LIMIT 8`
      )
      .all() as DashboardModelBreakdownRow[];

    const providerBreakdown = this.db
      .prepare(
        `SELECT coalesce(nullif(s.provider_id, ''), 'unknown') AS providerId,
                count(*) AS sessionsCount,
                coalesce(sum(u.tokens_total), 0) AS tokensTotal
         FROM agent_sessions s
         LEFT JOIN session_usage_latest latest ON latest.session_id = s.id
         LEFT JOIN session_usage u ON u.id = latest.session_usage_id
         WHERE s.status != 'deleted'
         GROUP BY providerId
         ORDER BY tokensTotal DESC, sessionsCount DESC, providerId ASC`
      )
      .all() as DashboardProviderBreakdownRow[];

    const dailyTrend = this.db
      .prepare(
        `SELECT usage_date AS usageDate,
                sum(tokens_input + tokens_output + tokens_reasoning + tokens_cache_read + tokens_cache_write) AS tokensTotal,
                sum(sessions_count) AS sessionsCount
         FROM provider_daily_usage
         GROUP BY usage_date
         ORDER BY usage_date ASC
         LIMIT 7`
      )
      .all() as DashboardDailyTrendRow[];

    return {
      sessionCount: totals.sessionCount,
      totalTokens: totals.totalTokens,
      activeModelCount: totals.activeModelCount,
      totalCostUsdMicros: totals.totalCostUsdMicros,
      modelBreakdown,
      providerBreakdown,
      dailyTrend
    };
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
