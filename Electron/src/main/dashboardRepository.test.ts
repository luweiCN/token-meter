import Database from 'better-sqlite3';
import { afterEach, describe, expect, it } from 'vitest';

import { DashboardRepository } from './dashboardRepository.js';

function createDashboardDb() {
  const db = new Database(':memory:');
  db.exec(`
    CREATE TABLE projects (
      id INTEGER PRIMARY KEY,
      project_key TEXT NOT NULL UNIQUE,
      canonical_path TEXT NOT NULL,
      display_name TEXT NOT NULL,
      first_seen_at TEXT NOT NULL,
      last_seen_at TEXT NOT NULL
    );

    CREATE TABLE provider_daily_usage (
      usage_date TEXT NOT NULL,
      provider_id TEXT NOT NULL,
      project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL,
      source_kind TEXT NOT NULL,
      sessions_count INTEGER NOT NULL,
      tokens_input INTEGER NOT NULL DEFAULT 0,
      tokens_output INTEGER NOT NULL DEFAULT 0,
      tokens_reasoning INTEGER NOT NULL DEFAULT 0,
      tokens_cache_read INTEGER NOT NULL DEFAULT 0,
      tokens_cache_write INTEGER NOT NULL DEFAULT 0,
      total_cost_usd_micros INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (usage_date, provider_id, project_id, source_kind)
    );

    CREATE TABLE agent_sessions (
      id INTEGER PRIMARY KEY,
      provider_id TEXT,
      source_kind TEXT NOT NULL,
      project_id INTEGER,
      model_name TEXT,
      status TEXT NOT NULL DEFAULT 'active',
      raw_meta_json TEXT
    );

    CREATE TABLE session_usage (
      id INTEGER PRIMARY KEY,
      session_id INTEGER NOT NULL,
      observed_at TEXT NOT NULL,
      usage_seq INTEGER NOT NULL,
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
      is_cumulative INTEGER NOT NULL DEFAULT 1
    );

    CREATE TABLE session_usage_latest (
      session_id INTEGER PRIMARY KEY,
      session_usage_id INTEGER NOT NULL UNIQUE,
      updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    );

    INSERT INTO projects(id, project_key, canonical_path, display_name, first_seen_at, last_seen_at) VALUES
      (10, 'token-meter', '/work/token-meter', 'Token Meter', '2026-07-01T00:00:00Z', '2026-07-03T00:00:00Z'),
      (20, 'other', '/work/other', 'Other', '2026-07-01T00:00:00Z', '2026-07-03T00:00:00Z');

    INSERT INTO provider_daily_usage(
      usage_date, provider_id, project_id, source_kind, sessions_count,
      tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, total_cost_usd_micros
    ) VALUES
      ('2026-07-01', 'codex', 10, 'codex_jsonl', 2, 100, 50, 10, 20, 5, 125000),
      ('2026-07-02', 'codex', 10, 'codex_jsonl', 1, 20, 30, 0, 0, 0, 42000),
      ('2026-07-02', 'claude-code', 20, 'claude_jsonl', 3, 1, 2, 3, 4, 5, 6000),
      ('2026-07-04', 'codex', 10, 'codex_jsonl', 9, 900, 0, 0, 0, 0, 999000);

    INSERT INTO agent_sessions(id, provider_id, source_kind, project_id, model_name, status, raw_meta_json) VALUES
      (1, 'codex', 'codex_jsonl', 10, 'gpt-5', 'active', '{"message":"SECRET_PROMPT_SHOULD_NOT_BE_READ"}'),
      (2, 'claude-code', 'claude_jsonl', 20, 'claude-sonnet', 'active', '{"message":"SECRET_RESPONSE_SHOULD_NOT_BE_READ"}'),
      (3, 'codex', 'codex_jsonl', 10, 'gpt-5', 'deleted', '{"message":"SECRET_DELETED_SHOULD_NOT_BE_READ"}');

    INSERT INTO session_usage(
      id, session_id, observed_at, usage_seq,
      tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, cost_usd_micros
    ) VALUES
      (101, 1, '2026-07-02T10:00:00Z', 1, 100, 40, 0, 10, 0, 12000),
      (102, 2, '2026-07-02T11:00:00Z', 1, 200, 20, 10, 5, 0, 24000),
      (103, 3, '2026-07-02T12:00:00Z', 1, 999, 999, 0, 0, 0, 999000);

    INSERT INTO session_usage_latest(session_id, session_usage_id) VALUES
      (1, 101),
      (2, 102),
      (3, 103);
  `);
  return db;
}

