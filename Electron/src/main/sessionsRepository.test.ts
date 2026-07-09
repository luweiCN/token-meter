import Database from 'better-sqlite3';
import { afterEach, describe, expect, it } from 'vitest';

import { SessionsRepository } from './sessionsRepository.js';

// Epoch-ms timestamps for the last event of each session. session_rollup stores
// last_event_epoch_ms as an integer; the repository renders it back to an ISO string.
const T1 = Date.parse('2026-07-03T09:30:00Z');
const T2 = Date.parse('2026-07-03T12:00:00Z');
const T3 = Date.parse('2026-07-03T11:00:00Z');
const iso = (ms: number) => new Date(ms).toISOString();

// v2 fixture. sessionsRepository.query() is now driven by session_rollup: only sessions
// that produced usage events appear, and per-session totals + model come from the rollup,
// not from session_usage (removed) or agent_sessions columns.
function createSessionsDb() {
  const db = new Database(':memory:');
  db.exec(`
    CREATE TABLE scan_roots (
      id INTEGER PRIMARY KEY,
      kind TEXT NOT NULL,
      root_path TEXT NOT NULL,
      display_name TEXT NOT NULL,
      stable_source_key TEXT NOT NULL
    );

    CREATE TABLE projects (
      id INTEGER PRIMARY KEY,
      project_key TEXT NOT NULL UNIQUE,
      canonical_path TEXT NOT NULL,
      display_name TEXT NOT NULL,
      first_seen_at TEXT NOT NULL,
      last_seen_at TEXT NOT NULL
    );

    CREATE TABLE agent_sessions (
      id INTEGER PRIMARY KEY,
      source_kind TEXT NOT NULL,
      source_session_key TEXT NOT NULL,
      scan_root_id INTEGER NOT NULL,
      project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL,
      provider_id TEXT,
      agent_name TEXT,
      model_provider TEXT,
      model_name TEXT,
      cli_version TEXT,
      session_started_at TEXT,
      session_updated_at TEXT,
      title TEXT,
      status TEXT NOT NULL DEFAULT 'active',
      message_count INTEGER,
      event_count INTEGER,
      source_revision TEXT NOT NULL,
      raw_meta_json TEXT,
      UNIQUE(source_kind, source_session_key)
    );

    CREATE TABLE session_rollup (
      session_id INTEGER PRIMARY KEY REFERENCES agent_sessions(id) ON DELETE CASCADE,
      first_event_epoch_ms INTEGER NOT NULL,
      last_event_epoch_ms INTEGER NOT NULL,
      events_count INTEGER NOT NULL,
      tokens_total INTEGER NOT NULL,
      cost_usd_micros INTEGER NOT NULL,
      cost_unknown_events INTEGER NOT NULL DEFAULT 0,
      primary_model TEXT
    );

    INSERT INTO scan_roots(id, kind, root_path, display_name, stable_source_key) VALUES
      (1, 'codex_jsonl', '/Users/test/.codex/sessions', 'Codex', 'codex'),
      (2, 'claude_jsonl', '/Users/test/.claude/projects', 'Claude Code', 'claude');

    INSERT INTO projects(id, project_key, canonical_path, display_name, first_seen_at, last_seen_at) VALUES
      (10, 'token-meter', '/work/token-meter', 'Token Meter', '2026-07-01T00:00:00Z', '2026-07-03T00:00:00Z');

    -- model_name here is intentionally stale so tests can prove modelName comes from
    -- session_rollup.primary_model, not from the agent_sessions column.
    INSERT INTO agent_sessions(
      id, source_kind, source_session_key, scan_root_id, project_id, provider_id, agent_name,
      model_provider, model_name, cli_version, session_started_at, session_updated_at,
      title, status, message_count, event_count, source_revision, raw_meta_json
    ) VALUES
      (1, 'codex_jsonl', 'codex-old', 1, 10, 'codex', 'Codex', 'openai', 'stale-agent-model', '1.0.0',
       '2026-07-01T08:00:00Z', '2026-07-03T09:00:00Z', 'Implement repo',
       'active', 5, 9, 'rev-a', '{"safe":"metadata","prompt":"SECRET_PROMPT_SHOULD_NOT_LEAK"}'),
      (2, 'codex_jsonl', 'codex-new', 1, 10, 'codex', 'Codex', 'openai', 'stale-agent-model', '1.0.0',
       '2026-07-02T08:00:00Z', '2026-07-03T10:00:00Z', 'Latest usage wins',
       'active', 6, 10, 'rev-b', '{"tool_output":"SECRET_TOOL_OUTPUT_SHOULD_NOT_LEAK"}'),
      (3, 'claude_jsonl', 'claude-one', 2, NULL, 'claude-code', 'Claude Code', 'anthropic', 'stale-agent-model', '2.0.0',
       '2026-07-02T09:00:00Z', '2026-07-03T11:00:00Z', 'Claude session',
       'closed', 7, 11, 'rev-c', '{"reasoning":"SECRET_REASONING_SHOULD_NOT_LEAK"}'),
      (4, 'codex_jsonl', 'deleted-session', 1, 10, 'codex', 'Codex', 'openai', 'stale-agent-model', '1.0.0',
       '2026-07-02T10:00:00Z', '2026-07-03T12:00:00Z', 'Deleted',
       'deleted', 99, 99, 'rev-d', '{"message":"DELETED_SECRET"}'),
      (5, 'codex_jsonl', 'codex-noevents', 1, 10, 'codex', 'Codex', 'openai', 'stale-agent-model', '1.0.0',
       '2026-07-02T11:00:00Z', '2026-07-03T13:00:00Z', 'No token data on disk',
       'active', 0, 0, 'rev-e', '{"message":"NO_EVENTS_SECRET"}');

    -- Only sessions with real usage events get a session_rollup row. Session 4 is deleted
    -- (RollupBuilder excludes it); session 5 yielded zero events (the pre-2026-04-16 Codex
    -- case) so it has no rollup and must not surface as a wall-of-zeros row.
    INSERT INTO session_rollup(session_id, first_event_epoch_ms, last_event_epoch_ms, events_count, tokens_total, cost_usd_micros, primary_model) VALUES
      (1, ${T1 - 60000}, ${T1}, 9, 35, 30000, 'gpt-5'),
      (2, ${T2 - 60000}, ${T2}, 10, 55, 50000, 'gpt-5'),
      (3, ${T3 - 60000}, ${T3}, 11, 77, 70000, 'claude-sonnet');
  `);
  return db;
}

