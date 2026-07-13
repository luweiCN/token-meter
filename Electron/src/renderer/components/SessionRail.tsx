import { useMemo, useState } from 'react';

import type { ActivityRow, SubagentRow } from '../api.js';
import { formatDuration, formatRelative, formatTokens, formatUnknownCostNote, formatUsdMicros } from '../format.js';

/// 实时会话卡（OpenDesign 稿 8b）三态：
///   running —— 2 分钟内有新事件（repository 的 isLive，脉冲绿点）
///   idle    —— 2~15 分钟（「等待输入」，黄点）；15 分钟只是稿上 6m=idle/18m=done 的中点取整
///   done    —— 更久（「已结束」，灰点）
/// 三态都只陈述磁盘事实，不声称进程状态（spec §7.2.1）。
const IDLE_WINDOW_MS = 15 * 60_000;

function cardState(s: ActivityRow): 'running' | 'idle' | 'done' {
  if (s.isLive) return 'running';
  return s.msSinceLastEvent < IDLE_WINDOW_MS ? 'idle' : 'done';
}

const STATE_LABEL = { running: '运行中', idle: '等待输入', done: '已结束' } as const;

/// 实时会话网格：一张 lcard 一个主会话，token/成本是【含子代理的合计】。
/// 会话标题不展示——97% 的会话（Codex SDK 批量调用）源日志里就没有标题。
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
      <div className="live-grid">
        {sessions.map(s => {
          const state = cardState(s);
          const unknownNote = formatUnknownCostNote(s.costUnknownEvents);
          const model = s.models[0] ?? s.primaryModel;
          return (
            <div key={s.sessionId} className="lcard" data-state={state}>
              <div className="lc-top">
                <i className="dot" aria-hidden="true" />
                <span className="proj" title={s.projectName}>{s.projectName}</span>
                <span className="last">{s.isLive ? '刚刚' : formatRelative(s.msSinceLastEvent)}</span>
              </div>
              {model ? (
                <span className="lc-model" title={s.models.join('、') || model}>
                  {model}
                  {s.models.length > 1 ? ` +${s.models.length - 1}` : ''}
                </span>
              ) : null}
              <div className="lc-nums">
                <span className="num">{formatTokens(s.tokensTotal)}</span>
                <span
                  className="num"
                  title={unknownNote ? `部分事件价格未知，成本可能偏低（${unknownNote}）` : undefined}
                >
                  {formatUsdMicros(s.costUsdMicros)}{unknownNote ? '†' : ''}
                </span>
                <span className="num">{formatDuration(Math.max(0, now - s.firstEventEpochMs))}</span>
              </div>
              <div className="lc-foot">
                <span className="state">{STATE_LABEL[state]}</span>
                {s.subagentCount > 0 ? (
                  <button
                    type="button"
                    className="agbtn"
                    aria-label={`${s.subagentCount} 个子代理，点开看明细`}
                    onClick={() => void openBreakdown(s)}
                  >
                    {s.subagentCount} 子代理
                  </button>
                ) : null}
              </div>
            </div>
          );
        })}
      </div>

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
