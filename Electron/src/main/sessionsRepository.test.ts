import Database from 'better-sqlite3';
import { afterEach, describe, expect, it } from 'vitest';

import { SessionsRepository } from './sessionsRepository.js';

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
      scan_root_id INTEGER NOT NULL REFERENCES scan_roots(id) ON DELETE CASCADE,
      project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL,
      provider_id TEXT,
      agent_name TEXT,
      model_provider TEXT,
      model_name TEXT,
      cli_version TEXT,
      session_started_at TEXT,
      session_updated_at TEXT,
      session_closed_at TEXT,
      cwd_path TEXT,
      worktree_path TEXT,
      title TEXT,
      status TEXT NOT NULL DEFAULT 'active',
      message_count INTEGER,
      event_count INTEGER,
      total_cost_usd_micros INTEGER,
      source_revision TEXT NOT NULL,
      deleted_at TEXT,
      raw_meta_json TEXT,
      UNIQUE(source_kind, source_session_key)
    );

    CREATE TABLE session_usage (
      id INTEGER PRIMARY KEY,
      session_id INTEGER NOT NULL REFERENCES agent_sessions(id) ON DELETE CASCADE,
      observed_at TEXT NOT NULL,
      usage_seq INTEGER NOT NULL,
      metric_scope TEXT NOT NULL DEFAULT 'session',
      window_label TEXT,
      tokens_input INTEGER,
      tokens_output INTEGER,
      tokens_reasoning INTEGER,
      tokens_cache_read INTEGER,
      tokens_cache_write INTEGER,
      tokens_total INTEGER GENERATED ALWAYS AS (
        coalesce(tokens_input,0) + coalesce(tokens_output,0) + coalesce(tokens_reasoning,0) +
        coalesce(tokens_cache_read,0) + coalesce(tokens_cache_write,0)
      ) VIRTUAL,
      cost_usd_micros INTEGER,
      source_event_id TEXT,
      source_offset INTEGER,
      source_hash TEXT,
      is_cumulative INTEGER NOT NULL DEFAULT 1,
      UNIQUE(session_id, usage_seq),
      UNIQUE(session_id, id)
    );

    CREATE TABLE session_usage_latest (
      session_id INTEGER PRIMARY KEY REFERENCES agent_sessions(id) ON DELETE CASCADE,
      session_usage_id INTEGER NOT NULL UNIQUE REFERENCES session_usage(id) ON DELETE CASCADE,
      updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY (session_id, session_usage_id) REFERENCES session_usage(session_id, id) ON DELETE CASCADE
    );

    INSERT INTO scan_roots(id, kind, root_path, display_name, stable_source_key) VALUES
      (1, 'codex_jsonl', '/Users/test/.codex/sessions', 'Codex', 'codex'),
      (2, 'claude_jsonl', '/Users/test/.claude/projects', 'Claude Code', 'claude');

    INSERT INTO projects(id, project_key, canonical_path, display_name, first_seen_at, last_seen_at) VALUES
      (10, 'token-meter', '/work/token-meter', 'Token Meter', '2026-07-01T00:00:00Z', '2026-07-03T00:00:00Z');

    INSERT INTO agent_sessions(
      id, source_kind, source_session_key, scan_root_id, project_id, provider_id, agent_name,
      model_provider, model_name, cli_version, session_started_at, session_updated_at,
      cwd_path, worktree_path, title, status, message_count, event_count, total_cost_usd_micros,
      source_revision, deleted_at, raw_meta_json
    ) VALUES
      (1, 'codex_jsonl', 'codex-old', 1, 10, 'codex', 'Codex', 'openai', 'gpt-5', '1.0.0',
       '2026-07-01T08:00:00Z', '2026-07-03T09:00:00Z', '/work/token-meter', '/work/token-meter', 'Implement repo',
       'active', 5, 9, 30000, 'rev-a', NULL, '{"safe":"metadata","prompt":"SECRET_PROMPT_SHOULD_NOT_LEAK"}'),
      (2, 'codex_jsonl', 'codex-new', 1, 10, 'codex', 'Codex', 'openai', 'gpt-5', '1.0.0',
       '2026-07-02T08:00:00Z', '2026-07-03T10:00:00Z', '/work/token-meter', '/work/token-meter', 'Latest usage wins',
       'active', 6, 10, 50000, 'rev-b', NULL, '{"tool_output":"SECRET_TOOL_OUTPUT_SHOULD_NOT_LEAK"}'),
      (3, 'claude_jsonl', 'claude-one', 2, NULL, 'claude-code', 'Claude Code', 'anthropic', 'claude-sonnet', '2.0.0',
       '2026-07-02T09:00:00Z', '2026-07-03T11:00:00Z', '/work/other', '/work/other', 'Claude session',
       'closed', 7, 11, 70000, 'rev-c', NULL, '{"reasoning":"SECRET_REASONING_SHOULD_NOT_LEAK"}'),
      (4, 'codex_jsonl', 'deleted-session', 1, 10, 'codex', 'Codex', 'openai', 'gpt-5', '1.0.0',
       '2026-07-02T10:00:00Z', '2026-07-03T12:00:00Z', '/work/token-meter', '/work/token-meter', 'Deleted',
       'deleted', 99, 99, 990000, 'rev-d', '2026-07-03T12:30:00Z', '{"message":"DELETED_SECRET"}');

    INSERT INTO session_usage(
      id, session_id, observed_at, usage_seq, tokens_input, tokens_output, tokens_reasoning,
      tokens_cache_read, tokens_cache_write, cost_usd_micros, source_event_id, source_offset, source_hash
    ) VALUES
      (101, 1, '2026-07-03T09:30:00Z', 1, 10, 20, 0, 5, 0, 30000, 'event-1', 100, 'hash-1'),
      (102, 2, '2026-07-03T12:00:00Z', 1, 20, 30, 5, 0, 0, 50000, 'event-2', 200, 'hash-2'),
      (103, 3, '2026-07-03T11:00:00Z', 1, 30, 40, 0, 0, 7, 70000, 'event-3', 300, 'hash-3'),
      (104, 4, '2026-07-03T13:00:00Z', 1, 90, 9, 0, 0, 0, 990000, 'event-4', 400, 'hash-4');

    INSERT INTO session_usage_latest(session_id, session_usage_id, updated_at) VALUES
      (1, 101, '2026-07-03T09:31:00Z'),
      (2, 102, '2026-07-03T12:01:00Z'),
      (3, 103, '2026-07-03T11:01:00Z'),
      (4, 104, '2026-07-03T13:01:00Z');
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

  it('query excludes deleted sessions, joins latest usage totals, and orders by latest observed time before session update time', () => {
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
        latestObservedAt: '2026-07-03T12:00:00Z',
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
        latestObservedAt: '2026-07-03T11:00:00Z',
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
        latestObservedAt: '2026-07-03T09:30:00Z',
        updatedAt: '2026-07-03T09:00:00Z',
        tokensTotal: 35,
        costUsdMicros: 30000
      })
    ]);
    expect(result.items.map((item) => item.sessionKey)).not.toContain('deleted-session');
  });

  it('query filters by provider, paginates, and never exposes raw prompt-like metadata', () => {
    const result = openRepo().query({ providerId: 'codex', limit: 1, offset: 1 });

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
    expect(JSON.stringify(result)).not.toMatch(/SECRET_|prompt|tool_output|reasoning|DELETED_SECRET/);
  });
});
