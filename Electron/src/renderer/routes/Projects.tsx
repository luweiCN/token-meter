import { useCallback, useEffect, useMemo, useState } from 'react';

import type { ProjectCard, ProjectDetail, SessionItem, SessionsFilter } from '../api.js';
import { chartAnimationDelay } from '../charts/chartMotion.js';
import { Pager, Select } from '../components/ui.js';
import { formatTokens, formatUnknownCostNote, formatUsdMicros } from '../format.js';
import { SessionCell, SessionDetail } from './Sessions.js';

/// 项目页（OpenDesign 稿 view-projects / view-project-detail）：
/// 卡片网格（名称 / 路径 / 近 14 天花费 spark 线 / 会话·token·花费）+ 排序与名称搜索，
/// 点卡进详情（统计卡 + 14 天花费柱 + 模型/Agent 分布 + 全量会话表分页）。
export function Projects() {
  const [selected, setSelected] = useState<ProjectCard | null>(null);
  if (selected) {
    return <ProjectDetailView card={selected} onBack={() => setSelected(null)} />;
  }
  return <ProjectGrid onOpen={setSelected} />;
}

type ProjectSortKey = 'cost' | 'tokens' | 'sessions' | 'recent' | 'name';

const PROJECT_SORTS: Array<{ value: ProjectSortKey; label: string }> = [
  { value: 'cost', label: '按累计花费' },
  { value: 'tokens', label: '按 Token' },
  { value: 'sessions', label: '按会话数' },
  { value: 'recent', label: '按最近活跃' },
  { value: 'name', label: '按名称' }
];

function ProjectGrid({ onOpen }: { onOpen: (card: ProjectCard) => void }) {
  const [cards, setCards] = useState<ProjectCard[] | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [sortKey, setSortKey] = useState<ProjectSortKey>('cost');
  const [search, setSearch] = useState('');

  useEffect(() => {
    void window.tokenMeter.projects.list()
      .then(setCards)
      .catch((error: unknown) => setLoadError(error instanceof Error ? error.message : '项目列表加载失败'));
  }, []);

  // 项目量级只有百级，排序/搜索在前端做，不打 IPC。
  const shown = useMemo(() => {
    const needle = search.trim().toLowerCase();
    const kept = needle
      ? (cards ?? []).filter((c) => c.displayName.toLowerCase().includes(needle) || c.pathLabel.toLowerCase().includes(needle))
      : (cards ?? []);
    const sorted = [...kept];
    switch (sortKey) {
      case 'tokens': sorted.sort((a, b) => b.tokensTotal - a.tokensTotal); break;
      case 'sessions': sorted.sort((a, b) => b.sessionsCount - a.sessionsCount); break;
      case 'recent': sorted.sort((a, b) => (b.lastActiveDate ?? '').localeCompare(a.lastActiveDate ?? '')); break;
      case 'name': sorted.sort((a, b) => a.displayName.localeCompare(b.displayName)); break;
      default: sorted.sort((a, b) => b.costUsdMicros - a.costUsdMicros);
    }
    return sorted;
  }, [cards, search, sortKey]);

  const sortLabel = PROJECT_SORTS.find((s) => s.value === sortKey)?.label ?? '';

  return (
    <section className="view">
      <div className="vhead">
        <h1>项目</h1>
        {cards ? <span className="sub">{shown.length} 个项目 · {sortLabel}排序</span> : null}
        <div className="spacer" />
      </div>

      <div className="card sess-filter-card">
        <div className="sess-filter">
          <Select
            ariaLabel="项目排序"
            value={sortKey}
            placeholder={null}
            options={PROJECT_SORTS}
            onChange={(next) => { if (next !== null) setSortKey(next); }}
          />
          <div className="grow" />
          <div className="field">
            <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
              <circle cx="5" cy="5" r="3.6" stroke="var(--muted)" strokeWidth="1.4" />
              <path d="m8 8 2.6 2.6" stroke="var(--muted)" strokeWidth="1.4" strokeLinecap="round" />
            </svg>
            <input
              type="search"
              placeholder="搜索项目名称 / 路径"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
            />
          </div>
        </div>
      </div>

      {loadError ? <p className="status-error" role="status">项目列表加载失败：{loadError}</p> : null}
      {cards === null && !loadError ? <p className="muted" role="status">正在加载项目…</p> : null}
      {cards !== null && shown.length === 0 ? <p className="muted">没有匹配的项目。</p> : null}
      <div className="proj-grid">
        {shown.map((card) => {
          const unknownNote = formatUnknownCostNote(card.costUnknownEvents);
          return (
            <button type="button" className="pcard" key={card.id} onClick={() => onOpen(card)}>
              <div className="pc-nm">{card.displayName}</div>
              <div className="pc-path" title={card.pathLabel}>{card.pathLabel}</div>
              <Sparkline values={card.spark} />
              <div className="pc-foot">
                <span className="num">{card.sessionsCount.toLocaleString()} 会话</span>
                <span className="num">{formatTokens(card.tokensTotal)}</span>
                <span className="num" title={unknownNote ? `部分事件价格未知（${unknownNote}）` : undefined}>
                  {formatUsdMicros(card.costUsdMicros)}{unknownNote ? '†' : ''}
                </span>
              </div>
            </button>
          );
        })}
      </div>
    </section>
  );
}

