import { useState } from 'react';

import type { ActivityRow, SubagentRow } from '../api.js';
import { formatDuration, formatRelative, formatTokens, formatUnknownCostNote, formatUsdMicros } from '../format.js';

/// 右栏会话列表（spec §7.2）：进行中的（5 分钟内消耗过 token）置顶并打脉冲点，
/// 下方是最近结束的若干条。数据已由 repository 的 sessionRail 排好序（live 组置顶，
/// 组内按最近事件倒序）+ 子代理归并（token/成本/isLive 都是主会话含子代理的合计）。
///
/// 「进行中」不等于「正在运行」——没有可靠的非侵入判据（spec §7.2.1），这里只陈述
/// 磁盘上的事实：这个会话（含其子代理）在 5 分钟内消耗过 token。
///
/// 有子代理的主会话挂一个数量徽标，点开走 subagentBreakdown 拉明细、原地展开浮层。
export function SessionRail({ sessions, now }: { sessions: ActivityRow[]; now: number }) {
  const [open, setOpen] = useState<{ sessionId: number; rows: SubagentRow[] } | null>(null);

  const toggle = async (sessionId: number) => {
    if (open?.sessionId === sessionId) {
      setOpen(null);
      return;
    }
    const rows = await window.tokenMeter.overview.subagentBreakdown(sessionId);
    setOpen({ sessionId, rows });
  };

  if (sessions.length === 0) {
    return <p className="muted">最近没有会话活动。</p>;
  }
  return (
    <ul className="session-rail__list">
      {sessions.map(s => (
        <li key={s.sessionId} className={`session-rail__item${s.isLive ? ' is-live' : ''}`}>
          <div className="session-rail__head">
            {s.isLive ? <span className="session-rail__pulse" aria-label="进行中" /> : null}
            <strong className="session-rail__project">{s.projectName}</strong>
            <span className="session-rail__provider">{s.providerId}</span>
          </div>
          <div className="session-rail__meta">
            <span>{s.primaryModel ?? '未知模型'}</span>
            <span>{formatTokens(s.tokensTotal)} tokens</span>
          </div>
          <div className="session-rail__meta">
            <span>{s.isLive ? '进行中' : formatRelative(s.msSinceLastEvent)}</span>
            <span>时长 {formatDuration(Math.max(0, now - s.firstEventEpochMs))}</span>
          </div>
          <div className="session-rail__cost">
            <span>{formatUsdMicros(s.costUsdMicros)}</span>
            {formatUnknownCostNote(s.costUnknownEvents) ? (
              <span className="cost-unknown" title="部分事件价格未知，成本可能偏低">
                {formatUnknownCostNote(s.costUnknownEvents)}
              </span>
            ) : null}
          </div>
          {s.subagentCount > 0 ? (
            <button
              type="button"
              className={`session-rail__subagents${open?.sessionId === s.sessionId ? ' is-open' : ''}`}
              aria-label={`${s.subagentCount} 个子代理，点开看明细`}
              onClick={() => void toggle(s.sessionId)}
            >
              {s.subagentCount} 个子代理
            </button>
          ) : null}
          {open?.sessionId === s.sessionId ? (
            <div className="session-rail__breakdown" role="dialog" aria-label="子代理明细">
              {open.rows.map((r, i) => (
                <div key={i} className="session-rail__breakdown-row">
                  <span className="session-rail__breakdown-label">{r.label}</span>
                  <span>{formatTokens(r.tokens)} tokens</span>
                  <span>{formatUsdMicros(r.costUsdMicros)}</span>
                </div>
              ))}
            </div>
          ) : null}
        </li>
      ))}
    </ul>
  );
}