describe('SessionsRepository', () => {
  const openedDbs: Database.Database[] = [];

  afterEach(() => {
    for (const db of openedDbs.splice(0)) {
      db.close();
    }
  });

  function openRepo() {
    const db = createSessionsDb();
    openedDbs.push(db);
    return new SessionsRepository(db);
  }

  it('query lists only sessions with usage events, joins rollup totals and primary model, and orders by latest event time', () => {
    const result = openRepo().query({ limit: 10, offset: 0 });

    expect(result.total).toBe(3);
    expect(result.items).toEqual([
      expect.objectContaining({
        id: 2,
        sessionKey: 'codex-new',
        sourceKind: 'codex_jsonl',
        providerId: 'codex',
        projectId: 10,
        projectDisplayName: 'Token Meter',
        modelName: 'gpt-5',
        latestObservedAt: iso(T2),
        updatedAt: '2026-07-03T10:00:00Z',
        tokensTotal: 55,
        costUsdMicros: 50000
      }),
      expect.objectContaining({
        id: 3,
        sessionKey: 'claude-one',
        sourceKind: 'claude_jsonl',
        providerId: 'claude-code',
        projectId: null,
        projectDisplayName: null,
        modelName: 'claude-sonnet',
        latestObservedAt: iso(T3),
        updatedAt: '2026-07-03T11:00:00Z',
        tokensTotal: 77,
        costUsdMicros: 70000
      }),
      expect.objectContaining({
        id: 1,
        sessionKey: 'codex-old',
        sourceKind: 'codex_jsonl',
        providerId: 'codex',
        projectId: 10,
        modelName: 'gpt-5',
        latestObservedAt: iso(T1),
        updatedAt: '2026-07-03T09:00:00Z',
        tokensTotal: 35,
        costUsdMicros: 30000
      })
    ]);
    const keys = result.items.map((item) => item.sessionKey);
    expect(keys).not.toContain('deleted-session');
    expect(keys).not.toContain('codex-noevents');
  });

  it('query filters by provider, paginates, and never exposes raw prompt-like metadata', () => {
    const result = openRepo().query({ providerId: 'codex', limit: 1, offset: 1 });

    // codex sessions with events = {1, 2}; the zero-event codex session 5 is excluded.
    expect(result.total).toBe(2);
    expect(result.items).toEqual([
      expect.objectContaining({
        id: 1,
        sessionKey: 'codex-old',
        providerId: 'codex',
        tokensTotal: 35
      })
    ]);
    expect(result.items[0]).not.toHaveProperty('raw_meta_json');
    expect(result.items[0]).not.toHaveProperty('rawMetaJson');
    expect(result.items[0]).not.toHaveProperty('rawMeta');
    expect(JSON.stringify(result)).not.toMatch(/SECRET_|prompt|tool_output|reasoning|DELETED_SECRET|NO_EVENTS/);
  });

  it('rejects malformed renderer session filters instead of throwing TypeError or silently changing pagination', () => {
    const repo = openRepo();
    const invalidFilters: Array<{ name: string; filter: unknown }> = [
      { name: 'null filter', filter: null },
      { name: 'array filter', filter: [] },
      { name: 'zero limit', filter: { limit: 0, offset: 0 } },
      { name: 'negative limit', filter: { limit: -1, offset: 0 } },
      { name: 'fractional limit', filter: { limit: 1.5, offset: 0 } },
      { name: 'negative offset', filter: { limit: 10, offset: -1 } },
      { name: 'fractional offset', filter: { limit: 10, offset: 0.5 } },
      { name: 'array provider id', filter: { providerId: ['codex'], limit: 10, offset: 0 } }
    ];

    for (const { name, filter } of invalidFilters) {
      expect(() => repo.query(filter as never), name).toThrow(/sessions filter/i);
    }
  });
});
