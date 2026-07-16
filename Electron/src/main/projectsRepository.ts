import type Database from 'better-sqlite3';

/// 项目卡片一枚（OpenDesign 稿 view-projects）。成本/token 从 daily_rollup
/// 按 project_id 聚合；会话数是主会话口径（与会话页一致）。
export interface ProjectCard {
  id: number;
  displayName: string;
  /// 已脱敏：~ 开头的相对家目录路径。
  pathLabel: string;
  sessionsCount: number;
  costUsdMicros: number;
  costUnknownEvents: number;
  tokensTotal: number;
  /// 近 14 天每日花费（USD micros），从今天-13 到今天按日对齐，缺日补 0。
  spark: number[];
  lastActiveDate: string | null;
}

export interface ProjectDetail {
  id: number;
  displayName: string;
  pathLabel: string;
  sessionsCount: number;
  /// 有用量的天数（distinct usage_date）与最近活跃日。
  activeDays: number;
  lastActiveDate: string | null;
  costUsdMicros: number;
  costUnknownEvents: number;
  tokensTotal: number;
  /// 近 14 天 [date, costUsdMicros]，含补零。
  dailyCost: Array<{ date: string; costUsdMicros: number }>;
  models: Array<{ model: string; tokens: number; costUsdMicros: number }>;
  agents: Array<{ providerId: string; tokens: number; costUsdMicros: number }>;
}

const SPARK_DAYS = 14;

export class ProjectsRepository {
  constructor(
    private readonly db: Database.Database,
    private readonly now: () => number = Date.now
  ) {}

  list(): ProjectCard[] {
    const totals = this.db
      .prepare(
        `SELECT p.id AS id,
                p.display_name AS displayName,
                p.canonical_path AS canonicalPath,
                coalesce(sum(d.cost_usd_micros), 0) AS costUsdMicros,
                coalesce(sum(d.cost_unknown_events), 0) AS costUnknownEvents,
                coalesce(sum(d.tokens_input + d.tokens_output + d.tokens_cache_read
                             + d.tokens_cache_write_5m + d.tokens_cache_write_1h), 0) AS tokensTotal,
                max(d.usage_date) AS lastActiveDate
         FROM projects p
         JOIN daily_rollup d ON d.project_id = p.id
         GROUP BY p.id
         ORDER BY costUsdMicros DESC, tokensTotal DESC`
      )
      .all() as Array<Omit<ProjectCard, 'pathLabel' | 'sessionsCount' | 'spark'> & { canonicalPath: string }>;

    const sessionCounts = new Map(
      (this.db
        .prepare(
          `SELECT s.project_id AS pid, count(*) AS n
           FROM agent_sessions s
           JOIN session_rollup sr ON sr.session_id = s.id
           WHERE s.status != 'deleted' AND s.root_session_key IS NULL AND s.project_id IS NOT NULL
           GROUP BY s.project_id`
        )
        .all() as Array<{ pid: number; n: number }>).map((r) => [r.pid, r.n])
    );

    const from = this.localDate(-(SPARK_DAYS - 1));
    const sparkRows = this.db
      .prepare(
        `SELECT project_id AS pid, usage_date AS date, sum(cost_usd_micros) AS cost
         FROM daily_rollup
         WHERE usage_date >= ? AND project_id IS NOT NULL
         GROUP BY project_id, usage_date`
      )
      .all(from) as Array<{ pid: number; date: string; cost: number }>;
    const sparkByProject = new Map<number, Map<string, number>>();
    for (const row of sparkRows) {
      let inner = sparkByProject.get(row.pid);
      if (!inner) {
        inner = new Map();
        sparkByProject.set(row.pid, inner);
      }
      inner.set(row.date, row.cost);
    }
    const dates = this.lastDates(SPARK_DAYS);

    return totals.map(({ canonicalPath, ...rest }) => ({
      ...rest,
      pathLabel: redactPath(canonicalPath),
      sessionsCount: sessionCounts.get(rest.id) ?? 0,
      spark: dates.map((date) => sparkByProject.get(rest.id)?.get(date) ?? 0)
    }));
  }

