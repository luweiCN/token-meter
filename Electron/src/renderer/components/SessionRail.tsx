import { useEffect, useMemo, useState } from 'react';

import type { ActivityRow, SubagentRow } from '../api.js';
import { formatDurationShort, formatRelative, formatTokens, formatUnknownCostNote, formatUsdMicros } from '../format.js';

/// 实时会话卡（OpenDesign 稿 8b）四态：
///   blocked —— hooks 上报「agent 停下来等用户」（权限确认 / 提问，琥珀色脉冲点）
///   running —— 2 分钟内有新事件（repository 的 isLive，脉冲绿点）
///   idle    —— 2~15 分钟（「等待输入」，黄点）；15 分钟只是稿上 6m=idle/18m=done 的中点取整
///   done    —— 更久（「已结束」，灰点）
/// blocked 来自 hooks 事件流，其余三态只陈述磁盘事实（spec §7.2.1）。
const IDLE_WINDOW_MS = 15 * 60_000;

function cardState(s: ActivityRow): 'blocked' | 'running' | 'idle' | 'done' {
  if (s.isLive) return s.isBlocked ? 'blocked' : 'running';
  return s.msSinceLastEvent < IDLE_WINDOW_MS ? 'idle' : 'done';
}

const STATE_LABEL = { blocked: '阻塞', running: '运行中', idle: '等待输入', done: '已结束' } as const;

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
            // key 用源标识：新会话占位卡还没有库 id（sessionId=0），sessionId 会撞。
            <div key={`${s.sourceKind}:${s.sourceSessionKey}`} className="lcard" data-state={state}>
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
              <div className="lc-stats">
                <div>
                  <i>Token</i>
                  <b className="num">{formatTokens(s.tokensTotal)}</b>
                </div>
                <div title={unknownNote ? `部分事件价格未知，成本可能偏低（${unknownNote}）` : undefined}>
                  <i>花费</i>
                  <b className="num">{formatUsdMicros(s.costUsdMicros)}{unknownNote ? '†' : ''}</b>
                </div>
                <div>
                  <i>时长</i>
                  <b className="num">{formatDurationShort(Math.max(0, now - s.firstEventEpochMs))}</b>
                </div>
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

/// 子代理下钻抽屉（OpenDesign 稿）：右侧滑入，遮罩点击/×/Esc 关闭。
/// 子代理动辄几十上百个，抽屉内滚动，带名称筛选与排序。
/// 排序区与筛选框在视觉上分开，靠激活态高亮和方向箭头表明当前排序键与方向，避免被误认成又一个筛选。
function SubagentModal({
  projectName, rows, now, onClose
}: { projectName: string; rows: SubagentRow[]; now: number; onClose: () => void }) {
  const [sortBy, setSortBy] = useState<SortKey>('tokens');
  const [sortDir, setSortDir] = useState<SortDir>('desc');
  const [filter, setFilter] = useState('');
  const [entered, setEntered] = useState(false);

  // 挂载后下一帧加 .on 触发入场过渡；关闭先撤 .on 等出场动画再卸载。
  useEffect(() => {
    const frame = requestAnimationFrame(() => setEntered(true));
    return () => cancelAnimationFrame(frame);
  }, []);

  const close = () => {
    setEntered(false);
    window.setTimeout(onClose, 250);
  };

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') close();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const onSort = (key: SortKey) => {
    if (key === sortBy) {
      setSortDir(d => (d === 'asc' ? 'desc' : 'asc'));
    } else {
      setSortBy(key);
      setSortDir(DEFAULT_DIR[key]);
    }
  };

  // 横条基准取全量最大值（不随筛选变），筛掉行时其余行的条长不跳。
  const maxTokens = Math.max(1, ...rows.map(r => r.tokens));

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
    <>
      <div className={`drawer-mask${entered ? ' on' : ''}`} onClick={close} aria-hidden="true" />
      <div className={`drawer${entered ? ' on' : ''}`} role="dialog" aria-modal="true" aria-label="子代理明细">
        <header>
          <div className="ttl">{projectName}</div>
          <div className="meta">{rows.length} 个子代理</div>
          <button type="button" className="close" aria-label="关闭" onClick={close}>×</button>
        </header>
        <div className="tools">
          <div className="filter-box">
            <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor"
              strokeWidth="2.4" strokeLinecap="round" aria-hidden="true">
              <circle cx="11" cy="11" r="7" />
              <path d="m20 20-3.8-3.8" />
            </svg>
            <input
              placeholder="按名称筛选"
              value={filter}
              onChange={e => setFilter(e.target.value)}
            />
          </div>
          <div className="seg" role="group" aria-label="排序">
            {SORTS.map(s => (
              <button
                key={s.key}
                type="button"
                className={sortBy === s.key ? 'on' : ''}
                aria-pressed={sortBy === s.key}
                onClick={() => onSort(s.key)}
              >
                {s.label}
                {sortBy === s.key ? <span aria-hidden="true"> {sortDir === 'desc' ? '↓' : '↑'}</span> : null}
              </button>
            ))}
          </div>
        </div>
        <div className="body">
          {shown.length === 0 ? (
            <p className="muted subagent-modal__empty">没有匹配的子代理。</p>
          ) : (
            <table>
              <thead>
                <tr>
                  <th className="r">#</th>
                  <th>名称</th>
                  <th>Token</th>
                  <th className="r">成本</th>
                  <th className="r">时间</th>
                </tr>
              </thead>
              <tbody>
                {shown.map((r, i) => (
                  <tr key={i}>
                    <td className="r num">{i + 1}</td>
                    <td><span className="mname" title={r.label}>{r.label}</span></td>
                    <td>
                      <div className="mbar">
                        <div className="bar"><i style={{ width: `${Math.round((r.tokens / maxTokens) * 100)}%` }} /></div>
                        <span className="num">{formatTokens(r.tokens)}</span>
                      </div>
                    </td>
                    <td className="r num">{formatUsdMicros(r.costUsdMicros)}</td>
                    <td className="r num">{formatRelative(now - r.lastEventMs)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
      </div>
    </>
  );
}
