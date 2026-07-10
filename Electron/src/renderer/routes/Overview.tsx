import { useCallback, useEffect, useState } from 'react';

import type { ModelRank, OverviewKpis, OverviewPayload, ScanProgress } from '../api.js';
import { StackedBarChart } from '../charts/StackedBarChart.js';
import { YearHeatmap, type HeatmapMetric } from '../charts/YearHeatmap.js';
import { SessionRail } from '../components/SessionRail.js';
import { formatCount, formatTokens, formatUnknownCostNote, formatUsdMicros } from '../format.js';
import { useAutoRefresh } from '../hooks/useAutoRefresh.js';

type OverviewState =
  | { kind: 'loading' }
  | { kind: 'loaded'; payload: OverviewPayload }
  | { kind: 'failed'; message: string };

const HEATMAP_METRICS: Array<{ metric: HeatmapMetric; label: string }> = [
  { metric: 'tokens', label: 'Token' },
  { metric: 'costUsdMicros', label: '成本' },
  { metric: 'sessions', label: '会话' },
  { metric: 'events', label: '事件' }
];

export function Overview({ intervalMs = 60_000 }: { intervalMs?: number }) {
  const [state, setState] = useState<OverviewState>({ kind: 'loading' });
  const [selectedDay, setSelectedDay] = useState<string | null>(null);
  const [metric, setMetric] = useState<HeatmapMetric>('tokens');
  const [railOpen, setRailOpen] = useState(false);
  const [reindexing, setReindexing] = useState(false);
  const [progress, setProgress] = useState<ScanProgress | null>(null);
  const [reindexError, setReindexError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      setState({ kind: 'loaded', payload: await window.tokenMeter.overview.query() });
    } catch (unknownError: unknown) {
      setState({ kind: 'failed', message: unknownError instanceof Error ? unknownError.message : '概览加载失败' });
    }
  }, []);

  // 轮询兜底 + 窗口隐藏暂停 + 单飞去重；返回的 refreshNow 给事件驱动与手动按钮共用。
  const refreshNow = useAutoRefresh(load, { intervalMs });

  // 事件驱动：Swift 扫描完成 → dashboard:invalidate → 走单飞守卫重取。
  useEffect(() => window.tokenMeter.overview.onInvalidate(() => refreshNow()), [refreshNow]);

  // 全量重扫的流式进度（index:scanProgress）；重扫完成会发 dashboard:invalidate，页面自动回到 ready。
  useEffect(
    () =>
      window.tokenMeter.index.onScanProgress((p) => {
        setProgress(p);
      }),
    []
  );

  const startReindex = useCallback(async () => {
    setReindexing(true);
    setReindexError(null);
    setProgress(null);
    try {
      await window.tokenMeter.index.startFullReindex();
      await load();
    } catch (unknownError: unknown) {
      setReindexError(unknownError instanceof Error ? unknownError.message : '重新索引失败');
    } finally {
      setReindexing(false);
    }
  }, [load]);

  if (selectedDay) {
    return <UsagePlaceholder day={selectedDay} onBack={() => setSelectedDay(null)} />;
  }

  const ready = state.kind === 'loaded' && state.payload.dataState === 'ready' ? state.payload : null;
  const liveCount = ready ? ready.sessionRail.filter((s) => s.isLive).length : 0;

  return (
    <>
      <p className="eyebrow">本地分析</p>
      <div className="page-heading-row">
        <h1>概览</h1>
        <div className="overview__actions">
          {ready ? (
            <button
              type="button"
              className={`rail-badge${liveCount > 0 ? ' is-live' : ''}`}
              onClick={() => setRailOpen(true)}
              aria-label={`打开会话列表（${liveCount} 个进行中）`}
            >
              会话<span className="rail-badge__count">{liveCount}</span>
            </button>
          ) : null}
          <button className="primary-button" type="button" onClick={() => refreshNow()}>
            刷新
          </button>
        </div>
      </div>

      {state.kind === 'loading' ? <p className="muted" role="status">正在加载概览…</p> : null}
      {state.kind === 'failed' ? <p className="status-error" role="status">概览加载失败：{state.message}</p> : null}

      {state.kind === 'loaded' && state.payload.dataState === 'never-used' ? <EmptyNeverUsed /> : null}

      {state.kind === 'loaded' && state.payload.dataState === 'needs-reindex' ? (
        <EmptyNeedsReindex
          onReindex={startReindex}
          reindexing={reindexing}
          progress={progress}
          error={reindexError}
        />
      ) : null}

      {ready ? (
        <div className="overview__body">
          <div className="overview__main">
            <KpiRow kpis={ready.kpis} />
            <QuotaRowPlaceholder />

            <section className="empty-panel" aria-label="用量趋势">
              <h2>用量趋势（最近 30 天）</h2>
              <StackedBarChart bars={ready.trend} />
            </section>

            <section className="empty-panel" aria-label="年度活动热力图">
              <div className="overview__panel-head">
                <h2>年度活动</h2>
                <div className="metric-switch" role="group" aria-label="热力图指标">
                  {HEATMAP_METRICS.map((m) => (
                    <button
                      key={m.metric}
                      type="button"
                      className={metric === m.metric ? 'active' : ''}
                      aria-pressed={metric === m.metric}
                      onClick={() => setMetric(m.metric)}
                    >
                      {m.label}
                    </button>
                  ))}
                </div>
              </div>
              <YearHeatmap
                days={ready.heatmap}
                lastDay={ready.heatmapLastDay}
                count={ready.heatmapDays}
                metric={metric}
                onSelectDate={setSelectedDay}
              />
            </section>

            {/* 模型可能有几十上百个，塞在热力图旁边那条窄列里挤不下。放到主区最底部，
                单独占一整行，随内容自然向下延伸，不设高度上限——页面本身可以滚动。 */}
            <section className="empty-panel" aria-label="模型排行">
              <h2>模型排行（按成本）</h2>
              <ModelRankingList rows={ready.modelRanking} />
            </section>
          </div>

          <aside className="overview__rail empty-panel" aria-label="会话列表">
            <h2>会话</h2>
            <SessionRail sessions={ready.sessionRail} now={Date.now()} />
          </aside>

          {railOpen ? (
            <div className="overview__rail-overlay" role="dialog" aria-label="会话列表">
              <div className="overview__rail-overlay-card empty-panel">
                <div className="overview__panel-head">
                  <h2>会话</h2>
                  <button type="button" className="rail-overlay__close" onClick={() => setRailOpen(false)} aria-label="关闭会话列表">
                    关闭
                  </button>
                </div>
                <SessionRail sessions={ready.sessionRail} now={Date.now()} />
              </div>
            </div>
          ) : null}
        </div>
      ) : null}
    </>
  );
}

