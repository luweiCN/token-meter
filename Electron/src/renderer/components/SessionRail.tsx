import type { ActivityRow } from '../api.js';
import { formatDuration, formatRelative, formatTokens, formatUnknownCostNote, formatUsdMicros } from '../format.js';

/// 右栏会话列表（spec §7.2）：进行中的（5 分钟内消耗过 token）置顶并打脉冲点，
/// 下方是最近结束的若干条。数据已由 repository 的 sessionRail 排好序（live 组置顶，
/// 组内按最近事件倒序），这里只负责画。
///
/// 「进行中」不等于「正在运行」——没有可靠的非侵入判据（spec §7.2.1），这里只陈述
/// 磁盘上的事实：这个会话在 5 分钟内消耗过 token。
export function SessionRail({ sessions, now }: { sessions: ActivityRow[]; now: number }) {
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
        </li>
      ))}
    </ul>
  );
}
