import { useCallback, useEffect, useState } from 'react';

import type { ModelRank, OverviewKpis, OverviewPayload, ScanProgress } from '../api.js';
import { AgentTrendChart, type AgentTrendMetric } from '../charts/AgentTrendChart.js';
import { YearHeatmap, type HeatmapMetric } from '../charts/YearHeatmap.js';
import { SessionRail } from '../components/SessionRail.js';
import { formatCount, formatTokens, formatUnknownCostNote, formatUsdMicros } from '../format.js';
import { useAnimatedNumber } from '../hooks/useAnimatedNumber.js';
import { useAutoRefresh } from '../hooks/useAutoRefresh.js';

type OverviewState =
  | { kind: 'loading' }
  | { kind: 'loaded'; payload: OverviewPayload }
  | { kind: 'failed'; message: string };

type TrendGranularity = 'day' | 'week' | 'month';

const TREND_METRICS: Array<{ metric: AgentTrendMetric; label: string }> = [
  { metric: 'tokens', label: 'Token' },
  { metric: 'costUsdMicros', label: '花费' },
  { metric: 'sessions', label: '会话' }
];

const TREND_GRANULARITIES: Array<{ granularity: TrendGranularity; label: string }> = [
  { granularity: 'day', label: '日' },
  { granularity: 'week', label: '周' },
  { granularity: 'month', label: '月' }
];

const TREND_DESC: Record<TrendGranularity, Record<AgentTrendMetric, string>> = {
  day: { tokens: '每日 Token 用量', costUsdMicros: '每日花费', sessions: '每日会话数' },
  week: { tokens: '每周 Token 用量', costUsdMicros: '每周花费', sessions: '每周会话数' },
  month: { tokens: '每月 Token 用量', costUsdMicros: '每月花费', sessions: '每月会话数' }
};

const HEATMAP_METRICS: Array<{ metric: HeatmapMetric; label: string }> = [
  { metric: 'tokens', label: 'Token' },
  { metric: 'costUsdMicros', label: '成本' },
  { metric: 'sessions', label: '会话' },
  { metric: 'events', label: '事件' }
];

/// 服务商显示名（菜单栏与趋势图例同款）。名单外回落到原始 id。
const PROVIDER_LABEL: Record<string, string> = {
  'claude-code': 'Claude Code',
  codex: 'Codex CLI',
  omp: 'OMP',
  opencode: 'OpenCode'
};

function providerLabel(id: string | null): string {
  if (id === null) return '混合';
  return PROVIDER_LABEL[id] ?? id;
}

/// 模型排行展示前 8 名，其余聚合成一行「其他 N 个模型」。
const MODEL_RANK_LIMIT = 8;