  detail(projectId: number): ProjectDetail | null {
    const base = this.db
      .prepare(`SELECT id, display_name AS displayName, canonical_path AS canonicalPath FROM projects WHERE id = ?`)
      .get(projectId) as { id: number; displayName: string; canonicalPath: string } | undefined;
    if (!base) return null;

    const totals = this.db
      .prepare(
        `SELECT coalesce(sum(cost_usd_micros), 0) AS costUsdMicros,
                coalesce(sum(cost_unknown_events), 0) AS costUnknownEvents,
                coalesce(sum(tokens_input + tokens_output + tokens_cache_read
                             + tokens_cache_write_5m + tokens_cache_write_1h), 0) AS tokensTotal,
                count(DISTINCT usage_date) AS activeDays,
                max(usage_date) AS lastActiveDate
         FROM daily_rollup WHERE project_id = ?`
      )
      .get(projectId) as {
        costUsdMicros: number; costUnknownEvents: number; tokensTotal: number;
        activeDays: number; lastActiveDate: string | null;
      };

    const counts = this.db
      .prepare(
        `SELECT sum(CASE WHEN s.root_session_key IS NULL THEN 1 ELSE 0 END) AS mains
         FROM agent_sessions s
         JOIN session_rollup sr ON sr.session_id = s.id
         WHERE s.status != 'deleted' AND s.project_id = ?`
      )
      .get(projectId) as { mains: number | null };

    const from = this.localDate(-(SPARK_DAYS - 1));
    const dailyRows = new Map(
      (this.db
        .prepare(
          `SELECT usage_date AS date, sum(cost_usd_micros) AS cost
           FROM daily_rollup WHERE project_id = ? AND usage_date >= ?
           GROUP BY usage_date`
        )
        .all(projectId, from) as Array<{ date: string; cost: number }>).map((r) => [r.date, r.cost])
    );

    const models = this.db
      .prepare(
        `SELECT model_canonical AS model,
                coalesce(sum(tokens_input + tokens_output + tokens_cache_read
                             + tokens_cache_write_5m + tokens_cache_write_1h), 0) AS tokens,
                coalesce(sum(cost_usd_micros), 0) AS costUsdMicros
         FROM daily_rollup WHERE project_id = ?
         GROUP BY model_canonical ORDER BY tokens DESC LIMIT 8`
      )
      .all(projectId) as ProjectDetail['models'];

    const agents = this.db
      .prepare(
        `SELECT provider_id AS providerId,
                coalesce(sum(tokens_input + tokens_output + tokens_cache_read
                             + tokens_cache_write_5m + tokens_cache_write_1h), 0) AS tokens,
                coalesce(sum(cost_usd_micros), 0) AS costUsdMicros
         FROM daily_rollup WHERE project_id = ?
         GROUP BY provider_id ORDER BY tokens DESC`
      )
      .all(projectId) as ProjectDetail['agents'];

    return {
      id: base.id,
      displayName: base.displayName,
      pathLabel: redactPath(base.canonicalPath),
      sessionsCount: counts.mains ?? 0,
      ...totals,
      dailyCost: this.lastDates(SPARK_DAYS).map((date) => ({ date, costUsdMicros: dailyRows.get(date) ?? 0 })),
      models,
      agents
    };
  }

  private localDate(offsetDays: number): string {
    const d = new Date(this.now() + offsetDays * 86_400_000);
    const pad = (n: number) => String(n).padStart(2, '0');
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
  }

  private lastDates(days: number): string[] {
    return Array.from({ length: days }, (_, i) => this.localDate(i - (days - 1)));
  }
}

/// 与 indexStatusRepository 同旨：绝对家目录路径不出主进程。
function redactPath(path: string): string {
  const match = path.match(/^\/(Users|home)\/[^/]+(?<rest>\/.*)?$/);
  if (match?.groups?.rest !== undefined) return `~${match.groups.rest}`;
  if (match) return '~';
  return path;
}
