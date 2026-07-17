import Database from 'better-sqlite3';
import { afterEach, describe, expect, it } from 'vitest';

import { SessionsRepository } from './sessionsRepository.js';

// Epoch-ms timestamps for the last event of each session. session_rollup stores
// last_event_epoch_ms as an integer; the repository renders it back to an ISO string.
const T1 = Date.parse('2026-07-03T09:30:00Z');
const T2 = Date.parse('2026-07-03T12:00:00Z');
const T3 = Date.parse('2026-07-03T11:00:00Z');

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
      root_session_key TEXT,
      subagent_label TEXT,
      UNIQUE(source_kind, source_session_key)
    );

    CREATE TABLE usage_events (
      id INTEGER PRIMARY KEY,
      session_id INTEGER NOT NULL,
      source_file_id INTEGER NOT NULL DEFAULT 1,
      is_sidechain INTEGER NOT NULL DEFAULT 0
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

  it('query lists only main sessions with usage events, joins rollup totals, ordered by start desc', () => {
    const result = openRepo().query({ limit: 10, offset: 0 });

    expect(result.total).toBe(3);
    // 默认排序 start desc：first_event_epoch_ms 递减 → T2(12:00) > T3(11:00) > T1(9:30)。
    expect(result.items).toEqual([
      expect.objectContaining({ id: 2, sessionKey: 'codex-new', tokensTotal: 55 }),
      expect.objectContaining({
        id: 3,
        sessionKey: 'claude-one',
        sourceKind: 'claude_jsonl',
        providerId: 'claude-code',
        projectId: null,
        projectDisplayName: null,
        modelName: 'claude-sonnet',
        firstEventEpochMs: T3 - 60000,
        lastEventEpochMs: T3,
        tokensTotal: 77,
        costUsdMicros: 70000,
        eventsCount: 11,
        subagentCount: 0
      }),
      expect.objectContaining({ id: 1, sessionKey: 'codex-old', tokensTotal: 35 })
    ]);
    const keys = result.items.map((item) => item.sessionKey);
    expect(keys).not.toContain('deleted-session');
    expect(keys).not.toContain('codex-noevents');
  });

  it('folds sub-agent sessions into their root row instead of listing them', () => {
    const repo = openRepo();
    const db = openedDbs[openedDbs.length - 1];
    // 子会话指向 codex-new（root_session_key = 主会话的 source_session_key）。
    db.exec(`
      INSERT INTO agent_sessions(id, source_kind, source_session_key, scan_root_id, project_id, provider_id, source_revision, root_session_key, status)
      VALUES (6, 'codex_jsonl', 'codex-sub', 1, 10, 'codex', 'rev-f', 'codex-new', 'active');
      INSERT INTO session_rollup(session_id, first_event_epoch_ms, last_event_epoch_ms, events_count, tokens_total, cost_usd_micros, primary_model)
      VALUES (6, ${T2}, ${T2 + 30000}, 2, 45, 10000, 'sub-model');
    `);

    const result = repo.query({ limit: 10, offset: 0 });

    expect(result.total).toBe(3);   // 子会话不单独成行
    const parent = result.items.find((s) => s.sessionKey === 'codex-new')!;
    expect(parent.tokensTotal).toBe(100);        // 55 + 45 合计
    expect(parent.costUsdMicros).toBe(60000);    // 50000 + 10000
    expect(parent.subagentCount).toBe(1);
    expect(parent.lastEventEpochMs).toBe(T2 + 30000);   // 归并后的最近活动
  });

  it('filters by projects (multi), local date range, and title/model search, and sorts by tokens', () => {
    const repo = openRepo();

    expect(repo.query({ projectIds: [10] }).total).toBe(2);           // codex 两条属于项目 10
    expect(repo.query({ projectIds: [10, 999] }).total).toBe(2);      // 多选 = IN 集合
    expect(repo.query({ projectIds: [999] }).total).toBe(0);
    expect(repo.query({ search: 'Latest' }).items.map((s) => s.id)).toEqual([2]);   // 标题子串
    expect(repo.query({ search: 'claude-son' }).items.map((s) => s.id)).toEqual([3]); // 模型子串

    const localDay = new Date(T2).toISOString().slice(0, 10);         // T2 所在 UTC 日（本地解析亦覆盖该日）
    expect(repo.query({ dateFrom: localDay, dateTo: localDay }).total).toBeGreaterThan(0);
    expect(repo.query({ dateFrom: '2030-01-01', dateTo: '2030-01-02' }).total).toBe(0);

    const byTokens = repo.query({ sortBy: 'tokens', sortDir: 'desc' }).items.map((s) => s.tokensTotal);
    expect(byTokens).toEqual([...byTokens].sort((a, b) => b - a));
  });

  it('lists filterable projects with their main-session counts', () => {
    const projects = openRepo().projects();
    expect(projects).toEqual([
      { id: 10, displayName: 'Token Meter', sessionsCount: 2 }
    ]);
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
      { name: 'array provider id', filter: { providerId: ['codex'], limit: 10, offset: 0 } },
      { name: 'non-array projectIds', filter: { projectIds: 10 } },
      { name: 'fractional project id', filter: { projectIds: [1.5] } },
      { name: 'bad date format', filter: { dateFrom: '2026/07/01' } }
    ];

    for (const { name, filter } of invalidFilters) {
      expect(() => repo.query(filter as never), name).toThrow(/sessions filter/i);
    }
  });

  describe('trend', () => {
    it('buckets per-provider tokens by local start day across the filtered range', () => {
      const result = openRepo().trend({ dateFrom: '2026-07-01', dateTo: '2026-07-04' });

      expect(result.buckets).toEqual(['2026-07-01', '2026-07-02', '2026-07-03', '2026-07-04']);
      // 三个主会话都始于本地 2026-07-03：codex 35+55、claude 77（含子代理合计口径）。
      expect(result.rows).toEqual([
        { bucket: '2026-07-03', providerId: 'claude-code', tokens: 77, sessions: 1 },
        { bucket: '2026-07-03', providerId: 'codex', tokens: 90, sessions: 2 }
      ]);
    });

    it('follows the project filter', () => {
      const result = openRepo().trend({ projectIds: [10], dateFrom: '2026-07-01', dateTo: '2026-07-04' });

      expect(result.rows).toEqual([
        { bucket: '2026-07-03', providerId: 'codex', tokens: 90, sessions: 2 }
      ]);
    });

    it('defaults to the recent 30 local days', () => {
      const result = openRepo().trend({});

      expect(result.buckets).toHaveLength(30);
      // 测试数据固定在 2026-07 初，远离「今天」：默认窗口内没有行也不该抛。
      expect(Array.isArray(result.rows)).toBe(true);
    });
  });
});
