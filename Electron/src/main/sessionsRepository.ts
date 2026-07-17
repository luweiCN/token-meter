import type Database from 'better-sqlite3';

export interface SessionsFilter {
  limit?: number;
  offset?: number;
  providerId?: string;
  /// projects 表主键集合（多选筛选）；空数组或缺省 = 不筛选。
  projectIds?: number[];
  /// 本地日范围 'YYYY-MM-DD'（闭区间）：列出该范围内有活动的会话（活动区间相交）。
  dateFrom?: string;
  dateTo?: string;
  /// 标题 / 主模型的子串搜索（大小写不敏感）。
  search?: string;
  sortBy?: 'tokens' | 'cost' | 'start';
  sortDir?: 'asc' | 'desc';
}

/// 会话列表一行（OpenDesign 稿 view-sessions）。只列主会话；token/成本是
/// 【含子代理的合计】，口径与总览页 sessionRail 一致。不携带任何提示词正文。
export interface SessionItem {
  id: number;
  sessionKey: string;
  sourceKind: string;
  providerId: string | null;
  projectId: number | null;
  projectDisplayName: string | null;
  modelName: string | null;
  title: string | null;
  firstEventEpochMs: number;
  lastEventEpochMs: number;
  tokensTotal: number;
  costUsdMicros: number;
  costUnknownEvents: number;
  /// 主会话自己的 usage 事件数（不含子代理会话的）。
  eventsCount: number;
  subagentCount: number;
}

export interface SessionsResult {
  items: SessionItem[];
  total: number;
}

export interface SessionProjectOption {
  id: number;
  displayName: string;
  sessionsCount: number;
}

/// 会话页直方图：按事件实际发生的本地日 × 主会话 provider 聚合。
/// 口径与菜单栏「今日」一致（事件日）；子代理事件归并进主会话的
/// provider，sessions = 当天有活动的主会话数（跨天会话每天都计入）。
export interface SessionTrendRow {
  bucket: string;
  providerId: string;
  tokens: number;
  costUsdMicros: number;
  sessions: number;
}

export interface SessionTrendResult {
  buckets: string[];
  rows: SessionTrendRow[];
}

interface CountRow {
  count: number;
}

const SORT_EXPR: Record<NonNullable<SessionsFilter['sortBy']>, string> = {
  tokens: 'sr.tokens_total + coalesce(sub.tokens, 0)',
  cost: 'coalesce(sr.cost_usd_micros, 0) + coalesce(sub.cost, 0)',
  start: 'sr.first_event_epoch_ms'
};

/// 与 overviewRepository.sessionRail 同款的子代理归并/侧链聚合（spec §6）。
const SUB_JOINS = `
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
           SELECT e.session_id AS sid, count(DISTINCT e.source_file_id) AS cnt
             FROM usage_events e
            WHERE e.is_sidechain = 1
         GROUP BY e.session_id
         ) sc ON sc.sid = s.id`;

export class SessionsRepository {
  constructor(private readonly db: Database.Database) {}

