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
                s.model_name AS modelName,
                s.title AS title,
                s.status AS status,
                s.session_started_at AS startedAt,
                s.session_updated_at AS updatedAt,
                s.message_count AS messageCount,
                s.event_count AS eventCount,
                u.observed_at AS latestObservedAt,
                u.tokens_total AS tokensTotal,
                u.cost_usd_micros AS costUsdMicros
         FROM agent_sessions s
         LEFT JOIN projects p ON p.id = s.project_id
         LEFT JOIN session_usage_latest ul ON ul.session_id = s.id
         LEFT JOIN session_usage u ON u.id = ul.session_usage_id
         WHERE (? IS NULL OR s.provider_id = ?)
           AND s.status != 'deleted'
         ORDER BY coalesce(u.observed_at, s.session_updated_at, s.session_started_at) DESC,
                  s.session_updated_at DESC,
                  s.id DESC
         LIMIT ? OFFSET ?`
      )
      .all(providerId, providerId, limit, offset) as SessionItem[];

    const total = this.db
      .prepare(`SELECT count(*) AS count FROM agent_sessions WHERE (? IS NULL OR provider_id = ?) AND status != 'deleted'`)
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