function KpiRow({ kpis }: { kpis: OverviewKpis }) {
  const unknownNote = formatUnknownCostNote(kpis.todayCostUnknownEvents);
  return (
    <div className="kpi-row" aria-label="今日指标">
      <article className="metric-card">
        <span>今日 Token</span>
        <strong>{formatTokens(kpis.todayTokens)}</strong>
        <span className="metric-card__foot">昨日 {formatTokens(kpis.yesterdayTokens)}</span>
      </article>
      <article className="metric-card">
        <span>今日成本</span>
        <strong>{formatUsdMicros(kpis.todayCostUsdMicros)}</strong>
        {unknownNote ? <span className="cost-unknown">{unknownNote}</span> : null}
      </article>
      <article className="metric-card">
        <span>今日会话</span>
        <strong>{formatCount(kpis.todaySessions)}</strong>
      </article>
      <article className="metric-card">
        <span>本月成本</span>
        <strong>{formatUsdMicros(kpis.monthCostUsdMicros)}</strong>
      </article>
    </div>
  );
}

/// 额度行占位（spec §7.5「额度 3 列」）；额度接入是 Phase 2B。
function QuotaRowPlaceholder() {
  return (
    <div className="quota-row" aria-label="额度（待接入）">
      {['5 小时窗口', '周额度', '月额度'].map((label) => (
        <article className="metric-card is-placeholder" key={label}>
          <span>{label}</span>
          <strong className="muted">待接入</strong>
        </article>
      ))}
    </div>
  );
}

