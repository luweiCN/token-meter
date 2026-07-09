import type { DashboardOverview, IndexStatusResult } from '../api.js';

type DashboardIndexState =
  | { kind: 'loading' }
  | { kind: 'loaded'; status: IndexStatusResult }
  | { kind: 'failed'; message: string };

type DashboardOverviewState =
  | { kind: 'loading' }
  | { kind: 'loaded'; overview: DashboardOverview }
  | { kind: 'failed'; message: string };

interface DashboardProps {
  indexState: DashboardIndexState;
  overviewState: DashboardOverviewState;
  onRefresh(): Promise<void>;
}

export function Dashboard({ indexState, overviewState, onRefresh }: DashboardProps) {
  const summary = indexState.kind === 'loaded' ? summarizeIndexStatus(indexState.status) : null;
  const overview = overviewState.kind === 'loaded' ? overviewState.overview : null;

  return (
    <>
      <p className="eyebrow">本地分析</p>
      <div className="page-heading-row">
        <h1>概览</h1>
        <button className="primary-button" type="button" onClick={() => { void onRefresh().catch(() => {}); }}>刷新概览</button>
      </div>
      <p className="lede">这里汇总本机代码 Agent 的 Token 用量，按来源、项目和模型查看趋势。</p>
      {indexState.kind === 'failed' ? <p className="status-error" role="status">索引状态加载失败：{indexState.message}</p> : null}
      {overviewState.kind === 'failed' ? <p className="status-error" role="status">概览数据加载失败：{overviewState.message}</p> : null}
      <div className="placeholder-grid" aria-label="概览指标卡片">
        <article className="metric-card">
          <span>本地索引</span>
          <strong>{summary?.label ?? (indexState.kind === 'loading' ? '读取中' : '状态未知')}</strong>
        </article>
        <article className="metric-card">
          <span>总会话</span>
          <strong>{overview ? formatCount(overview.sessionCount) : '读取中'}</strong>
        </article>
        <article className="metric-card">
          <span>总 Token</span>
          <strong>{overview ? formatTokens(overview.totalTokens) : '读取中'}</strong>
        </article>
        <article className="metric-card">
          <span>活跃模型</span>
          <strong>{overview ? formatCount(overview.activeModelCount) : '读取中'}</strong>
        </article>
        <article className="metric-card">
          <span>扫描源</span>
          <strong>{summary ? `${summary.attentionRoots} 个扫描源需要处理` : '读取中'}</strong>
        </article>
        <article className="metric-card">
          <span>失败文件</span>
          <strong>{summary ? `${summary.failedFiles} 个失败文件` : '读取中'}</strong>
        </article>
      </div>
      {overview ? <OverviewDetails overview={overview} /> : null}
    </>
  );
}

function OverviewDetails({ overview }: { overview: DashboardOverview }) {
  const peakDailyTokens = Math.max(...overview.dailyTrend.map((point) => point.tokensTotal), 1);
  return (
    <div className="overview-grid">
      <section className="empty-panel" aria-label="模型 Token 排行">
        <h2>模型 Token 排行</h2>
        <div className="rank-list">
          {overview.modelBreakdown.length === 0 ? <p className="muted">还没有模型用量。</p> : overview.modelBreakdown.map((model) => (
            <article className="rank-row" key={model.modelName}>
              <div>
                <strong>{model.modelName}</strong>
                <span>{formatCount(model.sessionsCount)} 个会话</span>
              </div>
              <strong>{formatTokens(model.tokensTotal)}</strong>
            </article>
          ))}
        </div>
      </section>

      <section className="empty-panel" aria-label="提供商 Token 汇总">
        <h2>提供商汇总</h2>
        <div className="rank-list">
          {overview.providerBreakdown.length === 0 ? <p className="muted">还没有提供商用量。</p> : overview.providerBreakdown.map((provider) => (
            <article className="rank-row" key={provider.providerId}>
              <div>
                <strong>{provider.providerId}</strong>
                <span>{formatCount(provider.sessionsCount)} 个会话</span>
              </div>
              <strong>{formatTokens(provider.tokensTotal)}</strong>
            </article>
          ))}
        </div>
      </section>

      <section className="empty-panel overview-wide" aria-label="最近 7 天 Token 趋势">
        <h2>最近 7 天 Token 趋势</h2>
        <div className="trend-list">
          {overview.dailyTrend.length === 0 ? <p className="muted">还没有每日用量。</p> : overview.dailyTrend.map((point) => (
            <article className="trend-row" key={point.usageDate}>
              <span>{point.usageDate}</span>
              <div className="trend-bar" aria-hidden="true">
                <span style={{ width: `${Math.max(4, Math.round((point.tokensTotal / peakDailyTokens) * 100))}%` }} />
              </div>
              <strong>{formatTokens(point.tokensTotal)}</strong>
              <span>{formatCount(point.sessionsCount)} 个会话</span>
            </article>
          ))}
        </div>
      </section>
    </div>
  );
}

function summarizeIndexStatus(status: IndexStatusResult) {
  const attentionRoots = status.roots.filter((root) => root.lastError !== null).length;
  const failedRuns = status.runs.filter((run) => run.status === 'partial' || run.status === 'failed').length;
  const failedFiles = status.failedFiles.length;
  const label = failedFiles > 0 || failedRuns > 0 || attentionRoots > 0 ? '索引部分失败' : '索引正常';

  return {
    attentionRoots,
    failedFiles,
    label
  };
}

function formatCount(value: number) {
  return new Intl.NumberFormat('en-US').format(value);
}

function formatTokens(value: number) {
  if (value >= 1_000_000_000) return `${(value / 1_000_000_000).toFixed(2)}B`;
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(2)}M`;
  if (value >= 1_000) return `${(value / 1_000).toFixed(2)}K`;
  return formatCount(value);
}
