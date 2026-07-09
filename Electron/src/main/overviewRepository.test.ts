import { describe, it, expect, beforeEach } from 'vitest';
import Database from 'better-sqlite3';
import { OverviewRepository } from './overviewRepository.js';

// 固定「现在」，否则测试会在午夜前后随机变红。
const NOW = Date.parse('2026-07-10T12:00:00+08:00');

let db: Database.Database;

beforeEach(() => {
  db = new Database(':memory:');
  db.exec(`
    CREATE TABLE agent_sessions (
      id INTEGER PRIMARY KEY, source_kind TEXT NOT NULL, source_session_key TEXT NOT NULL,
      scan_root_id INTEGER NOT NULL, project_id INTEGER, provider_id TEXT,
      status TEXT NOT NULL DEFAULT 'active', source_revision TEXT NOT NULL DEFAULT 'r'
    );
    CREATE TABLE projects (id INTEGER PRIMARY KEY, canonical_path TEXT NOT NULL, display_name TEXT NOT NULL,
      project_key TEXT NOT NULL DEFAULT 'k', first_seen_at TEXT NOT NULL DEFAULT '', last_seen_at TEXT NOT NULL DEFAULT '');
    CREATE TABLE session_rollup (
      session_id INTEGER PRIMARY KEY, first_event_epoch_ms INTEGER NOT NULL, last_event_epoch_ms INTEGER NOT NULL,
      events_count INTEGER NOT NULL, tokens_total INTEGER NOT NULL, cost_usd_micros INTEGER,
      cost_unknown_events INTEGER NOT NULL DEFAULT 0, primary_model TEXT
    );
    CREATE TABLE daily_rollup (
      usage_date TEXT NOT NULL, provider_id TEXT NOT NULL, source_kind TEXT NOT NULL, project_id INTEGER,
      model_canonical TEXT NOT NULL, sessions_count INTEGER NOT NULL DEFAULT 0, events_count INTEGER NOT NULL DEFAULT 0,
      tokens_input INTEGER NOT NULL DEFAULT 0, tokens_output INTEGER NOT NULL DEFAULT 0,
      tokens_reasoning INTEGER NOT NULL DEFAULT 0, tokens_cache_read INTEGER NOT NULL DEFAULT 0,
      tokens_cache_write_5m INTEGER NOT NULL DEFAULT 0, tokens_cache_write_1h INTEGER NOT NULL DEFAULT 0,
      cost_usd_micros INTEGER, cost_unknown_events INTEGER NOT NULL DEFAULT 0
    );
    -- 生产库用带表达式的 UNIQUE INDEX 而非 PRIMARY KEY（SQLite 禁止在 PK 约束里写表达式）。
    -- 见 TokenMeterDatabaseSchema.swift 的 idx_daily_rollup_unique。
    CREATE UNIQUE INDEX idx_daily_rollup_unique
      ON daily_rollup(usage_date, provider_id, source_kind, coalesce(project_id,-1), model_canonical);
  `);
});

function seedSession(id: number, provider: string, project: string, lastEventMsAgo: number, tokens: number) {
  db.prepare(`INSERT OR IGNORE INTO projects(id, canonical_path, display_name) VALUES (?,?,?)`)
    .run(id, `/p/${project}`, project);
  db.prepare(`INSERT INTO agent_sessions(id, source_kind, source_session_key, scan_root_id, project_id, provider_id)
              VALUES (?,?,?,1,?,?)`).run(id, `${provider}_jsonl`, `s${id}`, id, provider);
  const last = NOW - lastEventMsAgo;
  db.prepare(`INSERT INTO session_rollup(session_id, first_event_epoch_ms, last_event_epoch_ms, events_count,
              tokens_total, cost_usd_micros, primary_model) VALUES (?,?,?,?,?,?,?)`)
    .run(id, last - 60_000, last, 3, tokens, 1000, 'claude-fable-5');
}

describe('recentActivity', () => {
  it('orders by last event descending and marks only fresh sessions as live', () => {
    seedSession(1, 'claude-code', 'token-meter', 12_000, 500);      // 12 秒前
    seedSession(2, 'codex', 'health', 13 * 60_000, 300);            // 13 分钟前
    seedSession(3, 'claude-code', 'vainglory', 3 * 3600_000, 100);  // 3 小时前

    const rows = new OverviewRepository(db, () => NOW).recentActivity(5);

    expect(rows.map(r => r.projectName)).toEqual(['token-meter', 'health', 'vainglory']);
    expect(rows.map(r => r.isLive)).toEqual([true, false, false]);
    expect(rows[0].providerId).toBe('claude-code');
    expect(rows[0].msSinceLastEvent).toBe(12_000);
  });

  it('treats exactly 5 minutes as not live', () => {
    // 边界必须钉死，否则「5 分钟内」会在实现里漂成 <= 或 <
    seedSession(1, 'claude-code', 'p', 5 * 60_000, 1);
    expect(new OverviewRepository(db, () => NOW).recentActivity(5)[0].isLive).toBe(false);
  });

  it('returns an empty list rather than throwing when nothing was ever indexed', () => {
    expect(new OverviewRepository(db, () => NOW).recentActivity(5)).toEqual([]);
  });
});

describe('kpis', () => {
  it('sums today from daily_rollup and counts sessions from session_rollup', () => {
    // 同一个会话当天用了两个模型 → daily_rollup 两行；会话数必须是 1，不是 2。
    db.exec(`
      INSERT INTO daily_rollup(usage_date, provider_id, source_kind, project_id, model_canonical,
                               sessions_count, events_count, tokens_input, tokens_output, cost_usd_micros)
      VALUES ('2026-07-10','claude-code','claude_jsonl',NULL,'claude-fable-5', 1, 1, 100, 10, 500),
             ('2026-07-10','claude-code','claude_jsonl',NULL,'claude-opus-4-8', 1, 1, 200, 20, 700),
             ('2026-07-09','claude-code','claude_jsonl',NULL,'claude-fable-5', 1, 1,  50,  5, 100);
    `);
    seedSession(1, 'claude-code', 'p', 1000, 330);

    const k = new OverviewRepository(db, () => NOW).kpis();

    expect(k.todayTokens).toBe(330);        // 100+10+200+20
    expect(k.todayCostUsdMicros).toBe(1200);
    expect(k.todaySessions).toBe(1);        // NOT sum(sessions_count) = 2
    expect(k.yesterdayTokens).toBe(55);
  });

  it('reports unknown-cost events instead of silently treating them as zero', () => {
    db.exec(`
      INSERT INTO daily_rollup(usage_date, provider_id, source_kind, project_id, model_canonical,
                               sessions_count, events_count, tokens_input, cost_usd_micros, cost_unknown_events)
      VALUES ('2026-07-10','codex','codex_jsonl',NULL,'gpt-5.5', 1, 5, 100, NULL, 5);
    `);
    const k = new OverviewRepository(db, () => NOW).kpis();
    expect(k.todayCostUnknownEvents).toBe(5);
    expect(k.todayCostUsdMicros).toBe(0);   // NULL 不能变成别的数字
  });
});
