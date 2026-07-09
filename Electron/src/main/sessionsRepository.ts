import type Database from 'better-sqlite3';

export interface SessionsFilter {
  limit?: number;
  offset?: number;
  providerId?: string;
}

export interface SessionItem {
  id: number;
  sessionKey: string;
  sourceKind: string;
  providerId: string | null;
  projectId: number | null;
  projectDisplayName: string | null;
  agentName: string | null;
  modelProvider: string | null;
  modelName: string | null;
  title: string | null;
  status: string;
  startedAt: string | null;
  updatedAt: string | null;
  latestObservedAt: string | null;
  messageCount: number | null;
  eventCount: number | null;
  tokensTotal: number | null;
  costUsdMicros: number | null;
}

export interface SessionsResult {
  items: SessionItem[];
  total: number;
}

interface CountRow {
  count: number;
}

export class SessionsRepository {
  constructor(private readonly db: Database.Database) {}

  query(filter: unknown = {}): SessionsResult {
    const validatedFilter = validateSessionsFilter(filter);
    const limit = validatedFilter.limit ?? 50;
    const offset = validatedFilter.offset ?? 0;
    const providerId = validatedFilter.providerId ?? null;
    // Driven by session_rollup (INNER JOIN): only sessions that produced usage events are
    // listed. Sessions with no token data on disk — e.g. Codex sessions from before
    // 2026-04-16, which never wrote token counts — have no rollup row and must not surface
    // as a wall of zeros. Per-session totals and the primary model come from the rollup;
    // model_name on agent_sessions is a stale legacy column (dropped in Task 18).
    const items = this.db
      .prepare(
        `SELECT s.id AS id,
                s.source_session_key AS sessionKey,
                s.source_kind AS sourceKind,
                s.provider_id AS providerId,
                s.project_id AS projectId,
                p.display_name AS projectDisplayName,
                s.agent_name AS agentName,
                s.model_provider AS modelProvider,
                sr.primary_model AS modelName,
                s.title AS title,
                s.status AS status,
                s.session_started_at AS startedAt,
                s.session_updated_at AS updatedAt,
                s.message_count AS messageCount,
                s.event_count AS eventCount,
                strftime('%Y-%m-%dT%H:%M:%fZ', sr.last_event_epoch_ms / 1000.0, 'unixepoch') AS latestObservedAt,
                sr.tokens_total AS tokensTotal,
                sr.cost_usd_micros AS costUsdMicros
         FROM agent_sessions s
         JOIN session_rollup sr ON sr.session_id = s.id
         LEFT JOIN projects p ON p.id = s.project_id
         WHERE (? IS NULL OR s.provider_id = ?)
           AND s.status != 'deleted'
         ORDER BY sr.last_event_epoch_ms DESC,
                  s.session_updated_at DESC,
                  s.id DESC
         LIMIT ? OFFSET ?`
      )
      .all(providerId, providerId, limit, offset) as SessionItem[];

    const total = this.db
      .prepare(
        `SELECT count(*) AS count
         FROM agent_sessions s
         JOIN session_rollup sr ON sr.session_id = s.id
         WHERE (? IS NULL OR s.provider_id = ?) AND s.status != 'deleted'`
      )
      .get(providerId, providerId) as CountRow;

    return { items, total: total.count };
  }
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

  return {
    limit: candidate.limit === undefined ? undefined : Math.min(candidate.limit as number, 200),
    offset: candidate.offset === undefined ? undefined : candidate.offset as number,
    providerId: candidate.providerId === undefined ? undefined : candidate.providerId as string
  };
}
