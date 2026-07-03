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

  query(filter: SessionsFilter = {}): SessionsResult {
    const limit = normalizeLimit(filter.limit);
    const offset = normalizeOffset(filter.offset);
    const providerId = filter.providerId ?? null;

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

function normalizeLimit(limit: number | undefined) {
  if (limit === undefined) return 50;
  if (!Number.isInteger(limit) || limit < 1) return 50;
  return Math.min(limit, 200);
}

function normalizeOffset(offset: number | undefined) {
  if (offset === undefined) return 0;
  if (!Number.isInteger(offset) || offset < 0) return 0;
  return offset;
}