export function Overview({ intervalMs = 60_000 }: { intervalMs?: number }) {
  const [state, setState] = useState<OverviewState>({ kind: 'loading' });
  const [trendMetric, setTrendMetric] = useState<AgentTrendMetric>('tokens');
  const [trendGranularity, setTrendGranularity] = useState<TrendGranularity>('day');
  const [heatMetric, setHeatMetric] = useState<HeatmapMetric>('tokens');
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

  const ready = state.kind === 'loaded' && state.payload.dataState === 'ready' ? state.payload : null;
  const liveCount = ready ? ready.sessionRail.filter((s) => s.isLive).length : 0;

  return (
    <section className="view">
      <div className="vhead">
        <h1>总览</h1>
        {ready ? <span className="sub">{headSubtitle(ready.kpis, ready.today)}</span> : null}
        <div className="spacer" />
        <button className="btn" type="button" onClick={() => refreshNow()}>
          刷新
        </button>
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
        <>
          <StatTiles kpis={ready.kpis} />

          <div className="card" aria-label="实时会话">
            <div className="chead">
              <div>
                <h2>实时会话</h2>
                <div className="desc">最新 10 个 · 运行中判定：2 分钟内有新事件写入日志</div>
              </div>
              <div className="spacer" />
              {liveCount > 0 ? <span className="live-tag">实时</span> : null}
            </div>
            <SessionRail sessions={ready.sessionRail} now={Date.now()} />
          </div>

          <div className="card" aria-label="用量趋势">
            <div className="chead">
              <div>
                <h2>用量趋势</h2>
                <div className="desc">{TREND_DESC[trendGranularity][trendMetric]}</div>
              </div>
              <div className="spacer" />
              <div className="seg" role="group" aria-label="趋势指标">
                {TREND_METRICS.map((m) => (
                  <button
                    key={m.metric}
                    type="button"
                    className={trendMetric === m.metric ? 'on' : ''}
                    aria-pressed={trendMetric === m.metric}
                    onClick={() => setTrendMetric(m.metric)}
                  >
                    {m.label}
                  </button>
                ))}
              </div>
              <div className="seg" role="group" aria-label="趋势粒度">
                {TREND_GRANULARITIES.map((g) => (
                  <button
                    key={g.granularity}
                    type="button"
                    className={trendGranularity === g.granularity ? 'on' : ''}
                    aria-pressed={trendGranularity === g.granularity}
                    onClick={() => setTrendGranularity(g.granularity)}
                  >
                    {g.label}
                  </button>
                ))}
              </div>
            </div>
            <AgentTrendChart data={ready.agentTrend[trendGranularity]} metric={trendMetric} />
            {trendMetric === 'costUsdMicros' && ready.kpis.totalCostUnknownEvents > 0 ? (
              <p className="note">
                趋势金额不含价格未知事件（累计 {formatCount(ready.kpis.totalCostUnknownEvents)} 条）
              </p>
            ) : null}
          </div>

          <div className="card" aria-label="全年活跃度">
            <div className="chead">
              <div>
                <h2>全年活跃度</h2>
                <div className="desc">近 365 天</div>
              </div>
              <div className="spacer" />
              <div className="seg" role="group" aria-label="热力图指标">
                {HEATMAP_METRICS.map((m) => (
                  <button
                    key={m.metric}
                    type="button"
                    className={heatMetric === m.metric ? 'on' : ''}
                    aria-pressed={heatMetric === m.metric}
                    onClick={() => setHeatMetric(m.metric)}
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
              metric={heatMetric}
            />
          </div>

          <div className="card" aria-label="模型用量排行">
            <div className="chead">
              <div>
                <h2>模型用量排行</h2>
                <div className="desc">按累计 token 降序 · 归一化模型标识</div>
              </div>
            </div>
            <ModelRankingTable rows={ready.modelRanking} />
          </div>
        </>
      ) : null}
    </section>
  );
}

function headSubtitle(kpis: OverviewKpis, today: string): string {
  if (kpis.firstDate === null) return '';
  const days = Math.round((Date.parse(`${today}T00:00:00`) - Date.parse(`${kpis.firstDate}T00:00:00`)) / 86_400_000) + 1;
  return `自 ${kpis.firstDate} 起 · ${formatCount(days)} 天 · ${formatCount(kpis.totalEvents)} 条用量事件`;
}

/// 设计稿的四指标卡：累计成本 / 累计 Token / 本月成本 / 今日。
/// 价格未知的黄点标注走 .unk（每个显示成本的地方都要能表达「其中 N 条未知」）。
function StatTiles({ kpis }: { kpis: OverviewKpis }) {
  const monthLabel = `${new Date().getMonth() + 1}/1 至今`;
  return (
    <div className="stats" aria-label="累计指标">
      <div className="stat">
        <div className="lb">累计成本</div>
        <div className="v"><AnimatedNumber value={kpis.totalCostUsdMicros} format={formatUsdMicros} /></div>
        {kpis.totalCostUnknownEvents > 0 ? (
          <div className="sb unk">其中 {formatUnknownCostNote(kpis.totalCostUnknownEvents)}</div>
        ) : null}
      </div>
      <div className="stat">
        <div className="lb">累计 Token</div>
        <div className="v"><AnimatedNumber value={kpis.totalTokens} format={formatTokens} /></div>
        <div className="sb">
          {formatCount(kpis.totalEvents)} 条事件 · {formatCount(kpis.totalSessions)} 会话
        </div>
      </div>
      <div className="stat">
        <div className="lb">本月成本</div>
        <div className="v"><AnimatedNumber value={kpis.monthCostUsdMicros} format={formatUsdMicros} /></div>
        <div className={kpis.monthCostUnknownEvents > 0 ? 'sb unk' : 'sb'}>
          {monthLabel}
          {kpis.monthCostUnknownEvents > 0 ? ` · 其中 ${formatCount(kpis.monthCostUnknownEvents)} 条未知` : ''}
        </div>
      </div>
      <div className="stat">
        <div className="lb">今日</div>
        <div className="v"><AnimatedNumber value={kpis.todayCostUsdMicros} format={formatUsdMicros} /></div>
        <div className={kpis.todayCostUnknownEvents > 0 ? 'sb unk' : 'sb'}>
          {formatTokens(kpis.todayTokens)} tokens · {formatCount(kpis.todaySessions)} 会话
          {kpis.todayCostUnknownEvents > 0 ? ` · ${formatCount(kpis.todayCostUnknownEvents)} 条未知` : ''}
        </div>
      </div>
    </div>
  );
}

/// KPI 大数字刷新时的过渡入口：见 useAnimatedNumber 关于为什么首次挂载不动画。
function AnimatedNumber({ value, format }: { value: number; format: (n: number) => string }) {
  return <>{format(useAnimatedNumber(value))}</>;
}

/// 设计稿的模型排行表：模型 / 服务商 / Token（横条+数值）/ 占比 / 成本 / 备注。
/// 前 8 名单列，其余聚合为「其他 N 个模型」（服务商列显示「混合」）。
function ModelRankingTable({ rows }: { rows: ModelRank[] }) {
  if (rows.length === 0) return <p className="muted">还没有模型用量。</p>;

  const totalTokens = rows.reduce((sum, r) => sum + r.tokens, 0);
  const top = rows.slice(0, MODEL_RANK_LIMIT);
  const rest = rows.slice(MODEL_RANK_LIMIT);
  const restRow: ModelRank | null = rest.length > 0
    ? rest.reduce(
        (acc, r) => ({
          ...acc,
          tokens: acc.tokens + r.tokens,
          costUsdMicros: acc.costUsdMicros + r.costUsdMicros,
          costUnknownEvents: acc.costUnknownEvents + r.costUnknownEvents
        }),
        { model: `其他 ${rest.length} 个模型`, tokens: 0, costUsdMicros: 0, costUnknownEvents: 0, providerId: null }
      )
    : null;
  const maxTokens = Math.max(1, ...top.map(r => r.tokens));

  const renderRow = (r: ModelRank, isRest: boolean) => {
    const note = formatUnknownCostNote(r.costUnknownEvents);
    const allUnknown = r.costUsdMicros === 0 && r.costUnknownEvents > 0;
    return (
      <tr key={r.model}>
        <td>{isRest ? <span className="muted">{r.model}</span> : <span className="mname">{r.model}</span>}</td>
        <td>{isRest ? '混合' : providerLabel(r.providerId)}</td>
        <td>
          <div className="mbar">
            <div className="bar"><i style={{ width: `${Math.round((r.tokens / maxTokens) * 100)}%` }} /></div>
            <span className="num">{formatTokens(r.tokens)}</span>
          </div>
        </td>
        <td className="r num">{totalTokens > 0 ? `${((r.tokens / totalTokens) * 100).toFixed(1)}%` : '0%'}</td>
        <td className="r num">{allUnknown ? '—' : formatUsdMicros(r.costUsdMicros)}</td>
        <td>{note ? <span className="unk">{allUnknown ? `全部 ${note}` : note}</span> : null}</td>
      </tr>
    );
  };

  return (
    <table>
      <thead>
        <tr>
          <th>模型</th>
          <th>服务商</th>
          <th>Token</th>
          <th className="r">占比</th>
          <th className="r">成本</th>
          <th>备注</th>
        </tr>
      </thead>
      <tbody>
        {top.map(r => renderRow(r, false))}
        {restRow ? renderRow(restRow, true) : null}
      </tbody>
    </table>
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
      <button className="btn primary" type="button" onClick={onReindex} disabled={reindexing}>
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
