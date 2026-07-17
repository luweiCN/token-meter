import { useCallback, useEffect, useMemo, useState } from 'react';

import type { SessionItem, SessionProjectOption, SessionsFilter, SessionTrendResult, SubagentRow } from '../api.js';
import { StackedTrendChart, type TrendSeriesDef } from '../charts/StackedTrendChart.js';
import { DateRangePicker, MultiSelect, Pager, type DateRange } from '../components/ui.js';
import {
  formatCount,
  formatDurationShort,
  formatTokens,
  formatUnknownCostNote,
  formatUsdMicros
} from '../format.js';

/// agent 系列（与总览趋势图同色序 s1-s4；名单外 provider 归「其他」）。
const TREND_PROVIDERS: TrendSeriesDef[] = [
  { id: 'claude-code', label: 'Claude Code', color: 'var(--s1)' },
  { id: 'codex', label: 'Codex CLI', color: 'var(--s2)' },
  { id: 'omp', label: 'OMP', color: 'var(--s3)' },
  { id: 'opencode', label: 'OpenCode', color: 'var(--s4)' }
];
const TREND_OTHER: TrendSeriesDef = { id: '__other', label: '其他', color: 'var(--muted)' };

/// 会话活跃趋势直方图：每天活跃的会话个数（按 agent 堆叠，跟随列表筛选）。
/// 会话页的主指标是「会话」不是 token（用户裁定 2026-07-17）；token/花费
/// 合计在上方统计卡，均为事件日口径。
function SessionTrendCard({ trend }: { trend: SessionTrendResult | null }) {
  const byBucket = useMemo(() => {
    if (trend === null) return new Map<string, Map<string, number>>();
    const known = new Set(TREND_PROVIDERS.map((p) => p.id));
    const m = new Map<string, Map<string, number>>();
    for (const row of trend.rows) {
      const key = known.has(row.providerId) ? row.providerId : TREND_OTHER.id;
      let inner = m.get(row.bucket);
      if (!inner) {
        inner = new Map();
        m.set(row.bucket, inner);
      }
      inner.set(key, (inner.get(key) ?? 0) + row.sessions);
    }
    return m;
  }, [trend]);

  const series = useMemo(() => {
    if (trend === null) return [];
    const present = new Set(trend.rows.map((r) => r.providerId));
    const known = TREND_PROVIDERS.filter((p) => present.has(p.id));
    const hasOther = [...present].some((id) => !TREND_PROVIDERS.some((p) => p.id === id));
    return hasOther ? [...known, TREND_OTHER] : known;
  }, [trend]);

  if (trend === null || trend.rows.length === 0) return null;
  return (
    <div className="card">
      <div className="chead">
        <div>
          <h2>活跃趋势</h2>
          <div className="desc">每日活跃会话数 · 按 Agent 堆叠 · 跟随筛选</div>
        </div>
      </div>
      <StackedTrendChart
        buckets={trend.buckets}
        series={series}
        valueOf={(bucket, seriesId) => byBucket.get(bucket)?.get(seriesId) ?? 0}
        formatValue={(value) => formatCount(Math.round(value))}
        ariaLabel="每日活跃会话数直方图"
      />
    </div>
  );
}

/// 会话页统计卡（跟随筛选）：会话数 = 列表 total；Token/花费 = 事件日口径
/// （与菜单栏「今日」同源可对账）；活跃天数 = 趋势里有数据的天数。
function SessionStatCards({ total, trend }: { total: number; trend: SessionTrendResult | null }) {
  const sums = useMemo(() => {
    if (trend === null) return { tokens: 0, cost: 0, activeDays: 0 };
    let tokens = 0;
    let cost = 0;
    const days = new Set<string>();
    for (const row of trend.rows) {
      tokens += row.tokens;
      // dev 工作流里 renderer 热更快于 bundle 主进程，旧 trend 行无 cost 字段。
      cost += row.costUsdMicros ?? 0;
      days.add(row.bucket);
    }
    return { tokens, cost, activeDays: days.size };
  }, [trend]);

  return (
    <div className="stats">
      <div className="stat">
        <div className="lb">会话</div>
        <div className="v num">{formatCount(total)}</div>
        <div className="sb">筛选范围内的主会话</div>
      </div>
      <div className="stat">
        <div className="lb">Token</div>
        <div className="v num">{formatTokens(sums.tokens)}</div>
        <div className="sb">按事件实际发生日统计</div>
      </div>
      <div className="stat">
        <div className="lb">花费</div>
        <div className="v num">{formatUsdMicros(sums.cost)}</div>
        <div className="sb">不含价格未知事件</div>
      </div>
      <div className="stat">
        <div className="lb">活跃天数</div>
        <div className="v num">{formatCount(sums.activeDays)}</div>
        <div className="sb">范围内有用量的天数</div>
      </div>
    </div>
  );
}

