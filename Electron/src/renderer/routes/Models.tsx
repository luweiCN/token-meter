import { useCallback, useEffect, useMemo, useState } from 'react';

import type { ModelsFilter, ModelUsageItem } from '../api.js';
import { DateTimeRangePicker, type DateTimeRangeValue } from '../components/ui.js';
import { formatCount, formatTokens, formatUnknownCostNote, formatUsdMicros } from '../format.js';

type SortKey = NonNullable<ModelsFilter['sortBy']>;

/// "7/14 09:32"(本地时区)。
function formatShortDateTime(epochMs: number): string {
  const d = new Date(epochMs);
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${d.getMonth() + 1}/${d.getDate()} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

/// agent 显示名(与趋势图图例同一命名)。
const AGENT_LABEL: Record<string, string> = {
  'claude-code': 'Claude Code',
  codex: 'Codex CLI',
  omp: 'OMP',
  opencode: 'OpenCode'
};

/// 份额条分段色:系列色 s1-s4 打头(与全应用图表一致),补两色,「其他」灰。
const SHARE_COLORS = ['var(--s1)', 'var(--s2)', 'var(--s3)', 'var(--s4)', '#ff8fa3', '#ffb26b'];

/// 模型份额堆叠条(GitHub 语言条式样):Top6 模型 + 其他,一眼看出
/// 筛选范围内谁吃掉了额度——反推套餐容量场景的主视觉。
function ModelShareBar({ items, totalTokens }: { items: ModelUsageItem[]; totalTokens: number }) {
  if (totalTokens <= 0 || items.length === 0) return null;
  const byTokens = [...items].sort((a, b) => b.tokensTotal - a.tokensTotal);
  const top = byTokens.slice(0, 6);
  const otherTokens = totalTokens - top.reduce((sum, item) => sum + item.tokensTotal, 0);
  const segments = [
    ...top.map((item, index) => ({ label: item.model, tokens: item.tokensTotal, color: SHARE_COLORS[index] })),
    ...(otherTokens > 0 ? [{ label: '其他', tokens: otherTokens, color: 'var(--muted)' }] : [])
  ];
  return (
    <div className="card mshare-card">
      <div className="mshare-bar" role="img" aria-label="模型 token 份额">
        {segments.map((seg) => (
          <i key={seg.label} style={{ width: `${(seg.tokens / totalTokens) * 100}%`, background: seg.color }} />
        ))}
      </div>
      <div className="mshare-legend">
        {segments.map((seg) => (
          <span className="it" key={seg.label}>
            <i style={{ background: seg.color }} />
            <span className="mname">{seg.label}</span>
            <b className="num">{((seg.tokens / totalTokens) * 100).toFixed(1)}%</b>
          </span>
        ))}
      </div>
    </div>
  );
}

/// 模型维度统计(项目/会话之外的第三面板):按 model_canonical 聚合,
/// 时间筛选是分钟精度——「额度刷新时刻 → 周期结束」的用量统计场景,
/// 顶部合计可用于反推套餐容量(用量 ÷ 额度消耗百分比)。
export function Models() {
  const [range, setRange] = useState<DateTimeRangeValue>({});
  const [search, setSearch] = useState('');
  const [debouncedSearch, setDebouncedSearch] = useState('');
  const [sortBy, setSortBy] = useState<SortKey>('tokens');
  const [sortDir, setSortDir] = useState<'asc' | 'desc'>('desc');
  const [items, setItems] = useState<ModelUsageItem[]>([]);
  const [loadError, setLoadError] = useState<string | null>(null);

  useEffect(() => {
    const timer = window.setTimeout(() => setDebouncedSearch(search), 300);
    return () => window.clearTimeout(timer);
  }, [search]);

  const load = useCallback(async () => {
    try {
      const filter: ModelsFilter = {
        sortBy,
        sortDir,
        ...(range.from === undefined ? {} : { fromEpochMs: range.from.getTime() }),
        ...(range.to === undefined ? {} : { toEpochMs: range.to.getTime() }),
        ...(debouncedSearch.trim() === '' ? {} : { search: debouncedSearch.trim() })
      };
      const result = await window.tokenMeter.models.query(filter);
      setItems(result.items);
      setLoadError(null);
    } catch (unknownError: unknown) {
      setLoadError(unknownError instanceof Error ? unknownError.message : '模型统计加载失败');
    }
  }, [range, debouncedSearch, sortBy, sortDir]);

  useEffect(() => {
    void load();
  }, [load]);

  // 事件驱动刷新:扫描完成(data.changed → dashboard:invalidate)后重取。
  useEffect(() => window.tokenMeter.overview.onInvalidate(() => void load()), [load]);

  const totals = useMemo(
    () =>
      items.reduce(
        (acc, item) => ({
          tokens: acc.tokens + item.tokensTotal,
          cost: acc.cost + item.costUsdMicros,
          events: acc.events + item.eventsCount
        }),
        { tokens: 0, cost: 0, events: 0 }
      ),
    [items]
  );

  const onSort = (key: SortKey) => {
    if (key === sortBy) {
      setSortDir((d) => (d === 'asc' ? 'desc' : 'asc'));
    } else {
      setSortBy(key);
      setSortDir('desc');
    }
  };

  const sortClass = (key: SortKey) => `r sort${sortBy === key ? ` ${sortDir}` : ''}`;
  const filtered = range.from !== undefined || range.to !== undefined;
  const maxTokens = useMemo(() => items.reduce((max, it) => Math.max(max, it.tokensTotal), 0), [items]);

  return (
    <section className="view">
      <div className="vhead">
        <h1>模型</h1>
        <span className="sub">
          <b className="num">{items.length}</b> 个模型 ·{' '}
          <b className="num">{formatTokens(totals.tokens)}</b> tokens ·{' '}
          <b className="num">{formatUsdMicros(totals.cost)}</b>
          {filtered ? ' · 筛选范围内' : ''}
        </span>
        <div className="spacer" />
      </div>

      <div className="card sess-filter-card">
        <div className="sess-filter">
          <DateTimeRangePicker ariaLabel="按时间范围筛选(精确到分钟)" value={range} onChange={setRange} />
          <div className="grow" />
          <div className="field">
            <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
              <circle cx="5" cy="5" r="3.6" stroke="var(--muted)" strokeWidth="1.4" />
              <path d="m8 8 2.6 2.6" stroke="var(--muted)" strokeWidth="1.4" strokeLinecap="round" />
            </svg>
            <input
              type="search"
              placeholder="搜索模型名"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
            />
          </div>
        </div>
      </div>

      {loadError ? <p className="status-error" role="status">模型统计加载失败：{loadError}</p> : null}

      <ModelShareBar items={items} totalTokens={totals.tokens} />

      <div className="card sess-table-card">
        <div className="hscroll">
          <table className="sess-table">
            <thead>
              <tr>
                <th>模型</th>
                <th>Agent</th>
                <th className={sortClass('tokens')} onClick={() => onSort('tokens')}>Token</th>
                <th className={sortClass('cost')} onClick={() => onSort('cost')}>成本</th>
                <th className="r">会话</th>
                <th className={`${sortClass('events')} hide-sm`} onClick={() => onSort('events')}>事件</th>
                <th className={sortClass('lastUsed')} onClick={() => onSort('lastUsed')}>最近使用</th>
              </tr>
            </thead>
            <tbody>
              {items.map((item) => {
                const unknownNote = formatUnknownCostNote(item.costUnknownEvents);
                return (
                  <tr key={item.model}>
                    <td><span className="mname">{item.model}</span></td>
                    <td>
                      <span className="t2">
                        {item.agents.map((agent) => AGENT_LABEL[agent] ?? agent).join(' · ')}
                      </span>
                    </td>
                    <td className="r num">
                      <span className="rowbar">
                        <span>{formatTokens(item.tokensTotal)}</span>
                        <i style={{ width: `${maxTokens > 0 ? (item.tokensTotal / maxTokens) * 100 : 0}%` }} />
                      </span>
                    </td>
                    <td className="r num" title={unknownNote ? `部分事件价格未知（${unknownNote}）` : undefined}>
                      {formatUsdMicros(item.costUsdMicros)}{unknownNote ? '†' : ''}
                    </td>
                    <td className="r num">{formatCount(item.sessionsCount)}</td>
                    <td className="r num hide-sm">{formatCount(item.eventsCount)}</td>
                    <td className="r num">{formatShortDateTime(item.lastUsedEpochMs)}</td>
                  </tr>
                );
              })}
              {items.length === 0 && !loadError ? (
                <tr><td colSpan={7} className="muted sess-empty">该时间范围内没有模型用量。</td></tr>
              ) : null}
            </tbody>
          </table>
        </div>
      </div>
    </section>
  );
}