describe('DashboardRepository', () => {
  const openedDbs: Database.Database[] = [];

  afterEach(() => {
    for (const db of openedDbs.splice(0)) {
      db.close();
    }
  });

  function openRepo() {
    const db = createDashboardDb();
    openedDbs.push(db);
    return new DashboardRepository(db);
  }

  it('overview returns session totals, token totals, model breakdown, and daily trend without raw metadata', () => {
    const repo = openRepo();

    const overview = repo.overview();

    expect(overview).toEqual({
      sessionCount: 2,
      totalTokens: 385,
      activeModelCount: 2,
      totalCostUsdMicros: 36000,
      modelBreakdown: [
        { modelName: 'claude-sonnet', sessionsCount: 1, tokensTotal: 235, costUsdMicros: 24000 },
        { modelName: 'gpt-5', sessionsCount: 1, tokensTotal: 150, costUsdMicros: 12000 }
      ],
      providerBreakdown: [
        { providerId: 'claude-code', sessionsCount: 1, tokensTotal: 235 },
        { providerId: 'codex', sessionsCount: 1, tokensTotal: 150 }
      ],
      dailyTrend: [
        { usageDate: '2026-07-01', tokensTotal: 185, sessionsCount: 2 },
        { usageDate: '2026-07-02', tokensTotal: 65, sessionsCount: 4 },
        { usageDate: '2026-07-04', tokensTotal: 900, sessionsCount: 9 }
      ]
    });
    expect(JSON.stringify(overview)).not.toMatch(/SECRET|raw_meta|prompt|response/i);
  });

  it('dailyUsage returns daily rollups with token totals, session counts, and costs from provider_daily_usage only', () => {
    const repo = openRepo();

    const rows = repo.dailyUsage({ from: '2026-07-01', to: '2026-07-03' });

    expect(rows).toEqual([
      {
        usageDate: '2026-07-01',
        providerId: 'codex',
        projectId: 10,
        sourceKind: 'codex_jsonl',
        tokensTotal: 185,
        sessionsCount: 2,
        costUsdMicros: 125000
      },
      {
        usageDate: '2026-07-02',
        providerId: 'claude-code',
        projectId: 20,
        sourceKind: 'claude_jsonl',
        tokensTotal: 15,
        sessionsCount: 3,
        costUsdMicros: 6000
      },
      {
        usageDate: '2026-07-02',
        providerId: 'codex',
        projectId: 10,
        sourceKind: 'codex_jsonl',
        tokensTotal: 50,
        sessionsCount: 1,
        costUsdMicros: 42000
      }
    ]);
  });

  it('dailyUsage filters by provider and project without falling back to session source data', () => {
    const repo = openRepo();

    expect(repo.dailyUsage({ from: '2026-07-01', to: '2026-07-03', providerId: 'codex', projectId: 10 })).toEqual([
      {
        usageDate: '2026-07-01',
        providerId: 'codex',
        projectId: 10,
        sourceKind: 'codex_jsonl',
        tokensTotal: 185,
        sessionsCount: 2,
        costUsdMicros: 125000
      },
      {
        usageDate: '2026-07-02',
        providerId: 'codex',
        projectId: 10,
        sourceKind: 'codex_jsonl',
        tokensTotal: 50,
        sessionsCount: 1,
        costUsdMicros: 42000
      }
    ]);
    expect(repo.dailyUsage({ from: '2026-07-01', to: '2026-07-03', providerId: 'missing' })).toEqual([]);
  });

  it('rejects malformed renderer daily usage filters instead of throwing TypeError or silently broadening the query', () => {
    const repo = openRepo();
    const invalidFilters: Array<{ name: string; filter: unknown }> = [
      { name: 'null filter', filter: null },
      { name: 'array filter', filter: [] },
      { name: 'bad from date', filter: { from: 'not-a-date', to: '2026-07-03' } },
      { name: 'bad to date', filter: { from: '2026-07-01', to: '2026-07-99' } },
      { name: 'non-integer project id', filter: { from: '2026-07-01', to: '2026-07-03', projectId: 10.5 } },
      { name: 'negative project id', filter: { from: '2026-07-01', to: '2026-07-03', projectId: -1 } }
    ];

    for (const { name, filter } of invalidFilters) {
      expect(
        () => repo.dailyUsage(filter as never),
        name
      ).toThrow(/dailyUsage filter/i);
    }
  });
});