  query(filter: unknown = {}): SessionsResult {
    const f = validateSessionsFilter(filter);
    const limit = f.limit ?? 50;
    const offset = f.offset ?? 0;
    const providerId = f.providerId ?? null;
    const projectIds = f.projectIds ?? [];
    const search = f.search ? `%${f.search.trim()}%` : null;
    // 日期范围按会话的活动区间与 [from, to] 相交（会话可能跨天）。
    const rangeStart = f.dateFrom ? Date.parse(`${f.dateFrom}T00:00:00`) : null;
    const rangeEnd = f.dateTo ? Date.parse(`${f.dateTo}T00:00:00`) + 86_400_000 : null;
    const sortExpr = SORT_EXPR[f.sortBy ?? 'start'];
    const sortDir = f.sortDir === 'asc' ? 'ASC' : 'DESC';

    // 主会话口径（root_session_key IS NULL）+ 有 usage 数据（INNER JOIN rollup）：
    // 子代理会话不单独成行，经 sub 聚合折进父会话，明细走 subagentBreakdown 下钻。
    const projectClause = projectIds.length > 0
      ? ` AND s.project_id IN (${projectIds.map(() => '?').join(',')})`
      : '';
    const where = `
         WHERE s.status != 'deleted'
           AND s.root_session_key IS NULL
           AND (? IS NULL OR s.provider_id = ?)${projectClause}
           AND (? IS NULL OR max(sr.last_event_epoch_ms, coalesce(sub.last_event, 0)) >= ?)
           AND (? IS NULL OR sr.first_event_epoch_ms < ?)
           AND (? IS NULL OR s.title LIKE ? OR sr.primary_model LIKE ?)`;
    const whereParams = [
      providerId, providerId,
      ...projectIds,
      rangeStart, rangeStart,
      rangeEnd, rangeEnd,
      search, search, search
    ];

    const items = this.db
      .prepare(
        `SELECT s.id AS id,
                s.source_session_key AS sessionKey,
                s.source_kind AS sourceKind,
                s.provider_id AS providerId,
                s.project_id AS projectId,
                p.display_name AS projectDisplayName,
                sr.primary_model AS modelName,
                s.title AS title,
                sr.first_event_epoch_ms AS firstEventEpochMs,
                max(sr.last_event_epoch_ms, coalesce(sub.last_event, 0)) AS lastEventEpochMs,
                sr.tokens_total + coalesce(sub.tokens, 0) AS tokensTotal,
                coalesce(sr.cost_usd_micros, 0) + coalesce(sub.cost, 0) AS costUsdMicros,
                sr.cost_unknown_events AS costUnknownEvents,
                sr.events_count AS eventsCount,
                coalesce(sub.cnt, 0) + coalesce(sc.cnt, 0) AS subagentCount
         FROM agent_sessions s
         JOIN session_rollup sr ON sr.session_id = s.id
         LEFT JOIN projects p ON p.id = s.project_id
         ${SUB_JOINS}
         ${where}
         ORDER BY ${sortExpr} ${sortDir}, s.id DESC
         LIMIT ? OFFSET ?`
      )
      .all(...whereParams, limit, offset) as SessionItem[];

    const total = this.db
      .prepare(
        `SELECT count(*) AS count
         FROM agent_sessions s
         JOIN session_rollup sr ON sr.session_id = s.id
         ${SUB_JOINS}
         ${where}`
      )
      .get(...whereParams) as CountRow;

    return { items, total: total.count };
  }

  /// 会话页直方图数据：跟随 query 同一套筛选（provider/项目/日期/搜索），
  /// 但按【事件日】聚合——曾按会话起始日分桶，跨天长会话把当天用量全记去
  /// 起始那天，选「今天」时与菜单栏差出数量级（实测 900K vs 5 亿）。
  trend(filter: unknown = {}): SessionTrendResult {
    const f = validateSessionsFilter(filter);
    const providerId = f.providerId ?? null;
    const projectIds = f.projectIds ?? [];
    const search = f.search ? `%${f.search.trim()}%` : null;
    // 缺省范围 = 近 30 个本地日（含今天）。
    const fromDefault = new Date();
    fromDefault.setHours(0, 0, 0, 0);
    fromDefault.setDate(fromDefault.getDate() - 29);
    const rangeStart = f.dateFrom ? Date.parse(`${f.dateFrom}T00:00:00`) : fromDefault.getTime();
    // dateTo 是闭区间日 → +1 天取开区间上界；缺省时 now 本身就是上界。
    const rangeEnd = f.dateTo ? Date.parse(`${f.dateTo}T00:00:00`) + 86_400_000 : Date.now();

    const projectClause = projectIds.length > 0
      ? ` AND s.project_id IN (${projectIds.map(() => '?').join(',')})`
      : '';
    // mains = 通过筛选的主会话；members = 主会话自身 + 其子代理会话，
    // 事件经 members 归并到主会话（provider 与活跃会话数都按主会话计）。
    const rows = this.db
      .prepare(
        `WITH mains AS (
           SELECT s.id AS id,
                  s.source_kind AS source_kind,
                  s.source_session_key AS session_key,
                  coalesce(s.provider_id, s.source_kind) AS pid
             FROM agent_sessions s
             JOIN session_rollup sr ON sr.session_id = s.id
            WHERE s.status != 'deleted'
              AND s.root_session_key IS NULL
              AND (? IS NULL OR s.provider_id = ?)${projectClause}
              AND (? IS NULL OR s.title LIKE ? OR sr.primary_model LIKE ?)
         ),
         members AS (
           SELECT id AS session_id, id AS main_id FROM mains
           UNION ALL
           SELECT c.id, m.id
             FROM agent_sessions c
             JOIN mains m ON c.source_kind = m.source_kind AND c.root_session_key = m.session_key
            WHERE c.status != 'deleted'
         )
         SELECT date(e.observed_epoch_ms / 1000, 'unixepoch', 'localtime') AS bucket,
                m.pid AS providerId,
                coalesce(sum(e.tokens_total), 0) AS tokens,
                coalesce(sum(e.cost_usd_micros), 0) AS costUsdMicros,
                count(DISTINCT mem.main_id) AS sessions
           FROM usage_events e
           JOIN members mem ON mem.session_id = e.session_id
           JOIN mains m ON m.id = mem.main_id
          WHERE e.observed_epoch_ms >= ?
            AND e.observed_epoch_ms < ?
          GROUP BY bucket, providerId
          ORDER BY bucket ASC, providerId ASC`
      )
      .all(
        providerId, providerId,
        ...projectIds,
        search, search, search,
        rangeStart, rangeEnd
      ) as SessionTrendRow[];

    const buckets: string[] = [];
    const cursor = new Date(rangeStart);
    cursor.setHours(12, 0, 0, 0); // 正午推进，跨夏令时不跳日
    const lastMs = rangeEnd - 1;
    for (let i = 0; i < 1000; i += 1) {
      const day = localDayOf(cursor.getTime());
      buckets.push(day);
      if (day === localDayOf(lastMs)) break;
      cursor.setDate(cursor.getDate() + 1);
    }
    return { buckets, rows };
  }

