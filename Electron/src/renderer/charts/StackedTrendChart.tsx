import { useState, type MouseEvent } from 'react';

import { chartAnimationDelay } from './chartMotion.js';

/// 通用堆叠日直方图：AgentTrendChart（总览）的画布形态抽象——SVG 堆叠柱 +
/// 右缘 y 刻度 + x 标签 + 图例 + 跟随鼠标 tooltip，系列定义与取值由调用方给。
/// 模型页（Top6 模型 + 其他）与会话页（agent 系列）共用；总览的
/// AgentTrendChart 有 provider 特化逻辑（别名/粒度切换），保持独立不动。

export interface TrendSeriesDef {
  id: string;
  label: string;
  color: string;
}

export function StackedTrendChart({
  buckets,
  series,
  valueOf,
  formatValue,
  ariaLabel
}: {
  buckets: string[];
  series: TrendSeriesDef[];
  /// (bucket, seriesId) → 数值；无数据返回 0。
  valueOf: (bucket: string, seriesId: string) => number;
  formatValue: (value: number) => string;
  ariaLabel: string;
}) {
  const [tip, setTip] = useState<{ bucket: string; x: number; y: number } | null>(null);

  const stackOf = (bucket: string) =>
    series.map((def) => ({ def, value: valueOf(bucket, def.id) })).filter((s) => s.value > 0);

  const totals = buckets.map((b) => stackOf(b).reduce((sum, s) => sum + s.value, 0));
  const max = Math.max(1, ...totals);
  const seriesTotals = series
    .map((def) => ({ def, total: buckets.reduce((sum, b) => sum + valueOf(b, def.id), 0) }))
    .filter((s) => s.total > 0);

  const W = 1000;
  const H = 240;
  const slot = W / Math.max(1, buckets.length);
  const barW = Math.max(2, slot * 0.62);
  const stride = Math.max(1, Math.ceil(buckets.length / 8));
  const xLabelText = (bucket: string) => {
    const parts = bucket.split('-');
    return parts.length === 3 ? `${Number(parts[1])}/${Number(parts[2])}` : bucket;
  };

  const onMove = (e: MouseEvent, bucket: string) => setTip({ bucket, x: e.clientX, y: e.clientY });
  const tipStack = tip ? stackOf(tip.bucket) : [];
  const tipTotal = tipStack.reduce((sum, s) => sum + s.value, 0);
  const motionKey = buckets
    .map((bucket) => `${bucket}:${series.map((def) => valueOf(bucket, def.id)).join(',')}`)
    .join('|');

  return (
    <div className="chart-wrap" onMouseLeave={() => setTip(null)}>
      <svg key={motionKey} viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" role="img" aria-label={ariaLabel}>
        {[1 / 3, 2 / 3, 1].map((f) => (
          <line
            key={f}
            x1="0"
            x2={W}
            y1={H - f * (H - 10)}
            y2={H - f * (H - 10)}
            stroke="var(--chart-grid)"
            strokeWidth="1"
            vectorEffect="non-scaling-stroke"
          />
        ))}
        {buckets.map((bucket, i) => {
          let y = H;
          const segs = stackOf(bucket);
          return (
            <g
              key={bucket}
              className="trend-col chart-bar-y-in"
              style={{ animationDelay: chartAnimationDelay(i) }}
              onMouseMove={(e) => onMove(e, bucket)}
              onMouseEnter={(e) => onMove(e, bucket)}
              onMouseLeave={() => setTip(null)}
            >
              {segs.map(({ def, value }) => {
                const h = (value / max) * (H - 10);
                y -= h;
                return (
                  <rect
                    key={def.id}
                    x={i * slot + (slot - barW) / 2}
                    y={y}
                    width={barW}
                    height={h}
                    fill={def.color}
                    rx="1.5"
                  />
                );
              })}
            </g>
          );
        })}
      </svg>

      <div className="yticks" aria-hidden="true">
        <span>{formatValue(max)}</span>
        <span>{formatValue((max * 2) / 3)}</span>
        <span>{formatValue(max / 3)}</span>
        <span>{formatValue(0)}</span>
      </div>

      <div className="xlabels" aria-hidden="true">
        {buckets.map((b, i) => (
          <span key={b}>{i % stride === 0 || i === buckets.length - 1 ? xLabelText(b) : ' '}</span>
        ))}
      </div>

      <div className="legend">
        {seriesTotals.map(({ def, total }) => (
          <span className="it" key={def.id}>
            <i style={{ background: def.color }} />
            {def.label} <span className="num">{formatValue(total)}</span>
          </span>
        ))}
      </div>

      {tip && tipStack.length > 0
        ? (() => {
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
                    <span>
                      <i style={{ background: def.color }} />
                      {def.label}
                    </span>
                    <span className="num">{formatValue(value)}</span>
                  </div>
                ))}
                <div className="row total">
                  <span>合计</span>
                  <span className="num">{formatValue(tipTotal)}</span>
                </div>
              </div>
            );
          })()
        : null}
    </div>
  );
}
