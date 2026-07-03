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
      status TEXT NOT NULL DEFAULT 'active',
      raw_meta_json TEXT
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

    INSERT INTO agent_sessions(id, provider_id, raw_meta_json) VALUES
      (1, 'codex', '{"message":"SECRET_PROMPT_SHOULD_NOT_BE_READ"}');
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
});
