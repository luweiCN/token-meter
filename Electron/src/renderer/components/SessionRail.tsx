import { useMemo, useState } from 'react';

import type { ActivityRow, SubagentRow } from '../api.js';
import { formatDuration, formatRelative, formatTokens, formatUnknownCostNote, formatUsdMicros } from '../format.js';

/// 右侧会话列表（spec §7.2）：进行中的（5 分钟内消耗过 token）置顶并打脉冲点，
/// 下方是最近结束的若干条。数据已由 repository 的 sessionRail 排好序 + 子代理归并。
///
/// 卡片按信息层次排：标题（项目名 + 状态）→ 用过的模型（tag）→ 用量数字（token 为主，
/// 成本/时长次要）→ 子代理徽标。token/成本是【含子代理的合计】故标「总」；模型 tag 是
/// 【主会话自己用过的】（不含子代理），两个层级放一起才不会被误读成「这个模型用了这么多」。
///
/// 「进行中」不等于「正在运行」——没有可靠的非侵入判据（spec §7.2.1），这里只陈述
/// 磁盘上的事实：这个会话（含其子代理）在 5 分钟内消耗过 token。
export function SessionRail({ sessions, now }: { sessions: ActivityRow[]; now: number }) {
  const [open, setOpen] = useState<{ projectName: string; rows: SubagentRow[] } | null>(null);

  const openBreakdown = async (session: ActivityRow) => {
    const rows = await window.tokenMeter.overview.subagentBreakdown(session.sessionId);
    setOpen({ projectName: session.projectName, rows });
  };

  if (sessions.length === 0) {
    return <p className="muted">最近没有会话活动。</p>;
  }
  return (
    <>
      <ul className="session-rail__list">
        {sessions.map(s => {
          const unknownNote = formatUnknownCostNote(s.costUnknownEvents);
          return (
            <li key={s.sessionId} className={`session-rail__item${s.isLive ? ' is-live' : ''}`}>
              <div className="session-rail__head">
                {s.isLive ? <span className="session-rail__pulse" aria-hidden="true" /> : null}
                <strong className="session-rail__project" title={s.projectName}>{s.projectName}</strong>
                <span className="session-rail__provider">{s.providerId}</span>
                <span className={`session-rail__status${s.isLive ? ' is-live' : ''}`}>
                  {s.isLive ? '进行中' : formatRelative(s.msSinceLastEvent)}
                </span>
              </div>

              {s.models.length > 0 ? (
                <div className="session-rail__models" aria-label="主会话用过的模型">
                  {s.models.map(m => <span key={m} className="session-rail__model-tag">{m}</span>)}
                </div>
              ) : null}

              <div className="session-rail__stats">
                <strong className="session-rail__tokens">总 {formatTokens(s.tokensTotal)} tokens</strong>
                <span className="session-rail__stat">
                  {formatUsdMicros(s.costUsdMicros)}
                  {unknownNote ? (
                    <span className="cost-unknown" title="部分事件价格未知，成本可能偏低">（{unknownNote}）</span>
                  ) : null}
                </span>
                <span className="session-rail__stat">{formatDuration(Math.max(0, now - s.firstEventEpochMs))}</span>
              </div>

              {s.subagentCount > 0 ? (
                <button
                  type="button"
                  className="session-rail__subagents"
                  aria-label={`${s.subagentCount} 个子代理，点开看明细`}
                  onClick={() => void openBreakdown(s)}
                >
                  {s.subagentCount} 个子代理
                </button>
              ) : null}
            </li>
          );
        })}
      </ul>

      {open ? (
        <SubagentModal projectName={open.projectName} rows={open.rows} now={now} onClose={() => setOpen(null)} />
      ) : null}
    </>
  );
}

type SortKey = 'tokens' | 'cost' | 'time' | 'label';
type SortDir = 'asc' | 'desc';

