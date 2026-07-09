import Database from 'better-sqlite3';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';

import { DashboardRepository } from './dashboardRepository.js';

// v2 schema fixture. overview() now reads the rollup tables (daily_rollup, session_rollup)
// built by Swift's RollupBuilder from usage_events. provider_daily_usage is kept because
// dailyUsage() still reads it — the plan defers that query to Task 18 (see plan §Task 18:
// "在此之前 dashboardRepository.ts 仍在查 provider_daily_usage"), so Task 16 leaves it alone.
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

    CREATE TABLE agent_sessions (
      id INTEGER PRIMARY KEY,
      source_kind TEXT NOT NULL,
      source_session_key TEXT NOT NULL,
      scan_root_id INTEGER NOT NULL,
      project_id INTEGER,
      provider_id TEXT,
      model_name TEXT,
      status TEXT NOT NULL DEFAULT 'active',
      source_revision TEXT NOT NULL DEFAULT 'r',
      raw_meta_json TEXT,
      UNIQUE(source_kind, source_session_key)
    );

    CREATE TABLE usage_events (
      id INTEGER PRIMARY KEY,
      session_id INTEGER NOT NULL,
      source_file_id INTEGER NOT NULL,
      event_seq INTEGER NOT NULL,
      observed_epoch_ms INTEGER NOT NULL,
      model_name TEXT,
      model_canonical TEXT,
      tokens_input INTEGER NOT NULL DEFAULT 0,
      tokens_output INTEGER NOT NULL DEFAULT 0,
      tokens_reasoning INTEGER NOT NULL DEFAULT 0,
      tokens_cache_read INTEGER NOT NULL DEFAULT 0,
      tokens_cache_write_5m INTEGER NOT NULL DEFAULT 0,
      tokens_cache_write_1h INTEGER NOT NULL DEFAULT 0,
      tokens_total INTEGER GENERATED ALWAYS AS (
        tokens_input + tokens_output +
        tokens_cache_read + tokens_cache_write_5m + tokens_cache_write_1h
      ) VIRTUAL,
      cost_usd_micros INTEGER,
      cost_source TEXT NOT NULL CHECK (cost_source IN ('reported', 'computed', 'unknown')),
      dedupe_key TEXT,
      source_offset INTEGER NOT NULL,
      is_sidechain INTEGER NOT NULL DEFAULT 0,
      UNIQUE(source_file_id, event_seq)
    );

    CREATE TABLE daily_rollup (
      usage_date TEXT NOT NULL,
      provider_id TEXT NOT NULL,
      source_kind TEXT NOT NULL,
      project_id INTEGER,
      model_canonical TEXT NOT NULL,
      sessions_count INTEGER NOT NULL DEFAULT 0,
      events_count INTEGER NOT NULL DEFAULT 0,
      tokens_input INTEGER NOT NULL DEFAULT 0,
      tokens_output INTEGER NOT NULL DEFAULT 0,
      tokens_reasoning INTEGER NOT NULL DEFAULT 0,
      tokens_cache_read INTEGER NOT NULL DEFAULT 0,
      tokens_cache_write_5m INTEGER NOT NULL DEFAULT 0,
      tokens_cache_write_1h INTEGER NOT NULL DEFAULT 0,
      cost_usd_micros INTEGER NOT NULL DEFAULT 0,
      cost_unknown_events INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE session_rollup (
      session_id INTEGER PRIMARY KEY,
      first_event_epoch_ms INTEGER NOT NULL,
      last_event_epoch_ms INTEGER NOT NULL,
      events_count INTEGER NOT NULL,
      tokens_total INTEGER NOT NULL,
      cost_usd_micros INTEGER NOT NULL,
      cost_unknown_events INTEGER NOT NULL DEFAULT 0,
      primary_model TEXT
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
  `);
  return db;
}

// rebuildRollups runs the SAME SQL as Swift's RollupBuilder so this test verifies the
// product's aggregation, not a TypeScript re-implementation. The two INSERT ... SELECT
// statements are copied verbatim from Sources/TokenMeterCore/RollupBuilder.swift
// (rebuildDailyRollup, lines 26-68; rebuildSessionRollup, lines 72-104). If that file's
// SQL changes, this must change with it. (The plan notes the right long-term fix is a
// shared .sql resource; Task 16 deliberately does not do that — it just records it.)
function rebuildRollups(db: Database.Database) {
  db.exec(`DELETE FROM daily_rollup`);
  db.exec(`
    INSERT INTO daily_rollup(
        usage_date, provider_id, source_kind, project_id, model_canonical,
        sessions_count, events_count,
        tokens_input, tokens_output, tokens_reasoning,
        tokens_cache_read, tokens_cache_write_5m, tokens_cache_write_1h,
        cost_usd_micros, cost_unknown_events
    )
    SELECT
        date(e.observed_epoch_ms / 1000, 'unixepoch', 'localtime') AS usage_date,
        s.provider_id,
        s.source_kind,
        s.project_id,
        e.model_canonical,
        count(DISTINCT e.session_id) AS sessions_count,
        count(*) AS events_count,
        coalesce(sum(e.tokens_input), 0),
        coalesce(sum(e.tokens_output), 0),
        coalesce(sum(e.tokens_reasoning), 0),
        coalesce(sum(e.tokens_cache_read), 0),
        coalesce(sum(e.tokens_cache_write_5m), 0),
        coalesce(sum(e.tokens_cache_write_1h), 0),
        coalesce(sum(e.cost_usd_micros), 0),
        sum(CASE WHEN e.cost_source = 'unknown' THEN 1 ELSE 0 END)
    FROM usage_events e
    JOIN agent_sessions s ON s.id = e.session_id
    WHERE s.status != 'deleted'
    GROUP BY usage_date, s.provider_id, s.source_kind, s.project_id, e.model_canonical
  `);

  db.exec(`DELETE FROM session_rollup`);
  db.exec(`
    INSERT INTO session_rollup(
        session_id, first_event_epoch_ms, last_event_epoch_ms, events_count,
        tokens_total, cost_usd_micros, cost_unknown_events, primary_model
    )
    SELECT
        e.session_id,
        min(e.observed_epoch_ms),
        max(e.observed_epoch_ms),
        count(*),
        coalesce(sum(e.tokens_total), 0),
        coalesce(sum(e.cost_usd_micros), 0),
        sum(CASE WHEN e.cost_source = 'unknown' THEN 1 ELSE 0 END),
        (
            SELECT e2.model_canonical
            FROM usage_events e2
            WHERE e2.session_id = e.session_id
            GROUP BY e2.model_canonical
            ORDER BY sum(e2.tokens_total) DESC, e2.model_canonical ASC
            LIMIT 1
        )
    FROM usage_events e
    JOIN agent_sessions s ON s.id = e.session_id
    WHERE s.status != 'deleted'
    GROUP BY e.session_id
  `);
}

function seedUsageEvents(
  db: Database.Database,
  rows: Array<{ sessionId: number; day: string; model: string; input: number; output: number }>
) {
  const insertSession = db.prepare(
    `INSERT OR IGNORE INTO agent_sessions(id, source_kind, source_session_key, scan_root_id, provider_id, source_revision, status)
     VALUES (?, 'claude_jsonl', ?, 1, 'claude-code', 'r', 'active')`
  );
  for (const sessionId of new Set(rows.map((row) => row.sessionId))) {
    insertSession.run(sessionId, `s${sessionId}`);
  }

  const insertEvent = db.prepare(
    `INSERT INTO usage_events(session_id, source_file_id, event_seq, observed_epoch_ms,
                              model_name, model_canonical, tokens_input, tokens_output,
                              cost_usd_micros, cost_source, source_offset)
     VALUES (?, 1, ?, ?, ?, ?, ?, ?, 0, 'computed', ?)`
  );
  let seq = 0;
  for (const row of rows) {
    seq += 1;
    insertEvent.run(row.sessionId, seq, Date.parse(`${row.day}T12:00:00Z`), row.model, row.model, row.input, row.output, seq);
  }
}

describe('DashboardRepository', () => {
  let db: Database.Database;

  beforeEach(() => {
    db = createDashboardDb();
  });

  afterEach(() => {
    db.close();
  });

  function repo() {
    return new DashboardRepository(db);
  }

  it('overview draws session totals from session_rollup, model/provider/day breakdowns from daily_rollup, surfaces unknown-cost events, and never leaks raw metadata', () => {
    db.exec(`
      INSERT INTO agent_sessions(id, source_kind, source_session_key, scan_root_id, provider_id, source_revision, status, raw_meta_json) VALUES
        (1, 'codex_jsonl', 's1', 1, 'codex', 'r', 'active', '{"message":"SECRET_PROMPT_SHOULD_NOT_LEAK"}'),
        (2, 'claude_jsonl', 's2', 2, 'claude-code', 'r', 'active', '{"message":"SECRET_RESPONSE_SHOULD_NOT_LEAK"}');

      INSERT INTO session_rollup(session_id, first_event_epoch_ms, last_event_epoch_ms, events_count, tokens_total, cost_usd_micros, cost_unknown_events, primary_model) VALUES
        (1, 1000, 2000, 3, 1000, 500000, 2, 'gpt-5.5'),
        (2, 3000, 4000, 5, 2000, 700000, 0, 'claude-opus-4-8');

      INSERT INTO daily_rollup(usage_date, provider_id, source_kind, project_id, model_canonical,
                               sessions_count, events_count, tokens_input, tokens_output, tokens_cache_read,
                               cost_usd_micros, cost_unknown_events) VALUES
        ('2026-07-07', 'codex', 'codex_jsonl', NULL, 'gpt-5.5', 1, 3, 800, 100, 100, 500000, 2),
        ('2026-07-08', 'claude-code', 'claude_jsonl', NULL, 'claude-opus-4-8', 1, 5, 1500, 500, 0, 700000, 0);
    `);

    const overview = repo().overview();

    expect(overview).toEqual({
      sessionCount: 2,
      totalTokens: 3000,
      activeModelCount: 2,
      totalCostUsdMicros: 1200000,
      costUnknownEvents: 2,
      modelBreakdown: [
        { modelName: 'claude-opus-4-8', sessionsCount: 1, tokensTotal: 2000, costUsdMicros: 700000 },
        { modelName: 'gpt-5.5', sessionsCount: 1, tokensTotal: 1000, costUsdMicros: 500000 }
      ],
      providerBreakdown: [
        { providerId: 'claude-code', sessionsCount: 1, tokensTotal: 2000 },
        { providerId: 'codex', sessionsCount: 1, tokensTotal: 1000 }
      ],
      dailyTrend: [
        { usageDate: '2026-07-07', tokensTotal: 1000, sessionsCount: 1 },
        { usageDate: '2026-07-08', tokensTotal: 2000, sessionsCount: 1 }
      ]
    });
    expect(JSON.stringify(overview)).not.toMatch(/SECRET|raw_meta|prompt|response/i);
  });

  it('sums tokens per day from daily_rollup, not from session-level rows', () => {
    db.exec(`
      INSERT INTO daily_rollup(usage_date, provider_id, source_kind, project_id, model_canonical,
                               sessions_count, events_count, tokens_input, tokens_output,
                               tokens_cache_read, cost_usd_micros, cost_unknown_events)
      VALUES ('2026-07-07', 'claude-code', 'claude_jsonl', NULL, 'claude-fable-5', 1, 3, 100, 10, 900, 500, 0),
             ('2026-07-08', 'claude-code', 'claude_jsonl', NULL, 'claude-fable-5', 1, 2, 200, 20, 0, 700, 0);
    `);

    const overview = new DashboardRepository(db).overview();

    expect(overview.dailyTrend).toEqual([
      { usageDate: '2026-07-07', tokensTotal: 1010, sessionsCount: 1 },
      { usageDate: '2026-07-08', tokensTotal: 220, sessionsCount: 1 }
    ]);
  });

  it('counts distinct sessions instead of summing daily_rollup.sessions_count', () => {
    // 同一个 session 当天用了两个模型，会在 daily_rollup 里占两行
    db.exec(`
      INSERT INTO agent_sessions(id, source_kind, source_session_key, scan_root_id, source_revision)
      VALUES (1, 'claude_jsonl', 's1', 1, 'r');
      INSERT INTO session_rollup(session_id, first_event_epoch_ms, last_event_epoch_ms, events_count, tokens_total, cost_usd_micros, primary_model)
      VALUES (1, 1000, 2000, 2, 300, 100, 'claude-fable-5');
      INSERT INTO daily_rollup(usage_date, provider_id, source_kind, project_id, model_canonical,
                               sessions_count, events_count, tokens_input, cost_usd_micros, cost_unknown_events)
      VALUES ('2026-07-08', 'claude-code', 'claude_jsonl', NULL, 'claude-fable-5', 1, 1, 100, 50, 0),
             ('2026-07-08', 'claude-code', 'claude_jsonl', NULL, 'claude-opus-4-8', 1, 1, 200, 50, 0);
    `);

    const overview = new DashboardRepository(db).overview();

    expect(overview.sessionCount).toBe(1);
    expect(overview.activeModelCount).toBe(2);
  });

  it('reports unknown-cost events so the UI does not silently treat them as zero', () => {
    db.exec(`
      INSERT INTO daily_rollup(usage_date, provider_id, source_kind, project_id, model_canonical,
                               sessions_count, events_count, tokens_input, cost_usd_micros, cost_unknown_events)
      VALUES ('2026-07-08', 'codex', 'codex_jsonl', NULL, 'gpt-5.5', 1, 5, 100, 0, 5);
    `);

    const overview = new DashboardRepository(db).overview();

    expect(overview.costUnknownEvents).toBe(5);
  });

  it('keeps session_rollup and daily_rollup in agreement on total tokens', () => {
    // 两天、两模型、三个会话，其中一个会话跨天——跨天是关键，
    // 它是 daily_rollup 会拆行而 session_rollup 不会的唯一情形。
    seedUsageEvents(db, [
      { sessionId: 1, day: '2026-07-07', model: 'claude-fable-5', input: 100, output: 10 },
      { sessionId: 1, day: '2026-07-08', model: 'claude-fable-5', input: 200, output: 20 },
      { sessionId: 2, day: '2026-07-08', model: 'claude-opus-4-8', input: 300, output: 30 },
      { sessionId: 3, day: '2026-07-08', model: 'claude-opus-4-8', input: 400, output: 40 }
    ]);
    rebuildRollups(db);

    const fromSessions = (db.prepare('SELECT sum(tokens_total) AS n FROM session_rollup').get() as { n: number }).n;
    const fromDays = (
      db
        .prepare(
          `SELECT sum(tokens_input + tokens_output + tokens_cache_read
                      + tokens_cache_write_5m + tokens_cache_write_1h) AS n FROM daily_rollup`
        )
        .get() as { n: number }
    ).n;

    expect(fromSessions).toBe(1100);
    expect(fromDays).toBe(fromSessions);
  });

  it('dailyUsage returns daily rollups with token totals, session counts, and costs from provider_daily_usage only', () => {
    const rows = repo().dailyUsage({ from: '2026-07-01', to: '2026-07-03' });

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
    expect(repo().dailyUsage({ from: '2026-07-01', to: '2026-07-03', providerId: 'codex', projectId: 10 })).toEqual([
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
    expect(repo().dailyUsage({ from: '2026-07-01', to: '2026-07-03', providerId: 'missing' })).toEqual([]);
  });

  it('rejects malformed renderer daily usage filters instead of throwing TypeError or silently broadening the query', () => {
    const invalidFilters: Array<{ name: string; filter: unknown }> = [
      { name: 'null filter', filter: null },
      { name: 'array filter', filter: [] },
      { name: 'bad from date', filter: { from: 'not-a-date', to: '2026-07-03' } },
      { name: 'bad to date', filter: { from: '2026-07-01', to: '2026-07-99' } },
      { name: 'non-integer project id', filter: { from: '2026-07-01', to: '2026-07-03', projectId: 10.5 } },
      { name: 'negative project id', filter: { from: '2026-07-01', to: '2026-07-03', projectId: -1 } }
    ];

    for (const { name, filter } of invalidFilters) {
      expect(() => repo().dailyUsage(filter as never), name).toThrow(/dailyUsage filter/i);
    }
  });
});