function ModelRankingList({ rows }: { rows: ModelRank[] }) {
  if (rows.length === 0) return <p className="muted">还没有模型用量。</p>;
  return (
    <div className="rank-list">
      {rows.map((m) => {
        const note = formatUnknownCostNote(m.costUnknownEvents);
        return (
          <article className="rank-row" key={m.model}>
            <div>
              <strong>{m.model}</strong>
              <span>{formatTokens(m.tokens)} tokens</span>
            </div>
            <div className="rank-row__cost">
              <strong>{formatUsdMicros(m.costUsdMicros)}</strong>
              {note ? <span className="cost-unknown">{note}</span> : null}
            </div>
          </article>
        );
      })}
    </div>
  );
}

/// 从未用过 agent：不给重扫按钮——扫了也没有语料。
function EmptyNeverUsed() {
  return (
    <div className="empty-state" role="status">
      <h2>未检测到本地 agent 会话</h2>
      <p className="lede">
        没有启用的扫描源，或语料目录不存在。装上 Claude Code、Codex 等 agent 并产生会话后，这里会出现用量。
      </p>
    </div>
  );
}

/// 升级后尚未重扫：数据结构已更新但 rollup 还空，给重扫按钮 + 进度。
function EmptyNeedsReindex({
  onReindex,
  reindexing,
  progress,
  error
}: {
  onReindex: () => void;
  reindexing: boolean;
  progress: ScanProgress | null;
  error: string | null;
}) {
  return (
    <div className="empty-state" role="status">
      <h2>数据结构已更新，需要重新索引一次</h2>
      <p className="lede">
        升级后底层数据结构已迁移，旧的汇总已清空。重新索引一次即可看到全部历史用量（首次可能要跑一会儿）。
      </p>
      <button className="primary-button" type="button" onClick={onReindex} disabled={reindexing}>
        {reindexing ? '正在重新索引…' : '重新索引'}
      </button>
      {error ? <p className="status-error" role="alert">重新索引失败：{error}</p> : null}
      {progress ? (
        <div className="reindex-progress" aria-label="重新索引进度">
          <div className="reindex-progress__bar">
            <span style={{ width: `${progressPct(progress)}%` }} />
          </div>
          <p className="muted">
            {progress.currentRoot ? `${progress.currentRoot} · ` : ''}
            {formatCount(progress.filesDone)} / {formatCount(progress.filesTotal)} 个文件
          </p>
        </div>
      ) : null}
    </div>
  );
}

function progressPct(p: ScanProgress): number {
  if (p.filesTotal > 0) return Math.min(100, Math.round((p.filesDone / p.filesTotal) * 100));
  if (p.bytesTotal > 0) return Math.min(100, Math.round((p.bytesDone / p.bytesTotal) * 100));
  return 0;
}

/// 热力图点击某天 → 用量页（from = to = 该天，粒度 hour）。用量页是 Phase 2B，这里先给占位。
function UsagePlaceholder({ day, onBack }: { day: string; onBack: () => void }) {
  return (
    <>
      <p className="eyebrow">用量</p>
      <div className="page-heading-row">
        <h1>用量</h1>
        <button className="primary-button" type="button" onClick={onBack}>
          返回概览
        </button>
      </div>
      <section className="empty-panel" aria-label="用量筛选（占位）">
        <p className="lede">用量页将在 Phase 2B 实现。当前筛选：</p>
        <dl className="usage-placeholder__filter">
          <dt>开始</dt>
          <dd>{day}</dd>
          <dt>结束</dt>
          <dd>{day}</dd>
          <dt>粒度</dt>
          <dd>hour</dd>
        </dl>
      </section>
    </>
  );
}
