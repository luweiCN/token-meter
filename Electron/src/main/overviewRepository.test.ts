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
      status TEXT NOT NULL DEFAULT 'active', source_revision TEXT NOT NULL DEFAULT 'r',
      root_session_key TEXT, subagent_label TEXT
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
    -- usage_events：明细表（spec §4.1）。小时粒度趋势与热力图会话数走它，daily_rollup 只有天。
    -- Task 2 的 fixture 没建它；trendByHour 与 heatmap 的子查询都读这张表。
    CREATE TABLE usage_events (
      id INTEGER PRIMARY KEY,
      session_id INTEGER NOT NULL,
      source_file_id INTEGER NOT NULL DEFAULT 1,
      event_seq INTEGER NOT NULL DEFAULT 0,
      observed_epoch_ms INTEGER NOT NULL,
      model_canonical TEXT,
      tokens_input INTEGER NOT NULL DEFAULT 0,
      tokens_output INTEGER NOT NULL DEFAULT 0,
      tokens_reasoning INTEGER NOT NULL DEFAULT 0,
      tokens_cache_read INTEGER NOT NULL DEFAULT 0,
      tokens_cache_write_5m INTEGER NOT NULL DEFAULT 0,
      tokens_cache_write_1h INTEGER NOT NULL DEFAULT 0,
      cost_usd_micros INTEGER,
      cost_source TEXT NOT NULL DEFAULT 'reported',
      is_sidechain INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE source_files (
      id INTEGER PRIMARY KEY, scan_root_id INTEGER NOT NULL DEFAULT 1,
      relative_path TEXT NOT NULL DEFAULT '', subagent_label TEXT
    );
    -- 空状态判据表（TokenMeterDatabaseSchema.swift 的 scan_roots，取本判据用到的列）。
    CREATE TABLE scan_roots (
      id INTEGER PRIMARY KEY, kind TEXT NOT NULL, root_path TEXT NOT NULL,
      display_name TEXT NOT NULL DEFAULT '', enabled INTEGER NOT NULL DEFAULT 1,
      scan_mode TEXT NOT NULL DEFAULT 'incremental', stable_source_key TEXT NOT NULL DEFAULT 'k'
    );
  `);
});

function seedScanRoot(id: number, rootPath: string, enabled = 1, scanMode = 'incremental') {
  db.prepare(`INSERT INTO scan_roots(id, kind, root_path, enabled, scan_mode, stable_source_key)
              VALUES (?,?,?,?,?,?)`).run(id, 'claude_jsonl', rootPath, enabled, scanMode, `k${id}`);
}

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

/// 子会话：root_session_key 指向父会话的 source_session_key（`s<父id>`），同 source_kind。
function seedSubSession(id: number, provider: string, rootSessionKey: string, label: string,
                       lastEventMsAgo: number, tokens: number, cost = 1000) {
  db.prepare(`INSERT INTO agent_sessions(id, source_kind, source_session_key, scan_root_id, provider_id, root_session_key, subagent_label)
              VALUES (?,?,?,1,?,?,?)`).run(id, `${provider}_jsonl`, `s${id}`, provider, rootSessionKey, label);
  const last = NOW - lastEventMsAgo;
  db.prepare(`INSERT INTO session_rollup(session_id, first_event_epoch_ms, last_event_epoch_ms, events_count,
              tokens_total, cost_usd_micros, primary_model) VALUES (?,?,?,?,?,?,?)`)
    .run(id, last - 60_000, last, 2, tokens, cost, 'sub-model');
}

// localDateTime 无时区 → JS 按本地时区解析，SQLite 的 'localtime' 再转回同一本地日期。
// 取正午等非边界时刻，避免午夜/DST 的日期归属歧义。
function seedEvent(id: number, sessionId: number, localDateTime: string, model = 'm') {
  db.prepare(`INSERT INTO usage_events(id, session_id, observed_epoch_ms, model_canonical)
              VALUES (?,?,?,?)`).run(id, sessionId, Date.parse(localDateTime), model);
}

function seedSourceFile(id: number, subagentLabel: string | null) {
  db.prepare(`INSERT INTO source_files(id, relative_path, subagent_label) VALUES (?,?,?)`)
    .run(id, `f${id}.jsonl`, subagentLabel);
}

/// Claude 子代理事件：is_sidechain=1，归在父会话，按 source_file 区分是哪个子代理。
function seedSidechainEvent(id: number, sessionId: number, sourceFileId: number, localDateTime: string,
                           tokensInput: number, model = 'm') {
  db.prepare(`INSERT INTO usage_events(id, session_id, source_file_id, observed_epoch_ms, model_canonical, tokens_input, is_sidechain)
              VALUES (?,?,?,?,?,?,1)`).run(id, sessionId, sourceFileId, Date.parse(localDateTime), model, tokensInput);
}

describe('subagentBreakdown', () => {
  it('lists the sub-sessions of a non-Claude main session, newest first, with labels and totals', () => {
    seedSession(1, 'codex', 'proj', 60_000, 1000);
    seedSubSession(2, 'codex', 's1', 'worker', 30 * 60_000, 500, 2000);   // 30 分钟前
    seedSubSession(3, 'codex', 's1', 'explorer', 60_000, 300, 1500);      // 1 分钟前

    const rows = new OverviewRepository(db, () => NOW).subagentBreakdown(1);

    expect(rows).toHaveLength(2);
    expect(rows[0].label).toBe('explorer');           // 按 lastEvent 倒序
    expect(rows[0].tokens).toBe(300);
    expect(rows[0].costUsdMicros).toBe(1500);
    expect(rows[1].label).toBe('worker');
    expect(rows[1].tokens).toBe(500);
  });

  it('groups a Claude main session\'s sidechain events by source file, labeled from the file', () => {
    seedSession(1, 'claude', 'proj', 60_000, 1000);   // source_kind = 'claude_jsonl'
    seedSourceFile(10, 'general-purpose');
    seedSourceFile(11, 'Explore');
    seedSidechainEvent(100, 1, 10, '2026-07-10T11:00:00+08:00', 400);
    seedSidechainEvent(101, 1, 10, '2026-07-10T11:05:00+08:00', 100);   // 同文件第二条
    seedSidechainEvent(102, 1, 11, '2026-07-10T11:50:00+08:00', 200);

    const rows = new OverviewRepository(db, () => NOW).subagentBreakdown(1);

    expect(rows).toHaveLength(2);                       // 两个子代理文件
    expect(rows[0].label).toBe('Explore');             // 11:50 最近
    expect(rows[0].tokens).toBe(200);
    expect(rows[1].label).toBe('general-purpose');
    expect(rows[1].tokens).toBe(500);                  // 400 + 100（同文件两条）
  });

  it('returns nothing for a main session with no sub-agents', () => {
    seedSession(1, 'codex', 'proj', 60_000, 1000);
    expect(new OverviewRepository(db, () => NOW).subagentBreakdown(1)).toEqual([]);
  });
});

describe('sessionRail sub-agent merging', () => {
  it('lists only main sessions, sums sub-agent tokens/cost, and folds their activity into isLive', () => {
    // 父会话自己 10 分钟前（超出 5 分钟 live 窗口，自己不 live）
    seedSession(1, 'codex', 'proj', 10 * 60_000, 1000);
    // 两个子会话指向 s1：一个 30 分钟前，一个 1 分钟前（让主会话归并后变 live）
    seedSubSession(2, 'codex', 's1', 'worker', 30 * 60_000, 500);
    seedSubSession(3, 'codex', 's1', 'explorer', 1 * 60_000, 300);

    const rail = new OverviewRepository(db, () => NOW).sessionRail(10);

    expect(rail).toHaveLength(1);              // 只列主会话，子会话不单独出现
    expect(rail[0].sessionId).toBe(1);
    expect(rail[0].tokensTotal).toBe(1800);    // 1000 + 500 + 300
    expect(rail[0].costUsdMicros).toBe(3000);  // 1000 + 1000 + 1000
    expect(rail[0].subagentCount).toBe(2);
    expect(rail[0].isLive).toBe(true);         // 父自己 10min 前不 live，但子 1min 前 → 归并后 live
  });

  it('a main session with no sub-agents keeps its own totals and subagentCount 0', () => {
    seedSession(1, 'claude-code', 'proj', 60_000, 700);
    const rail = new OverviewRepository(db, () => NOW).sessionRail(10);
    expect(rail).toHaveLength(1);
    expect(rail[0].subagentCount).toBe(0);
    expect(rail[0].tokensTotal).toBe(700);
  });
});

describe('kpis todaySessions sub-agent handling', () => {
  it('counts only main sessions, excluding sub-agent sessions', () => {
    seedSession(1, 'codex', 'proj', 60_000, 1000);        // 父，1 分钟前（今天）
    seedSubSession(2, 'codex', 's1', 'worker', 120_000, 500);  // 子，指向 s1，今天

    const k = new OverviewRepository(db, () => NOW).kpis();
    expect(k.todaySessions).toBe(1);  // 只数父，子代理不灌水
  });
});

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

describe('trend', () => {
  it('returns four stack segments per bucket, cache split from input', () => {
    db.exec(`
      INSERT INTO daily_rollup(usage_date, provider_id, source_kind, project_id, model_canonical,
        sessions_count, events_count, tokens_input, tokens_output, tokens_cache_read,
        tokens_cache_write_5m, tokens_cache_write_1h, cost_usd_micros)
      VALUES ('2026-07-09','claude-code','claude_jsonl',NULL,'m',1,1, 100, 10, 900, 5, 3, 1),
             ('2026-07-10','claude-code','claude_jsonl',NULL,'m',1,1, 200, 20,   0, 0, 0, 1);
    `);

    const rows = new OverviewRepository(db, () => NOW).trend('2026-07-09', '2026-07-10', 'day');

    expect(rows).toEqual([
      { bucket: '2026-07-09', input: 100, cacheWrite: 8, cacheRead: 900, output: 10 },
      { bucket: '2026-07-10', input: 200, cacheWrite: 0, cacheRead: 0, output: 20 }
    ]);
  });

  it('fills gaps with zero buckets so the x axis has no holes', () => {
    db.exec(`INSERT INTO daily_rollup(usage_date, provider_id, source_kind, project_id, model_canonical,
      sessions_count, events_count, tokens_input, cost_usd_micros)
      VALUES ('2026-07-08','c','k',NULL,'m',1,1,10,1), ('2026-07-10','c','k',NULL,'m',1,1,20,1);`);

    const rows = new OverviewRepository(db, () => NOW).trend('2026-07-08', '2026-07-10', 'day');

    expect(rows.map(r => r.bucket)).toEqual(['2026-07-08', '2026-07-09', '2026-07-10']);
    expect(rows[1]).toEqual({ bucket: '2026-07-09', input: 0, cacheWrite: 0, cacheRead: 0, output: 0 });
  });

  it('rejects a granularity the range does not allow', () => {
    const repo = new OverviewRepository(db, () => NOW);
    expect(() => repo.trend('2026-06-11', '2026-07-10', 'hour')).toThrow(/hour.*not allowed/i);
  });
});

describe('heatmap', () => {
  it('returns one row per day that has data, with three switchable metrics', () => {
    db.exec(`INSERT INTO daily_rollup(usage_date, provider_id, source_kind, project_id, model_canonical,
      sessions_count, events_count, tokens_input, tokens_output, cost_usd_micros)
      VALUES ('2026-07-09','c','k',NULL,'m1', 1, 3, 100, 10, 500),
             ('2026-07-09','c','k',NULL,'m2', 1, 2,  50,  5, 300),
             ('2026-07-10','c','k',NULL,'m1', 1, 1,  20,  2, 100);`);
    // sessions 走 usage_events 的 count(distinct)，与 token/成本/事件分开取。
    // 07-09 是两个不同会话，07-10 是一个会话。
    seedEvent(1, 1, '2026-07-09T09:00:00');
    seedEvent(2, 2, '2026-07-09T10:00:00');
    seedEvent(3, 1, '2026-07-10T09:00:00');

    const rows = new OverviewRepository(db, () => NOW).heatmap('2026-07-09', '2026-07-10');

    expect(rows).toEqual([
      { date: '2026-07-09', tokens: 165, costUsdMicros: 800, sessions: 2, events: 5 },
      { date: '2026-07-10', tokens: 22, costUsdMicros: 100, sessions: 1, events: 1 }
    ]);
  });

  it('counts distinct sessions, not summed sessions_count, when one session used two models', () => {
    // 同一会话当天用了两个模型 → 两行 daily_rollup、各 sessions_count=1，naive sum = 2。
    // 但 usage_events 里只有一个 session_id → 正确会话数是 1。RollupBuilder.swift L44-49 同旨。
    db.exec(`INSERT INTO daily_rollup(usage_date, provider_id, source_kind, project_id, model_canonical,
      sessions_count, events_count, tokens_input, cost_usd_micros)
      VALUES ('2026-07-09','c','k',NULL,'m1', 1, 1, 100, 1),
             ('2026-07-09','c','k',NULL,'m2', 1, 1, 200, 1);`);
    seedEvent(1, 7, '2026-07-09T09:00:00', 'm1');
    seedEvent(2, 7, '2026-07-09T10:00:00', 'm2');

    const rows = new OverviewRepository(db, () => NOW).heatmap('2026-07-09', '2026-07-09');

    expect(rows[0].sessions).toBe(1);   // NOT sum(sessions_count) = 2
  });
});

describe('modelRanking', () => {
  it('ranks by cost or by tokens, and reports unknown-cost events per model', () => {
    db.exec(`INSERT INTO daily_rollup(usage_date, provider_id, source_kind, project_id, model_canonical,
      sessions_count, events_count, tokens_input, cost_usd_micros, cost_unknown_events)
      VALUES ('2026-07-10','c','k',NULL,'cheap-but-huge', 1, 1, 1000, 100, 0),
             ('2026-07-10','c','k',NULL,'pricey-but-small', 1, 1,  10, 900, 0),
             ('2026-07-10','c','k',NULL,'unpriced',        1, 4,  50, NULL, 4);`);

    const repo = new OverviewRepository(db, () => NOW);

    expect(repo.modelRanking('2026-07-10', '2026-07-10', 'cost').map(m => m.model))
      .toEqual(['pricey-but-small', 'cheap-but-huge', 'unpriced']);
    expect(repo.modelRanking('2026-07-10', '2026-07-10', 'tokens').map(m => m.model))
      .toEqual(['cheap-but-huge', 'unpriced', 'pricey-but-small']);

    const unpriced = repo.modelRanking('2026-07-10', '2026-07-10', 'tokens')
      .find(m => m.model === 'unpriced')!;
    expect(unpriced.costUsdMicros).toBe(0);
    expect(unpriced.costUnknownEvents).toBe(4);   // 成本是 0 还是「不知道」，UI 必须能区分
  });
});

describe('dataState', () => {
  it('reports ready as soon as usage_events has any row', () => {
    seedScanRoot(1, '/corpus/claude');
    seedEvent(1, 1, '2026-07-09T09:00:00');
    // corpus 判据函数在 ready 分支不该被咨询——有明细就是有数据。
    expect(new OverviewRepository(db, () => NOW).dataState(() => false)).toBe('ready');
  });

  it('reports never-used when no scan root is enabled', () => {
    seedScanRoot(1, '/corpus/claude', 0);            // 停用
    seedScanRoot(2, '/corpus/codex', 1, 'disabled'); // scan_mode disabled
    expect(new OverviewRepository(db, () => NOW).dataState(() => true)).toBe('never-used');
  });

  it('reports never-used when enabled roots point at corpora that do not exist on disk', () => {
    seedScanRoot(1, '/corpus/claude');               // 启用，但目录不存在
    expect(new OverviewRepository(db, () => NOW).dataState(() => false)).toBe('never-used');
  });

  it('reports needs-reindex when enabled roots have a present corpus but usage_events is empty', () => {
    // 升级后尚未重扫：scan_roots 有启用项、语料在，但 rollup/明细都空。
    seedScanRoot(1, '/corpus/missing');
    seedScanRoot(2, '/corpus/present');
    const present = (p: string) => p === '/corpus/present';
    expect(new OverviewRepository(db, () => NOW).dataState(present)).toBe('needs-reindex');
  });

  it('survives a v1 database whose usage_events table does not exist yet', () => {
    // 迁移由 Swift 触发；Electron 直接打开尚未迁移的 v1 库时 usage_events 尚不存在，
    // dataState 必须按「空」处理而不是抛 no such table。本机生产库就是这个状态。
    const v1 = new Database(':memory:');
    v1.exec(`CREATE TABLE scan_roots (id INTEGER PRIMARY KEY, kind TEXT NOT NULL, root_path TEXT NOT NULL,
      display_name TEXT NOT NULL DEFAULT '', enabled INTEGER NOT NULL DEFAULT 1,
      scan_mode TEXT NOT NULL DEFAULT 'incremental', stable_source_key TEXT NOT NULL DEFAULT 'k');
      INSERT INTO scan_roots(id, kind, root_path, stable_source_key) VALUES (1,'claude_jsonl','/corpus/claude','k1');`);
    expect(new OverviewRepository(v1, () => NOW).dataState(() => true)).toBe('needs-reindex');
    v1.close();
  });
});

describe('buildOverview', () => {
  it('short-circuits to the empty payload without running section queries when not ready', () => {
    // 关键：needs-reindex 时绝不能去跑 kpis/trend/heatmap——生产 v1 库里那些表还不存在，
    // 跑了就 no such table。这里 usage_events 空、有启用扫描源+语料在 → needs-reindex。
    seedScanRoot(1, '/corpus/present');
    const payload = new OverviewRepository(db, () => NOW).buildOverview(() => true);
    expect(payload).toEqual({ dataState: 'needs-reindex' });
  });

  it('assembles every section when there is data', () => {
    seedScanRoot(1, '/corpus/present');
    db.exec(`INSERT INTO daily_rollup(usage_date, provider_id, source_kind, project_id, model_canonical,
      sessions_count, events_count, tokens_input, tokens_output, cost_usd_micros, cost_unknown_events)
      VALUES ('2026-07-10','claude-code','claude_jsonl',NULL,'claude-fable-5', 1, 2, 100, 10, 500, 1);`);
    seedSession(1, 'claude-code', 'token-meter', 30_000, 110);
    seedEvent(1, 1, '2026-07-10T09:00:00');

    const payload = new OverviewRepository(db, () => NOW).buildOverview(() => true);

    expect(payload.dataState).toBe('ready');
    if (payload.dataState !== 'ready') throw new Error('expected ready');
    expect(payload.kpis.todayTokens).toBe(110);
    expect(payload.trend.length).toBeGreaterThan(0);
    expect(payload.trend[payload.trend.length - 1].bucket).toBe('2026-07-10');   // 末桶是今天
    expect(payload.heatmapLastDay).toBe('2026-07-10');
    expect(payload.modelRanking.map(m => m.model)).toContain('claude-fable-5');
    expect(payload.sessionRail.map(s => s.projectName)).toContain('token-meter');
  });
});

describe('sessionRail', () => {
  it('pins live sessions to the top, each group ordered by most recent, carrying duration and cost', () => {
    seedSession(1, 'claude-code', 'a', 30_000, 100);      // live, 30s 前
    seedSession(2, 'codex', 'b', 2 * 60_000, 100);        // live, 2min 前
    seedSession(3, 'claude-code', 'c', 20 * 60_000, 100); // 已结束, 20min 前
    seedSession(4, 'codex', 'd', 40 * 60_000, 100);       // 已结束, 40min 前

    const rows = new OverviewRepository(db, () => NOW).sessionRail(10);

    // live 组置顶，两组各自按最近事件倒序
    expect(rows.map(r => r.sessionId)).toEqual([1, 2, 3, 4]);
    expect(rows.map(r => r.isLive)).toEqual([true, true, false, false]);
    // 时长（firstEventEpochMs）与成本随行返回，供右栏展示
    expect(rows[0].firstEventEpochMs).toBe(NOW - 30_000 - 60_000);
    expect(rows[0].costUsdMicros).toBe(1000);
    expect(rows[0].costUnknownEvents).toBe(0);   // 成本可能部分未知，右栏也要能表达
  });
});
