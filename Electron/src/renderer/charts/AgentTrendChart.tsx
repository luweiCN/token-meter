import { useMemo, useState, type MouseEvent } from 'react';

import type { AgentTrendSeries } from '../api.js';
import { formatCount, formatTokens, formatUsdMicros } from '../format.js';
import { chartAnimationDelay } from './chartMotion.js';

export type AgentTrendMetric = 'tokens' | 'costUsdMicros' | 'sessions';

/// agent → 系列色（设计稿 s1-s4）与显示名。名单外的 provider 归到「其他」（muted 灰）。
const KNOWN_PROVIDERS: Array<{ id: string; label: string; cssVar: string }> = [
  { id: 'claude-code', label: 'Claude Code', cssVar: 'var(--s1)' },
  { id: 'codex', label: 'Codex CLI', cssVar: 'var(--s2)' },
  { id: 'omp', label: 'OMP', cssVar: 'var(--s3)' },
  { id: 'opencode', label: 'OpenCode', cssVar: 'var(--s4)' }
];
const OTHER = { id: '__other', label: '其他', cssVar: 'var(--muted)' };

function metricValue(row: { tokens: number; costUsdMicros: number; sessions: number }, metric: AgentTrendMetric): number {
  return row[metric];
}

/// dailyScale：day 粒度的桶是单日数字，token 锁 M 单位（不升 B）。
function formatMetric(value: number, metric: AgentTrendMetric, dailyScale = false): string {
  if (metric === 'tokens') return formatTokens(value, dailyScale);
  if (metric === 'costUsdMicros') return formatUsdMicros(value);
  return formatCount(value);
}

/// x 轴最多摆 8 个标签，其余省略——30 天/12 周/12 月都读得动。
function xLabelStride(bucketCount: number): number {
  return Math.max(1, Math.ceil(bucketCount / 8));
}

function xLabelText(bucket: string): string {
  // '2026-07-04' → '7/4'；'2026-07' → '26/7'（月粒度跨年时年份不可省）
  const parts = bucket.split('-');
  if (parts.length === 3) return `${Number(parts[1])}/${Number(parts[2])}`;
  return `${parts[0].slice(2)}/${Number(parts[1])}`;
}

