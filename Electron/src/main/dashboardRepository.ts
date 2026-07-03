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

export class DashboardRepository {
  constructor(private readonly db: Database.Database) {}

  dailyUsage(filter: DailyUsageFilter): DailyUsageRow[] {
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
        filter.from,
        filter.to,
        filter.providerId ?? null,
        filter.providerId ?? null,
        filter.projectId ?? null,
        filter.projectId ?? null
      ) as DailyUsageRow[];
  }
}