type SortKey = NonNullable<SessionsFilter['sortBy']>;

/// "7/13 19:54"（设计稿的开始时间格式，本地时区）。
function formatShortDateTime(epochMs: number): string {
  const d = new Date(epochMs);
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${d.getMonth() + 1}/${d.getDate()} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

/// 会话名单元格：绝大多数会话源日志里没有标题（97% 是程序化调用），
/// 满屏「未命名会话」比没有更糟——没标题时直接用 mono 会话号当主行。
export function SessionCell({ session, showProject }: { session: SessionItem; showProject?: boolean }) {
  const sub = [showProject ? session.projectDisplayName ?? '未归属项目' : null, session.title ? session.sessionKey.slice(0, 12) : null]
    .filter(Boolean)
    .join(' · ');
  return (
    <>
      {session.title
        ? <span className="t1">{session.title}</span>
        : <span className="t1 num">{session.sessionKey.slice(0, 18)}</span>}
      {sub ? <span className="t2">{sub}</span> : null}
    </>
  );
}

/// 会话页（OpenDesign 稿 view-sessions / view-session-detail）：
/// 列表（项目/日期/搜索筛选 + Token/成本/开始排序）与详情（四统计卡 +
/// 子代理模型分布 + 花费 Top5 + 子代理任务表）双视图，详情数据走已有的
/// subagentBreakdown 下钻。只展示用量元数据，绝不展示提示词或回复正文。
export function Sessions() {
  const [selected, setSelected] = useState<SessionItem | null>(null);
  if (selected) {
    return <SessionDetail session={selected} onBack={() => setSelected(null)} />;
  }
  return <SessionList onOpen={setSelected} />;
}

const PAGE_SIZE = 50;

function SessionList({ onOpen }: { onOpen: (session: SessionItem) => void }) {
  const [projects, setProjects] = useState<SessionProjectOption[]>([]);
  const [projectIds, setProjectIds] = useState<number[]>([]);
  const [range, setRange] = useState<DateRange | null>(null);
  const [search, setSearch] = useState('');
  const [debouncedSearch, setDebouncedSearch] = useState('');
  const [sortBy, setSortBy] = useState<SortKey>('start');
  const [sortDir, setSortDir] = useState<'asc' | 'desc'>('desc');
  const [page, setPage] = useState(1);
  const [items, setItems] = useState<SessionItem[]>([]);
  const [total, setTotal] = useState(0);
  const [trend, setTrend] = useState<SessionTrendResult | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);

  useEffect(() => {
    void window.tokenMeter.sessions.projects().then(setProjects).catch(() => {});
  }, []);

  // 搜索防抖：300ms 静默后才下查询，避免每个键击都打 IPC。
  useEffect(() => {
    const timer = window.setTimeout(() => setDebouncedSearch(search), 300);
    return () => window.clearTimeout(timer);
  }, [search]);

  // 筛选/排序变化回到第 1 页。
  useEffect(() => {
    setPage(1);
  }, [projectIds, range, debouncedSearch, sortBy, sortDir]);

  const load = useCallback(async () => {
    try {
      const filter: SessionsFilter = {
        limit: PAGE_SIZE,
        offset: (page - 1) * PAGE_SIZE,
        sortBy,
        sortDir,
        ...(projectIds.length === 0 ? {} : { projectIds }),
        ...(range === null ? {} : { dateFrom: range.from, dateTo: range.to }),
        ...(debouncedSearch.trim() === '' ? {} : { search: debouncedSearch.trim() })
      };
      // 趋势不受分页影响：filter 去掉 limit/offset 后单独查。
      const { limit: _limit, offset: _offset, ...trendFilter } = filter;
      const [result, trendResult] = await Promise.all([
        window.tokenMeter.sessions.query(filter),
        window.tokenMeter.sessions.trend(trendFilter)
      ]);
      setItems(result.items);
      setTotal(result.total);
      setTrend(trendResult);
      setLoadError(null);
    } catch (unknownError: unknown) {
      setLoadError(unknownError instanceof Error ? unknownError.message : '会话列表加载失败');
    }
  }, [page, projectIds, range, debouncedSearch, sortBy, sortDir]);

  useEffect(() => {
    void load();
  }, [load]);

  const onSort = (key: SortKey) => {
    if (key === sortBy) {
      setSortDir((d) => (d === 'asc' ? 'desc' : 'asc'));
    } else {
      setSortBy(key);
      setSortDir('desc');
    }
  };

  const sortClass = (key: SortKey) => `r sort${sortBy === key ? ` ${sortDir}` : ''}`;
  const pageCount = Math.max(1, Math.ceil(total / PAGE_SIZE));
  const maxTokens = useMemo(() => items.reduce((max, it) => Math.max(max, it.tokensTotal), 0), [items]);

  return (
    <section className="view">
      <div className="vhead">
        <h1>会话</h1>
        <span className="sub">
          {projects.length} 个项目 · <b className="num">{total.toLocaleString()}</b> 个会话
        </span>
        <div className="spacer" />
      </div>

      <div className="card sess-filter-card">
        <div className="sess-filter">
          <MultiSelect
            ariaLabel="按项目筛选"
            values={projectIds}
            allLabel="全部项目"
            searchPlaceholder="搜索项目"
            options={projects.map((p) => ({ value: p.id, label: p.displayName }))}
            onChange={setProjectIds}
          />
          <DateRangePicker ariaLabel="按日期筛选" value={range} onChange={setRange} />
          <div className="grow" />
          <div className="field">
            <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
              <circle cx="5" cy="5" r="3.6" stroke="var(--muted)" strokeWidth="1.4" />
              <path d="m8 8 2.6 2.6" stroke="var(--muted)" strokeWidth="1.4" strokeLinecap="round" />
            </svg>
            <input
              type="search"
              placeholder="搜索会话标题 / 模型"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
            />
          </div>
        </div>
      </div>

      {loadError ? <p className="status-error" role="status">会话列表加载失败：{loadError}</p> : null}

      <SessionStatCards total={total} trend={trend} />
      <SessionTrendCard trend={trend} />

      <div className="card sess-table-card">
        <div className="hscroll">
          <table className="sess-table">
            <thead>
              <tr>
                <th>会话</th>
                <th>模型</th>
                <th className={sortClass('tokens')} onClick={() => onSort('tokens')}>Token</th>
                <th className={sortClass('cost')} onClick={() => onSort('cost')}>成本</th>
                <th className={sortClass('start')} onClick={() => onSort('start')}>开始</th>
                <th className="r hide-sm">时长</th>
                <th className="r">子代理</th>
              </tr>
            </thead>
            <tbody>
              {items.map((s) => {
                const unknownNote = formatUnknownCostNote(s.costUnknownEvents);
                return (
                  <tr key={`${s.sourceKind}:${s.sessionKey}`} className="sess-row" onClick={() => onOpen(s)}>
                    <td><SessionCell session={s} showProject /></td>
                    <td><span className="mname">{s.modelName ?? '—'}</span></td>
                    <td className="r num">
                      <span className="rowbar">
                        <span>{formatTokens(s.tokensTotal)}</span>
                        <i style={{ width: `${maxTokens > 0 ? (s.tokensTotal / maxTokens) * 100 : 0}%` }} />
                      </span>
                    </td>
                    <td className="r num" title={unknownNote ? `部分事件价格未知（${unknownNote}）` : undefined}>
                      {formatUsdMicros(s.costUsdMicros)}{unknownNote ? '†' : ''}
                    </td>
                    <td className="r num">{formatShortDateTime(s.firstEventEpochMs)}</td>
                    <td className="r num hide-sm">
                      {formatDurationShort(Math.max(0, s.lastEventEpochMs - s.firstEventEpochMs))}
                    </td>
                    <td className="r num">{s.subagentCount}</td>
                  </tr>
                );
              })}
              {items.length === 0 && !loadError ? (
                <tr><td colSpan={7} className="muted sess-empty">没有匹配的会话。</td></tr>
              ) : null}
            </tbody>
          </table>
        </div>
        <Pager page={page} pageCount={pageCount} onPage={setPage} />
      </div>
    </section>
  );
}