const SORTS: Array<{ key: SortKey; label: string }> = [
  { key: 'tokens', label: 'Token' },
  { key: 'cost', label: '成本' },
  { key: 'time', label: '时间' },
  { key: 'label', label: '名称' }
];

/// 每个字段的「顺手」默认方向：量与时间是从大/新看起（降序），名称是字母序（升序）。
const DEFAULT_DIR: Record<SortKey, SortDir> = { tokens: 'desc', cost: 'desc', time: 'desc', label: 'asc' };

/// 子代理下钻弹窗：子代理动辄几十上百个，故用居中 modal + 滚动，并带名称筛选与排序。
/// 排序区与筛选框在视觉上分开，靠激活态高亮和方向箭头表明当前排序键与方向，避免被误认成又一个筛选。
function SubagentModal({
  projectName, rows, now, onClose
}: { projectName: string; rows: SubagentRow[]; now: number; onClose: () => void }) {
  const [sortBy, setSortBy] = useState<SortKey>('tokens');
  const [sortDir, setSortDir] = useState<SortDir>('desc');
  const [filter, setFilter] = useState('');

  const onSort = (key: SortKey) => {
    if (key === sortBy) {
      setSortDir(d => (d === 'asc' ? 'desc' : 'asc'));
    } else {
      setSortBy(key);
      setSortDir(DEFAULT_DIR[key]);
    }
  };

  const shown = useMemo(() => {
    const needle = filter.trim().toLowerCase();
    const kept = needle ? rows.filter(r => r.label.toLowerCase().includes(needle)) : rows;
    const sign = sortDir === 'asc' ? 1 : -1;
    return [...kept].sort((a, b) => {
      let v: number;
      switch (sortBy) {
        case 'label': v = a.label.localeCompare(b.label); break;
        case 'time': v = a.lastEventMs - b.lastEventMs; break;
        case 'cost': v = a.costUsdMicros - b.costUsdMicros; break;
        default: v = a.tokens - b.tokens;
      }
      return sign * v;
    });
  }, [rows, filter, sortBy, sortDir]);

  return (
    <div className="subagent-modal__overlay" role="dialog" aria-modal="true" aria-label="子代理明细" onClick={onClose}>
      <div className="subagent-modal" onClick={e => e.stopPropagation()}>
        <div className="subagent-modal__head">
          <h3 className="subagent-modal__title">{projectName} · {rows.length} 个子代理</h3>
          <button type="button" className="subagent-modal__close" aria-label="关闭" onClick={onClose}>×</button>
        </div>
        <div className="subagent-modal__toolbar">
          <input
            className="subagent-modal__filter"
            placeholder="按名称筛选"
            value={filter}
            onChange={e => setFilter(e.target.value)}
          />
          <div className="subagent-modal__sort" role="group" aria-label="排序">
            {SORTS.map(s => (
              <button
                key={s.key}
                type="button"
                className={`subagent-modal__sort-btn${sortBy === s.key ? ' is-active' : ''}`}
                aria-pressed={sortBy === s.key}
                onClick={() => onSort(s.key)}
              >
                {s.label}
                {sortBy === s.key ? <span className="subagent-modal__sort-dir" aria-hidden="true">{sortDir === 'desc' ? '↓' : '↑'}</span> : null}
              </button>
            ))}
          </div>
        </div>
        <div className="subagent-modal__list">
          {shown.length === 0 ? (
            <p className="muted subagent-modal__empty">没有匹配的子代理。</p>
          ) : (
            shown.map((r, i) => (
              <div key={i} className="subagent-modal__row">
                <span className="subagent-modal__idx">{i + 1}</span>
                <span className="subagent-modal__label" title={r.label}>{r.label}</span>
                <span className="subagent-modal__time">{formatRelative(now - r.lastEventMs)}</span>
                <span className="subagent-modal__tokens">{formatTokens(r.tokens)} tokens</span>
                <span className="subagent-modal__cost">{formatUsdMicros(r.costUsdMicros)}</span>
              </div>
            ))
          )}
        </div>
      </div>
    </div>
  );
}
