import type Database from 'better-sqlite3';

export interface ModelsFilter {
  /// 毫秒时间戳,闭区间。时间点精度是这个维度的存在理由:
  /// 「额度刷新时刻 → 周期结束」的用量统计(用户场景),天粒度装不下。
  fromEpochMs?: number;
  toEpochMs?: number;
  /// 模型名子串搜索(大小写不敏感)。
  search?: string;
  sortBy?: 'tokens' | 'cost' | 'events' | 'lastUsed';
  sortDir?: 'asc' | 'desc';
}

export interface ModelItem {
  model: string;
  tokensTotal: number;
  costUsdMicros: number;
  costUnknownEvents: number;
  eventsCount: number;
  /// 归并口径的会话数(子代理折进主会话,键与 daily_active_sessions 一致)。
  sessionsCount: number;
  /// 用过该模型的 agent(provider_id 或 source_kind 兜底),字典序。
  agents: string[];
  firstUsedEpochMs: number;
  lastUsedEpochMs: number;
}

export interface ModelsResult {
  items: ModelItem[];
}

/// 模型用量趋势（模型页直方图）：本地日 × model_canonical 的 token 聚合。
export interface ModelTrendRow {
  bucket: string;
  model: string;
  tokens: number;
}

export interface ModelTrendResult {
  /// 连续铺满范围的本地日序列（含无数据日，直方图空桶也占位）。
  buckets: string[];
  rows: ModelTrendRow[];
}

/// 'YYYY-MM-DD'（本地时区）。
export function localDay(epochMs: number): string {
  const d = new Date(epochMs);
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

/// 连续本地日序列 [fromDay, toDay]。
export function dayBuckets(fromEpochMs: number, toEpochMs: number): string[] {
  const buckets: string[] = [];
  const cursor = new Date(fromEpochMs);
  cursor.setHours(12, 0, 0, 0); // 正午推进，跨夏令时不会跳日
  const last = localDay(toEpochMs);
  for (let i = 0; i < 1000; i += 1) {
    const day = localDay(cursor.getTime());
    buckets.push(day);
    if (day === last) break;
    cursor.setDate(cursor.getDate() + 1);
  }
  return buckets;
}

/// 缺省范围 = 近 30 个本地日（含今天）。
export function defaultTrendRange(now = Date.now()): { fromEpochMs: number; toEpochMs: number } {
  const from = new Date(now);
  from.setHours(0, 0, 0, 0);
  from.setDate(from.getDate() - 29);
  return { fromEpochMs: from.getTime(), toEpochMs: now };
}

const SORT_EXPR: Record<NonNullable<ModelsFilter['sortBy']>, string> = {
  tokens: 'tokensTotal',
  cost: 'costUsdMicros',
  events: 'eventsCount',
  lastUsed: 'lastUsedEpochMs'
};

interface ModelRow {
  model: string;
  tokensTotal: number;
  costUsdMicros: number;
  costUnknownEvents: number;
  eventsCount: number;
  sessionsCount: number;
  agentsConcat: string | null;
  firstUsedEpochMs: number;
  lastUsedEpochMs: number;
}

/// 模型维度统计:直接聚合 usage_events(唯一有毫秒时间戳的表),
/// 项目/会话维度之外的第三面板。model_canonical 已在扫描端归一
/// (供应商前缀剥离),这里不再做任何名字加工。
export class ModelsRepository {
  constructor(private readonly db: Database.Database) {}

  query(filter: ModelsFilter): ModelsResult {
    const sortBy = SORT_EXPR[filter.sortBy ?? 'tokens'];
    const sortDir = filter.sortDir === 'asc' ? 'ASC' : 'DESC';

    const rows = this.db.prepare(
      `SELECT e.model_canonical AS model,
              coalesce(sum(e.tokens_total), 0) AS tokensTotal,
              coalesce(sum(e.cost_usd_micros), 0) AS costUsdMicros,
              sum(CASE WHEN e.cost_source = 'unknown' THEN 1 ELSE 0 END) AS costUnknownEvents,
              count(*) AS eventsCount,
              count(DISTINCT s.source_kind || ':' || coalesce(s.root_session_key, s.source_session_key)) AS sessionsCount,
              group_concat(DISTINCT coalesce(s.provider_id, s.source_kind)) AS agentsConcat,
              min(e.observed_epoch_ms) AS firstUsedEpochMs,
              max(e.observed_epoch_ms) AS lastUsedEpochMs
         FROM usage_events e
         JOIN agent_sessions s ON s.id = e.session_id
        WHERE e.model_canonical IS NOT NULL
          AND (? IS NULL OR e.observed_epoch_ms >= ?)
          AND (? IS NULL OR e.observed_epoch_ms <= ?)
          AND (? IS NULL OR instr(lower(e.model_canonical), lower(?)) > 0)
     GROUP BY e.model_canonical
     ORDER BY ${sortBy} ${sortDir}, model ASC`
    ).all(
      filter.fromEpochMs ?? null, filter.fromEpochMs ?? null,
      filter.toEpochMs ?? null, filter.toEpochMs ?? null,
      filter.search ?? null, filter.search ?? null
    ) as ModelRow[];

    return {
      items: rows.map((row) => ({
        model: row.model,
        tokensTotal: row.tokensTotal,
        costUsdMicros: row.costUsdMicros,
        costUnknownEvents: row.costUnknownEvents,
        eventsCount: row.eventsCount,
        sessionsCount: row.sessionsCount,
        agents: (row.agentsConcat ?? '').split(',').filter(Boolean).sort(),
        firstUsedEpochMs: row.firstUsedEpochMs,
        lastUsedEpochMs: row.lastUsedEpochMs
      }))
    };
  }

  /// 模型页直方图数据：跟随 query 同一套筛选（时间范围 + 模型名搜索），
  /// 本地日分桶。TopN/「其他」归并在前端做（与份额条共用同一份 Top6 名单）。
  trend(filter: ModelsFilter): ModelTrendResult {
    const range = filter.fromEpochMs === undefined && filter.toEpochMs === undefined
      ? defaultTrendRange()
      : {
          fromEpochMs: filter.fromEpochMs ?? defaultTrendRange().fromEpochMs,
          toEpochMs: filter.toEpochMs ?? Date.now()
        };

    const rows = this.db.prepare(
      `SELECT date(e.observed_epoch_ms / 1000, 'unixepoch', 'localtime') AS bucket,
              e.model_canonical AS model,
              coalesce(sum(e.tokens_total), 0) AS tokens
         FROM usage_events e
        WHERE e.model_canonical IS NOT NULL
          AND e.observed_epoch_ms >= ?
          AND e.observed_epoch_ms <= ?
          AND (? IS NULL OR instr(lower(e.model_canonical), lower(?)) > 0)
     GROUP BY bucket, model
     ORDER BY bucket ASC, model ASC`
    ).all(
      range.fromEpochMs, range.toEpochMs,
      filter.search ?? null, filter.search ?? null
    ) as ModelTrendRow[];

    return { buckets: dayBuckets(range.fromEpochMs, range.toEpochMs), rows };
  }
}