  /// 筛选下拉的项目清单：只含有主会话数据的项目，按名称排序。
  projects(): SessionProjectOption[] {
    return this.db
      .prepare(
        `SELECT p.id AS id,
                p.display_name AS displayName,
                count(*) AS sessionsCount
         FROM agent_sessions s
         JOIN session_rollup sr ON sr.session_id = s.id
         JOIN projects p ON p.id = s.project_id
         WHERE s.status != 'deleted' AND s.root_session_key IS NULL
         GROUP BY p.id
         ORDER BY p.display_name ASC`
      )
      .all() as SessionProjectOption[];
  }
}

function localDayOf(epochMs: number): string {
  const d = new Date(epochMs);
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

function validateSessionsFilter(filter: unknown): SessionsFilter {
  if (typeof filter !== 'object' || filter === null || Array.isArray(filter)) {
    throw new Error('sessions filter must be an object');
  }

  const candidate = filter as Record<string, unknown>;
  if (candidate.limit !== undefined && (!Number.isInteger(candidate.limit) || (candidate.limit as number) < 1)) {
    throw new Error('sessions filter limit must be a positive integer');
  }
  if (candidate.offset !== undefined && (!Number.isInteger(candidate.offset) || (candidate.offset as number) < 0)) {
    throw new Error('sessions filter offset must be a non-negative integer');
  }
  if (candidate.providerId !== undefined && (typeof candidate.providerId !== 'string' || candidate.providerId.length === 0)) {
    throw new Error('sessions filter providerId must be a non-empty string');
  }
  if (candidate.projectIds !== undefined
    && (!Array.isArray(candidate.projectIds) || !candidate.projectIds.every((id) => Number.isInteger(id)))) {
    throw new Error('sessions filter projectIds must be an array of integers');
  }
  for (const key of ['dateFrom', 'dateTo'] as const) {
    if (candidate[key] !== undefined && (typeof candidate[key] !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(candidate[key] as string))) {
      throw new Error(`sessions filter ${key} must be YYYY-MM-DD`);
    }
  }
  if (candidate.search !== undefined && typeof candidate.search !== 'string') {
    throw new Error('sessions filter search must be a string');
  }
  if (candidate.sortBy !== undefined && !(candidate.sortBy === 'tokens' || candidate.sortBy === 'cost' || candidate.sortBy === 'start')) {
    throw new Error('sessions filter sortBy must be tokens | cost | start');
  }
  if (candidate.sortDir !== undefined && !(candidate.sortDir === 'asc' || candidate.sortDir === 'desc')) {
    throw new Error('sessions filter sortDir must be asc | desc');
  }

  return {
    limit: candidate.limit === undefined ? undefined : Math.min(candidate.limit as number, 200),
    offset: candidate.offset === undefined ? undefined : candidate.offset as number,
    providerId: candidate.providerId as string | undefined,
    projectIds: candidate.projectIds as number[] | undefined,
    dateFrom: candidate.dateFrom as string | undefined,
    dateTo: candidate.dateTo as string | undefined,
    search: candidate.search === undefined || (candidate.search as string).trim() === ''
      ? undefined
      : (candidate.search as string),
    sortBy: candidate.sortBy as SessionsFilter['sortBy'],
    sortDir: candidate.sortDir as SessionsFilter['sortDir']
  };
}