/// 近 14 天花费的迷你面积折线（设计稿 .pc-spark）。数据量固定 14 点，纯 SVG。
function Sparkline({ values }: { values: number[] }) {
  const W = 200;
  const H = 40;
  const max = Math.max(1, ...values);
  const step = values.length > 1 ? W / (values.length - 1) : W;
  const points = values.map((v, i) => `${(i * step).toFixed(1)},${(H - 3 - (v / max) * (H - 8)).toFixed(1)}`);
  return (
    <svg className="pc-spark chart-surface-in" viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" aria-label="近 14 天花费">
      <polygon points={`0,${H} ${points.join(' ')} ${W},${H}`} fill="var(--accent)" opacity="0.12" />
      <polyline points={points.join(' ')} fill="none" stroke="var(--accent)" strokeWidth="1.5" />
    </svg>
  );
}

const SESSION_PAGE_SIZE = 20;

function ProjectDetailView({ card, onBack }: { card: ProjectCard; onBack: () => void }) {
  const [detail, setDetail] = useState<ProjectDetail | null>(null);
  // 会话表点行下钻到会话详情（与会话页同一组件），返回键回到本项目。
  const [session, setSession] = useState<SessionItem | null>(null);

  useEffect(() => {
    let cancelled = false;
    void window.tokenMeter.projects.detail(card.id)
      .then((d) => { if (!cancelled && d) setDetail(d); })
      .catch(() => {});
    return () => { cancelled = true; };
  }, [card.id]);

  const unknownNote = formatUnknownCostNote(detail?.costUnknownEvents ?? card.costUnknownEvents);
  const maxDaily = Math.max(1, ...(detail?.dailyCost ?? []).map((d) => d.costUsdMicros));
  const maxModelTokens = Math.max(1, ...(detail?.models ?? []).map((m) => m.tokens));
  const maxAgentTokens = Math.max(1, ...(detail?.agents ?? []).map((a) => a.tokens));

  if (session) {
    return <SessionDetail session={session} onBack={() => setSession(null)} />;
  }

  return (
    <section className="view">
      <div className="vhead">
        <button className="backbtn" type="button" onClick={onBack}>← 项目</button>
        <h1>{card.displayName}</h1>
        <span className="sub num">{card.pathLabel}</span>
      </div>

      <div className="stats">
        <div className="stat">
          <div className="lb">会话总数</div>
          <div className="v num">{(detail?.sessionsCount ?? card.sessionsCount).toLocaleString()}</div>
          <div className="sb">全部历史 · 仅主会话</div>
        </div>
        <div className="stat" data-kind={unknownNote ? 'unknown' : undefined}>
          <div className="lb">累计成本</div>
          <div className="v num">{formatUsdMicros(detail?.costUsdMicros ?? card.costUsdMicros)}</div>
          <div className="sb">{unknownNote ? `部分价格未知（${unknownNote}）` : '全部历史'}</div>
        </div>
        <div className="stat">
          <div className="lb">Token</div>
          <div className="v num">{formatTokens(detail?.tokensTotal ?? card.tokensTotal)}</div>
          <div className="sb">全部历史</div>
        </div>
        <div className="stat">
          <div className="lb">活跃天数</div>
          <div className="v num">{(detail?.activeDays ?? 0).toLocaleString()}</div>
          <div className="sb">
            {detail?.lastActiveDate ? `最近活跃 ${detail.lastActiveDate}` : '—'}
          </div>
        </div>
      </div>

      <div className="card proj-spend-card">
        <div className="chead"><div><h2>近 14 天花费</h2><div className="desc">USD · 不含价格未知事件</div></div></div>
        <div className="proj-days">
          {(detail?.dailyCost ?? []).map((d, index) => (
            <div className="proj-day" key={d.date} title={`${d.date} · ${formatUsdMicros(d.costUsdMicros)}`}>
              <div className="proj-day-bar">
                <i
                  className="chart-bar-y-in"
                  style={{
                    height: `${Math.round((d.costUsdMicros / maxDaily) * 100)}%`,
                    animationDelay: chartAnimationDelay(index)
                  }}
                />
              </div>
              <span className="proj-day-lb num">{Number(d.date.slice(8, 10))}</span>
            </div>
          ))}
        </div>
      </div>

      <div className="detail-grid">
        <div className="card">
          <div className="chead"><div><h2>模型分布</h2><div className="desc">按 token 计 · Top 8</div></div></div>
          {(detail?.models ?? []).length === 0 ? <p className="muted">暂无数据。</p> : (
            <div>
              {detail!.models.map((m, index) => (
                <div className="mbar dist-row" key={m.model}>
                  <span className="mname dist-name" title={m.model}>{m.model}</span>
                  <div className="bar">
                    <i
                      className="chart-bar-x-in"
                      style={{
                        width: `${Math.round((m.tokens / maxModelTokens) * 100)}%`,
                        animationDelay: chartAnimationDelay(index)
                      }}
                    />
                  </div>
                  <span className="num">{formatTokens(m.tokens)}</span>
                </div>
              ))}
            </div>
          )}
        </div>
        <div className="card">
          <div className="chead"><div><h2>Coding Agent 分布</h2><div className="desc">按 token 计</div></div></div>
          {(detail?.agents ?? []).length === 0 ? <p className="muted">暂无数据。</p> : (
            <div>
              {detail!.agents.map((a, index) => (
                <div className="mbar dist-row" key={a.providerId}>
                  <span className="mname dist-name">{a.providerId}</span>
                  <div className="bar">
                    <i
                      className="chart-bar-x-in"
                      style={{
                        width: `${Math.round((a.tokens / maxAgentTokens) * 100)}%`,
                        animationDelay: chartAnimationDelay(index)
                      }}
                    />
                  </div>
                  <span className="num">{formatTokens(a.tokens)}</span>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>

      <ProjectSessions projectId={card.id} onOpen={setSession} />
    </section>
  );
}

/// 项目详情的会话表：全量 + 分页 + Token/成本/开始 排序（服务端分页，与会话页
/// 同一查询）。点行打开会话详情——与会话页同一交互，不放多余按钮。
function ProjectSessions({ projectId, onOpen }: { projectId: number; onOpen: (session: SessionItem) => void }) {
  const [page, setPage] = useState(1);
  const [sortBy, setSortBy] = useState<NonNullable<SessionsFilter['sortBy']>>('start');
  const [sortDir, setSortDir] = useState<'asc' | 'desc'>('desc');
  const [items, setItems] = useState<SessionItem[]>([]);
  const [total, setTotal] = useState(0);

  const load = useCallback(async () => {
    try {
      const result = await window.tokenMeter.sessions.query({
        projectIds: [projectId],
        limit: SESSION_PAGE_SIZE,
        offset: (page - 1) * SESSION_PAGE_SIZE,
        sortBy,
        sortDir
      });
      setItems(result.items);
      setTotal(result.total);
    } catch {
      /* 加载失败时保留上一页数据 */
    }
  }, [projectId, page, sortBy, sortDir]);

  useEffect(() => {
    void load();
  }, [load]);

  useEffect(() => {
    setPage(1);
  }, [sortBy, sortDir]);

  const onSort = (key: NonNullable<SessionsFilter['sortBy']>) => {
    if (key === sortBy) {
      setSortDir((d) => (d === 'asc' ? 'desc' : 'asc'));
    } else {
      setSortBy(key);
      setSortDir('desc');
    }
  };
  const sortClass = (key: NonNullable<SessionsFilter['sortBy']>) => `r sort${sortBy === key ? ` ${sortDir}` : ''}`;
  const pageCount = Math.max(1, Math.ceil(total / SESSION_PAGE_SIZE));

  return (
    <div className="card sess-agents-card">
      <div className="chead"><div><h2>会话</h2><div className="desc">{total.toLocaleString()} 条</div></div></div>
      {items.length === 0 ? <p className="muted">该项目还没有会话。</p> : (
        <div className="hscroll">
          <table className="sess-table">
            <thead>
              <tr>
                <th>会话</th><th>模型</th>
                <th className={sortClass('tokens')} onClick={() => onSort('tokens')}>Token</th>
                <th className={sortClass('cost')} onClick={() => onSort('cost')}>成本</th>
                <th className={sortClass('start')} onClick={() => onSort('start')}>开始</th>
                <th className="r">子代理</th>
              </tr>
            </thead>
            <tbody>
              {items.map((s) => (
                <tr key={`${s.sourceKind}:${s.sessionKey}`} className="sess-row" onClick={() => onOpen(s)}>
                  <td><SessionCell session={s} /></td>
                  <td><span className="mname">{s.modelName ?? '—'}</span></td>
                  <td className="r num">{formatTokens(s.tokensTotal)}</td>
                  <td className="r num">{formatUsdMicros(s.costUsdMicros)}</td>
                  <td className="r num">{new Date(s.firstEventEpochMs).toLocaleDateString()}</td>
                  <td className="r num">{s.subagentCount}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <Pager page={page} pageCount={pageCount} onPage={setPage} />
    </div>
  );
}