/// 设计稿 8c 的直方图：SVG 堆叠柱 + 右缘 y 刻度 + x 标签 + tooltip（.tip）。
/// 数据量小（≤30 桶 × ≤5 系列），纯 SVG 一次渲染，不引入图表库。
export function AgentTrendChart({
  data, metric, providerNames = {}
}: { data: AgentTrendSeries; metric: AgentTrendMetric; providerNames?: Record<string, string> }) {
  const [tip, setTip] = useState<{ bucket: string; x: number; y: number } | null>(null);

  const { buckets } = data;
  // day 粒度的桶与 tooltip 都是单日数字 → token 锁 M 单位；图例合计是范围总和，仍可用 B。
  const dailyBuckets = data.granularity === 'day';
  const byBucket = useMemo(() => {
    const m = new Map<string, Map<string, { tokens: number; costUsdMicros: number; sessions: number }>>();
    for (const row of data.rows) {
      let inner = m.get(row.bucket);
      if (!inner) {
        inner = new Map();
        m.set(row.bucket, inner);
      }
      inner.set(row.providerId, row);
    }
    return m;
  }, [data.rows]);

  /// 实际出现过的系列，按 s1-s4 固定顺序；未知 provider 合并进「其他」。
  /// 系列名先看设置里的供应商别名（providerNames），再落到内置名。
  const seriesDefs = useMemo(() => {
    const present = new Set(data.rows.map(r => r.providerId));
    const known = KNOWN_PROVIDERS.filter(p => present.has(p.id))
      .map(p => ({ ...p, label: providerNames[p.id] ?? p.label }));
    const hasOther = [...present].some(id => !KNOWN_PROVIDERS.some(p => p.id === id));
    return hasOther ? [...known, OTHER] : known;
  }, [data.rows, providerNames]);

  const stackOf = (bucket: string): Array<{ def: typeof OTHER; value: number }> => {
    const inner = byBucket.get(bucket);
    if (!inner) return [];
    return seriesDefs.map(def => {
      let value = 0;
      if (def.id === OTHER.id) {
        for (const [pid, row] of inner) {
          if (!KNOWN_PROVIDERS.some(p => p.id === pid)) value += metricValue(row, metric);
        }
      } else {
        const row = inner.get(def.id);
        if (row) value = metricValue(row, metric);
      }
      return { def, value };
    }).filter(s => s.value > 0);
  };

  const totals = buckets.map(b => stackOf(b).reduce((sum, s) => sum + s.value, 0));
  const max = Math.max(1, ...totals);
  const seriesTotals = seriesDefs.map(def => ({
    def,
    total: buckets.reduce((sum, b) => sum + (stackOf(b).find(s => s.def.id === def.id)?.value ?? 0), 0)
  }));

  // 画布几何：viewBox 固定，柱宽按桶数均分（间隙 38%）。
  const W = 1000;
  const H = 240;
  const slot = W / buckets.length;
  const barW = Math.max(2, slot * 0.62);

  const stride = xLabelStride(buckets.length);

  const onMove = (e: MouseEvent, bucket: string) => {
    setTip({ bucket, x: e.clientX, y: e.clientY });
  };

  const tipStack = tip ? stackOf(tip.bucket) : [];
  const tipTotal = tipStack.reduce((sum, s) => sum + s.value, 0);
  const motionKey = `${data.granularity}:${metric}:${data.rows
    .map((row) => `${row.bucket}/${row.providerId}/${metricValue(row, metric)}`)
    .join('|')}`;

  return (
    <div className="chart-wrap" onMouseLeave={() => setTip(null)}>
      <svg key={motionKey} viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" role="img" aria-label="用量趋势直方图">
        {/* 三条基准线（0 线在底部由柱子自然形成） */}
        {[1 / 3, 2 / 3, 1].map(f => (
          <line key={f} x1="0" x2={W} y1={H - f * (H - 10)} y2={H - f * (H - 10)}
            stroke="var(--chart-grid)" strokeWidth="1" vectorEffect="non-scaling-stroke" />
        ))}
        {buckets.map((bucket, i) => {
          let y = H;
          const segs = stackOf(bucket);
          return (
            <g key={bucket} className="trend-col chart-bar-y-in"
              style={{ animationDelay: chartAnimationDelay(i) }}
              onMouseMove={e => onMove(e, bucket)}
              onMouseEnter={e => onMove(e, bucket)}
              onMouseLeave={() => setTip(null)}>
              {/* 命中区就是柱段矩形本身：悬停柱子才出 tooltip，
                  空桶和柱子上方的留白都不触发（移出柱子立即收起）。 */}
              {segs.map(({ def, value }) => {
                const h = (value / max) * (H - 10);
                y -= h;
                return (
                  <rect key={def.id} x={i * slot + (slot - barW) / 2} y={y} width={barW} height={h}
                    fill={def.cssVar} rx="1.5" />
                );
              })}
            </g>
          );
        })}
      </svg>

      <div className="yticks" aria-hidden="true">
        <span>{formatMetric(max, metric, dailyBuckets)}</span>
        <span>{formatMetric(max * 2 / 3, metric, dailyBuckets)}</span>
        <span>{formatMetric(max / 3, metric, dailyBuckets)}</span>
        <span>{formatMetric(0, metric, dailyBuckets)}</span>
      </div>

      <div className="xlabels" aria-hidden="true">
        {buckets.map((b, i) => (
          <span key={b}>{i % stride === 0 || i === buckets.length - 1 ? xLabelText(b) : ' '}</span>
        ))}
      </div>

      <div className="legend">
        {seriesTotals.map(({ def, total }) => (
          <span className="it" key={def.id}>
            <i style={{ background: def.cssVar }} />
            {def.label} <span className="num">{formatMetric(total, metric)}</span>
          </span>
        ))}
      </div>

      {tip && tipStack.length > 0 ? (() => {
        // 贴近窗口右缘时翻到鼠标左侧：translateX(-100%) 让浮层右缘贴在
        // 鼠标左侧 12px。阈值按 .tip 的 max-width（320px，见 styles.css）
        // 保守估计，窄内容时早翻无伤。
        const flipLeft = tip.x + 12 + 320 + 8 > window.innerWidth;
        return (
        <div
          className="tip"
          style={{
            display: 'block',
            left: flipLeft ? tip.x - 12 : tip.x + 12,
            top: tip.y + 12,
            transform: flipLeft ? 'translateX(-100%)' : 'none'
          }}
        >
          <b>{tip.bucket}</b>
          {tipStack.map(({ def, value }) => (
            <div className="row" key={def.id}>
              <span><i style={{ background: def.cssVar }} />{def.label}</span>
              <span className="num">{formatMetric(value, metric, dailyBuckets)}</span>
            </div>
          ))}
          <div className="row total">
            <span>合计</span>
            <span className="num">{formatMetric(tipTotal, metric, dailyBuckets)}</span>
          </div>
        </div>
        );
      })() : null}
    </div>
  );
}
