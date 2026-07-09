import { useEffect, useRef, useState } from 'react';
import type { TrendBucket } from '../../main/overviewRepository.js';
import { layoutStackedBars, SEGMENTS, type Segment } from './stackedBarLayout.js';
import { niceTicks } from './scale.js';

/// 段的填色走 CSS 变量（主题可切），带兜底色，避免本组件依赖 styles.css 的先行定义。
const SEGMENT_FILL: Record<Segment, string> = {
  input: 'var(--seg-input, #4c9be8)',
  cacheWrite: 'var(--seg-cache-write, #f2b134)',
  cacheRead: 'var(--seg-cache-read, #8a63d2)',
  output: 'var(--seg-output, #38b48b)'
};

const SEGMENT_LABEL: Record<Segment, string> = {
  input: '输入',
  cacheWrite: '缓存写',
  cacheRead: '缓存读',
  output: '输出'
};

const MARGIN = { left: 48, right: 8, top: 8, bottom: 20 };

export interface StackedBarChartProps {
  bars: TrendBucket[];
  height?: number;
  /// 显式宽度用于测试与受控布局；缺省时由 ResizeObserver 量取容器宽度。
  width?: number;
}

export function StackedBarChart({ bars, height = 240, width: widthProp }: StackedBarChartProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const [measured, setMeasured] = useState(0);
  const [hovered, setHovered] = useState<TrendBucket | null>(null);

  useEffect(() => {
    if (widthProp !== undefined) return;
    const el = containerRef.current;
    if (!el || typeof ResizeObserver === 'undefined') return;
    const ro = new ResizeObserver(entries => setMeasured(entries[0].contentRect.width));
    ro.observe(el);
    return () => ro.disconnect();
  }, [widthProp]);

  const width = widthProp ?? measured;
  const plotWidth = Math.max(0, width - MARGIN.left - MARGIN.right);
  const plotHeight = Math.max(0, height - MARGIN.top - MARGIN.bottom);

  const { rects, slots, maxTotal } = layoutStackedBars(bars, {
    width: plotWidth,
    height: plotHeight,
    padding: 2
  });

  const ticks = maxTotal > 0 ? niceTicks(maxTotal, 4).filter(t => t <= maxTotal) : [0];
  const stride = bars.length > 12 ? Math.ceil(bars.length / 12) : 1;

  return (
    <div ref={containerRef} className="stacked-bar-chart" style={{ position: 'relative', width: '100%' }}>
      <svg width={width || '100%'} height={height} role="img" aria-label="Token 用量趋势">
        {/* Y 轴刻度与网格线 */}
        <g transform={`translate(0, ${MARGIN.top})`}>
          {ticks.map(t => {
            const y = plotHeight - (maxTotal > 0 ? (t / maxTotal) * plotHeight : 0);
            return (
              <g key={t}>
                <line x1={MARGIN.left} y1={y} x2={width - MARGIN.right} y2={y}
                  stroke="var(--chart-grid, #e2e2e2)" strokeWidth={1} />
                <text x={MARGIN.left - 6} y={y} textAnchor="end" dominantBaseline="middle"
                  fontSize={10} fill="var(--chart-axis, #888)">{t}</text>
              </g>
            );
          })}
        </g>

        {/* 柱子（段）与 hover 覆盖层 */}
        <g transform={`translate(${MARGIN.left}, ${MARGIN.top})`}>
          {rects.map((r, i) => (
            <rect key={`${r.bucket}-${r.segment}-${i}`} data-segment={r.segment}
              x={r.x} y={r.y} width={r.width} height={r.height} fill={SEGMENT_FILL[r.segment]} />
          ))}
          {slots.map(s => {
            const bar = bars.find(b => b.bucket === s.bucket)!;
            return (
              <rect key={s.bucket} data-hover-bucket={s.bucket}
                x={s.x} y={0} width={s.width} height={plotHeight} fill="transparent"
                onMouseEnter={() => setHovered(bar)} onMouseLeave={() => setHovered(null)} />
            );
          })}
        </g>

        {/* X 轴标签：超过 12 根时每 ceil(n/12) 个显示一个 */}
        <g transform={`translate(${MARGIN.left}, 0)`}>
          {slots.map((s, i) => (i % stride === 0 ? (
            <text key={s.bucket} x={s.x + s.width / 2} y={height - 6} textAnchor="middle"
              fontSize={10} fill="var(--chart-axis, #888)">{s.bucket}</text>
          ) : null))}
        </g>
      </svg>

      {hovered && (
        <div role="tooltip" className="stacked-bar-tooltip"
          style={{ position: 'absolute', top: 0, left: 0, pointerEvents: 'none' }}>
          <div className="stacked-bar-tooltip__bucket">{hovered.bucket}</div>
          {SEGMENTS.map(seg => (
            <div key={seg} className="stacked-bar-tooltip__row">
              {SEGMENT_LABEL[seg]}: {hovered[seg].toLocaleString()}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
