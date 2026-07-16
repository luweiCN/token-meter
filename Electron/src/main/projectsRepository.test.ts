import Database from 'better-sqlite3';
import { afterEach, describe, expect, it } from 'vitest';

import { ProjectsRepository } from './projectsRepository.js';

// 固定"当前时间"取正午，避免日期边界歧义（与 overviewRepository.test 同法）。
const NOW = Date.parse('2026-07-10T12:00:00+08:00');

function createDb() {
  const db = new Database(':memory:');
  db.exec(`
    CREATE TABLE projects (
      id INTEGER PRIMARY KEY, canonical_path TEXT NOT NULL, display_name TEXT NOT NULL
    );
    CREATE TABLE daily_rollup (
      usage_date TEXT NOT NULL, provider_id TEXT NOT NULL, source_kind TEXT NOT NULL,
      project_id INTEGER, model_canonical TEXT NOT NULL,
      sessions_count INTEGER NOT NULL DEFAULT 0, events_count INTEGER NOT NULL DEFAULT 0,
      tokens_input INTEGER NOT NULL DEFAULT 0, tokens_output INTEGER NOT NULL DEFAULT 0,
      tokens_reasoning INTEGER NOT NULL DEFAULT 0, tokens_cache_read INTEGER NOT NULL DEFAULT 0,
      tokens_cache_write_5m INTEGER NOT NULL DEFAULT 0, tokens_cache_write_1h INTEGER NOT NULL DEFAULT 0,
      cost_usd_micros INTEGER NOT NULL DEFAULT 0, cost_unknown_events INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE agent_sessions (
      id INTEGER PRIMARY KEY, source_kind TEXT NOT NULL, source_session_key TEXT NOT NULL,
      project_id INTEGER, provider_id TEXT, root_session_key TEXT,
      status TEXT NOT NULL DEFAULT 'active'
    );
    CREATE TABLE session_rollup (
      session_id INTEGER PRIMARY KEY,
      first_event_epoch_ms INTEGER NOT NULL DEFAULT 0, last_event_epoch_ms INTEGER NOT NULL DEFAULT 0,
      events_count INTEGER NOT NULL DEFAULT 0, tokens_total INTEGER NOT NULL DEFAULT 0,
      cost_usd_micros INTEGER NOT NULL DEFAULT 0, cost_unknown_events INTEGER NOT NULL DEFAULT 0,
      primary_model TEXT
    );

    INSERT INTO projects(id, canonical_path, display_name) VALUES
      (1, '/Users/x/dev/big-project', 'big-project'),
      (2, '/Users/x/dev/small-project', 'small-project'),
      (3, '/Users/x/dev/empty-project', 'empty-project');

    INSERT INTO daily_rollup(usage_date, provider_id, source_kind, project_id, model_canonical,
      tokens_input, cost_usd_micros, cost_unknown_events) VALUES
      ('2026-07-09', 'claude-code', 'claude_jsonl', 1, 'claude-fable-5', 1000, 900000, 2),
      ('2026-07-10', 'codex', 'codex_jsonl', 1, 'gpt-5', 500, 300000, 0),
      ('2026-06-01', 'claude-code', 'claude_jsonl', 1, 'claude-fable-5', 200, 100000, 0),
      ('2026-07-10', 'claude-code', 'claude_jsonl', 2, 'claude-fable-5', 50, 40000, 0);

    INSERT INTO agent_sessions(id, source_kind, source_session_key, project_id, provider_id, root_session_key) VALUES
      (1, 'claude_jsonl', 's1', 1, 'claude-code', NULL),
      (2, 'codex_jsonl', 's2', 1, 'codex', NULL),
      (3, 'codex_jsonl', 's3', 1, 'codex', 's2'),     -- 子会话：不计入主会话数、计入子代理数
      (4, 'claude_jsonl', 's4', 2, 'claude-code', NULL);
    INSERT INTO session_rollup(session_id) VALUES (1), (2), (3), (4);
  `);
  return db;
}

describe('ProjectsRepository', () => {
  const openedDbs: Database.Database[] = [];

  afterEach(() => {
    for (const db of openedDbs.splice(0)) db.close();
  });

  function openRepo() {
    const db = createDb();
    openedDbs.push(db);
    return new ProjectsRepository(db, () => NOW);
  }

  it('lists projects ordered by total cost with redacted paths, main-session counts, and a 14-day spark', () => {
    const cards = openRepo().list();

    expect(cards.map((c) => c.displayName)).toEqual(['big-project', 'small-project']); // 空项目不出现
    const big = cards[0];
    expect(big.pathLabel).toBe('~/dev/big-project');
    expect(big.costUsdMicros).toBe(1_300_000);       // 三日合计
    expect(big.costUnknownEvents).toBe(2);
    expect(big.tokensTotal).toBe(1700);
    expect(big.sessionsCount).toBe(2);               // 子会话 s3 不计
    expect(big.spark).toHaveLength(14);
    expect(big.spark[13]).toBe(300000);              // 今天（07-10）
    expect(big.spark[12]).toBe(900000);              // 昨天（07-09）
    expect(big.spark[0]).toBe(0);                    // 14 天窗口外的 06-01 不进 spark
    expect(big.lastActiveDate).toBe('2026-07-10');
  });

  it('detail aggregates totals, active days, daily cost with zero-fill, and model/agent splits', () => {
    const detail = openRepo().detail(1)!;

    expect(detail.displayName).toBe('big-project');
    expect(detail.pathLabel).toBe('~/dev/big-project');
    expect(detail.sessionsCount).toBe(2);
    expect(detail.activeDays).toBe(3);                 // 06-01 / 07-09 / 07-10
    expect(detail.lastActiveDate).toBe('2026-07-10');
    expect(detail.costUsdMicros).toBe(1_300_000);
    expect(detail.dailyCost).toHaveLength(14);
    expect(detail.dailyCost[13]).toEqual({ date: '2026-07-10', costUsdMicros: 300000 });
    expect(detail.dailyCost[0].costUsdMicros).toBe(0);
    expect(detail.models.map((m) => m.model)).toEqual(['claude-fable-5', 'gpt-5']);   // token 降序
    expect(detail.agents.map((a) => a.providerId)).toEqual(['claude-code', 'codex']);
  });

  it('detail returns null for an unknown project', () => {
    expect(openRepo().detail(999)).toBeNull();
  });
});