/// 会话详情（view-session-detail）：统计卡从列表行数据来，子代理明细走
/// subagentBreakdown（与总览页抽屉同一 IPC）。项目详情的会话表也复用本组件。
export function SessionDetail({ session, onBack }: { session: SessionItem; onBack: () => void }) {
  const [rows, setRows] = useState<SubagentRow[] | null>(null);

  useEffect(() => {
    let cancelled = false;
    void window.tokenMeter.overview.subagentBreakdown(session.id)
      .then((result) => { if (!cancelled) setRows(result); })
      .catch(() => { if (!cancelled) setRows([]); });
    return () => { cancelled = true; };
  }, [session.id]);

  const unknownNote = formatUnknownCostNote(session.costUnknownEvents);
  const durationMs = Math.max(0, session.lastEventEpochMs - session.firstEventEpochMs);

  // 子代理模型分布（按任务数）与花费 Top5，都从明细行在前端聚合。
  const modelDist = useMemo(() => {
    if (!rows) return [];
    const byModel = new Map<string, number>();
    for (const r of rows) byModel.set(r.model ?? '未知模型', (byModel.get(r.model ?? '未知模型') ?? 0) + 1);
    return [...byModel.entries()].sort((a, b) => b[1] - a[1]);
  }, [rows]);
  const topByCost = useMemo(
    () => (rows ? [...rows].filter((r) => r.costUsdMicros > 0).sort((a, b) => b.costUsdMicros - a.costUsdMicros).slice(0, 5) : []),
    [rows]
  );
  const maxDistCount = Math.max(1, ...modelDist.map(([, n]) => n));

  return (
    <section className="view">
      <div className="vhead">
        <button className="backbtn" type="button" onClick={onBack}>← 返回</button>
        <h1>{session.title ?? session.sessionKey.slice(0, 18)}</h1>
        <span className="sub">
          {session.projectDisplayName ?? '未归属项目'}
          {session.title ? ` · ${session.sessionKey.slice(0, 16)}` : ''}
        </span>
      </div>

      <div className="stats">
        <div className="stat">
          <div className="lb">Token</div>
          <div className="v num">{formatTokens(session.tokensTotal)}</div>
          <div className="sb">{session.modelName ?? '—'}</div>
        </div>
        <div className="stat" data-kind={unknownNote ? 'unknown' : undefined}>
          <div className="lb">成本</div>
          <div className="v num">{formatUsdMicros(session.costUsdMicros)}</div>
          <div className="sb">{unknownNote ? `部分价格未知（${unknownNote}）` : '含子代理合计'}</div>
        </div>
        <div className="stat">
          <div className="lb">事件</div>
          <div className="v num">{formatCount(session.eventsCount)}</div>
          <div className="sb">{session.subagentCount > 0 ? `${session.subagentCount} 个子代理（明细见下）` : '主会话用量事件'}</div>
        </div>
        <div className="stat">
          <div className="lb">时长</div>
          <div className="v num">{formatDurationShort(durationMs)}</div>
          <div className="sb">开始于 {formatShortDateTime(session.firstEventEpochMs)}</div>
        </div>
      </div>

      <div className="detail-grid">
        <div className="card">
          <div className="chead"><div><h2>子代理模型分布</h2><div className="desc">按任务数计</div></div></div>
          {modelDist.length === 0 ? <p className="muted">没有子代理任务。</p> : (
            <div>
              {modelDist.map(([model, count]) => (
                <div className="mbar dist-row" key={model}>
                  <span className="mname dist-name" title={model}>{model}</span>
                  <div className="bar"><i style={{ width: `${Math.round((count / maxDistCount) * 100)}%` }} /></div>
                  <span className="num">{count}</span>
                </div>
              ))}
            </div>
          )}
        </div>
        <div className="card">
          <div className="chead"><div><h2>花费 Top 5 子代理</h2><div className="desc">价格未知的子代理不计入排名</div></div></div>
          {topByCost.length === 0 ? <p className="muted">没有可排名的子代理。</p> : (
            <div>
              {topByCost.map((r, i) => (
                <div className="mbar dist-row" key={`${r.label}-${i}`}>
                  <span className="mname dist-name" title={r.label}>{i + 1}. {r.label}</span>
                  <div className="bar"><i style={{ width: `${Math.round((r.costUsdMicros / topByCost[0].costUsdMicros) * 100)}%` }} /></div>
                  <span className="num">{formatUsdMicros(r.costUsdMicros)}</span>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>

      <div className="card sess-agents-card">
        <div className="chead">
          <div>
            <h2>子代理任务</h2>
            <div className="desc">{rows ? `${rows.length} 条` : ''}</div>
          </div>
        </div>
        {rows !== null && rows.length === 0 ? <p className="muted">该会话没有子代理任务。</p> : null}
        {rows && rows.length > 0 ? (
          <div className="hscroll">
            <table className="sess-table">
              <thead>
                <tr>
                  <th>名称</th><th>模型</th>
                  <th className="r">Token</th><th className="r">成本</th>
                  <th className="r">开始</th><th className="r">时长</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r, i) => (
                  <tr key={i}>
                    <td><span className="mname" title={r.label}>{r.label}</span></td>
                    <td><span className="t2">{r.model ?? '—'}</span></td>
                    <td className="r num">{formatTokens(r.tokens)}</td>
                    <td className="r num">{formatUsdMicros(r.costUsdMicros)}</td>
                    <td className="r num">{formatShortDateTime(r.lastEventMs - r.durationMs)}</td>
                    <td className="r num">{formatDurationShort(r.durationMs)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : null}
      </div>
    </section>
  );
}
