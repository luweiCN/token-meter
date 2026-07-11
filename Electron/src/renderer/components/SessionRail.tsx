import { useState } from 'react';

import type { ActivityRow, SubagentRow } from '../api.js';
import { formatDuration, formatRelative, formatTokens, formatUnknownCostNote, formatUsdMicros } from '../format.js';

/// 右栏会话列表（spec §7.2）：进行中的（5 分钟内消耗过 token）置顶并打脉冲点，
/// 下方是最近结束的若干条。数据已由 repository 的 sessionRail 排好序 + 子代理归并
/// （token/成本/isLive 都是主会话含子代理的合计，subagentCount 含独立子会话与 Claude sidechain）。
///
/// 「进行中」不等于「正在运行」——没有可靠的非侵入判据（spec §7.2.1），这里只陈述
/// 磁盘上的事实：这个会话（含其子代理）在 5 分钟内消耗过 token。
///
/// 有子代理的主会话挂一个数量徽标；点开走 subagentBreakdown 拉明细，弹一个居中 modal
/// （子代理动辄几十上百个，内联展开会把整条列表撑爆，故用带滚动的独立弹窗）。
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
                className="session-rail__subagents"
                aria-label={`${s.subagentCount} 个子代理，点开看明细`}
                onClick={() => void openBreakdown(s)}
              >
                {s.subagentCount} 个子代理
              </button>
            ) : null}
          </li>
        ))}
      </ul>

      {open ? (
        <div
          className="subagent-modal__overlay"
          role="dialog"
          aria-modal="true"
          aria-label="子代理明细"
          onClick={() => setOpen(null)}
        >
          <div className="subagent-modal" onClick={e => e.stopPropagation()}>
            <div className="subagent-modal__head">
              <h3 className="subagent-modal__title">{open.projectName} · {open.rows.length} 个子代理</h3>
              <button type="button" className="subagent-modal__close" aria-label="关闭" onClick={() => setOpen(null)}>
                ×
              </button>
            </div>
            <div className="subagent-modal__list">
              {open.rows.map((r, i) => (
                <div key={i} className="subagent-modal__row">
                  <span className="subagent-modal__idx">{i + 1}</span>
                  <span className="subagent-modal__label" title={r.label}>{r.label}</span>
                  <span className="subagent-modal__tokens">{formatTokens(r.tokens)} tokens</span>
                  <span className="subagent-modal__cost">{formatUsdMicros(r.costUsdMicros)}</span>
                </div>
              ))}
            </div>
          </div>
        </div>
      ) : null}
    </>
  );
}
