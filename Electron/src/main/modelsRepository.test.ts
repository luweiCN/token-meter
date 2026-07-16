import Database from 'better-sqlite3';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';

import { ModelsRepository } from './modelsRepository.js';

/// 模型维度直接聚合 usage_events(observed_epoch_ms)——用户场景是「额度刷新
/// 时刻 → 周期结束」的时间点精度,daily_rollup 的天粒度装不下。
function createModelsDb() {
  const db = new Database(':memory:');
  db.exec(`
    CREATE TABLE agent_sessions (
      id INTEGER PRIMARY KEY,
      source_kind TEXT NOT NULL,
      source_session_key TEXT NOT NULL,
      root_session_key TEXT,
      provider_id TEXT,
      status TEXT NOT NULL DEFAULT 'active'
    );

    CREATE TABLE usage_events (
      id INTEGER PRIMARY KEY,
      session_id INTEGER NOT NULL,
      source_file_id INTEGER NOT NULL DEFAULT 1,
      event_seq INTEGER NOT NULL,
      observed_epoch_ms INTEGER NOT NULL,
      model_canonical TEXT,
      tokens_input INTEGER NOT NULL DEFAULT 0,
      tokens_output INTEGER NOT NULL DEFAULT 0,
      tokens_cache_read INTEGER NOT NULL DEFAULT 0,
      tokens_cache_write_5m INTEGER NOT NULL DEFAULT 0,
      tokens_cache_write_1h INTEGER NOT NULL DEFAULT 0,
      tokens_total INTEGER GENERATED ALWAYS AS (
        tokens_input + tokens_output +
        tokens_cache_read + tokens_cache_write_5m + tokens_cache_write_1h
      ) VIRTUAL,
      cost_usd_micros INTEGER,
      cost_source TEXT NOT NULL DEFAULT 'computed'
    );
  `);
  return db;
}

function seedSession(
  db: Database.Database,
  id: number,
  provider: string,
  options: { root?: string; key?: string } = {}
) {
  db.prepare(
    'INSERT INTO agent_sessions (id, source_kind, source_session_key, root_session_key, provider_id) VALUES (?, ?, ?, ?, ?)'
  ).run(id, 'k', options.key ?? `s${id}`, options.root ?? null, provider);
}

function seedEvent(
  db: Database.Database,
  options: {
    session: number;
    at: number;
    model: string;
    tokens?: number;
    cost?: number | null;
    costSource?: string;
  }
) {
  db.prepare(
    `INSERT INTO usage_events (session_id, event_seq, observed_epoch_ms, model_canonical, tokens_input, cost_usd_micros, cost_source)
     VALUES (?, (SELECT coalesce(max(event_seq), 0) + 1 FROM usage_events), ?, ?, ?, ?, ?)`
  ).run(
    options.session,
    options.at,
    options.model,
    options.tokens ?? 100,
    options.cost === undefined ? 10 : options.cost,
    options.costSource ?? 'computed'
  );
}

describe('ModelsRepository', () => {
  let db: Database.Database;
  let repository: ModelsRepository;

  beforeEach(() => {
    db = createModelsDb();
    repository = new ModelsRepository(db as never);
  });

  afterEach(() => {
    db.close();
  });

  it('aggregates per model with millisecond-precision time bounds (closed interval)', () => {
    seedSession(db, 1, 'codex');
    seedEvent(db, { session: 1, at: 1_000, model: 'gpt-5.6-sol', tokens: 10 });   // 界外(早)
    seedEvent(db, { session: 1, at: 2_000, model: 'gpt-5.6-sol', tokens: 100 });  // 下边界(含)
    seedEvent(db, { session: 1, at: 5_000, model: 'gpt-5.6-sol', tokens: 1_000 }); // 界内
    seedEvent(db, { session: 1, at: 9_000, model: 'gpt-5.6-sol', tokens: 10_000 }); // 上边界(含)
    seedEvent(db, { session: 1, at: 9_001, model: 'gpt-5.6-sol', tokens: 100_000 }); // 界外(晚)

    const result = repository.query({ fromEpochMs: 2_000, toEpochMs: 9_000 });

    expect(result.items).toHaveLength(1);
    expect(result.items[0].model).toBe('gpt-5.6-sol');
    expect(result.items[0].tokensTotal).toBe(11_100);
    expect(result.items[0].eventsCount).toBe(3);
    expect(result.items[0].firstUsedEpochMs).toBe(2_000);
    expect(result.items[0].lastUsedEpochMs).toBe(9_000);
  });

  it('counts merged sessions (subagents fold into their root) and lists distinct agents', () => {
    seedSession(db, 1, 'claude-code', { key: 'root-a' });
    seedSession(db, 2, 'claude-code', { key: 'sub-a', root: 'root-a' });   // 子代理 → 归并进 root-a
    seedSession(db, 3, 'codex', { key: 'root-b' });
    seedEvent(db, { session: 1, at: 1_000, model: 'claude-fable-5', tokens: 100, cost: 5 });
    seedEvent(db, { session: 2, at: 2_000, model: 'claude-fable-5', tokens: 200, cost: 7 });
    seedEvent(db, { session: 3, at: 3_000, model: 'claude-fable-5', tokens: 400, cost: null, costSource: 'unknown' });

    const result = repository.query({});

    expect(result.items).toHaveLength(1);
    const item = result.items[0];
    expect(item.tokensTotal).toBe(700);
    expect(item.costUsdMicros).toBe(12);
    expect(item.costUnknownEvents).toBe(1);
    expect(item.sessionsCount).toBe(2);   // root-a(含子代理) + root-b
    expect(item.agents).toEqual(['claude-code', 'codex']);
  });

  it('sorts by the requested column and filters by model-name search', () => {
    seedSession(db, 1, 'codex');
    seedEvent(db, { session: 1, at: 1_000, model: 'gpt-5.6-sol', tokens: 100 });
    seedEvent(db, { session: 1, at: 2_000, model: 'claude-fable-5', tokens: 900 });
    seedEvent(db, { session: 1, at: 3_000, model: 'glm-5.2', tokens: 500 });

    const byTokens = repository.query({ sortBy: 'tokens', sortDir: 'desc' });
    expect(byTokens.items.map((item) => item.model)).toEqual(['claude-fable-5', 'glm-5.2', 'gpt-5.6-sol']);

    const searched = repository.query({ search: 'GPT' });
    expect(searched.items.map((item) => item.model)).toEqual(['gpt-5.6-sol']);
  });

  it('excludes events without a canonical model instead of grouping them as a ghost row', () => {
    seedSession(db, 1, 'codex');
    seedEvent(db, { session: 1, at: 1_000, model: 'gpt-5.6-sol' });
    db.prepare(
      'INSERT INTO usage_events (session_id, event_seq, observed_epoch_ms, model_canonical, tokens_input, cost_usd_micros, cost_source) VALUES (1, 99, 1500, NULL, 50, 1, ?)'
    ).run('computed');

    const result = repository.query({});

    expect(result.items.map((item) => item.model)).toEqual(['gpt-5.6-sol']);
  });
});
