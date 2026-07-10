import { useEffect, useMemo, useRef, useState } from 'react';
import uPlot from 'uplot';
import 'uplot/dist/uPlot.min.css';

import type { TrendBucket } from '../../main/overviewRepository.js';
import { formatTokens } from '../format.js';
import {
  SEGMENTS,
  SEGMENT_LABEL,
  axisLabelStride,
  buildStackedSeries,
  tooltipRows,
  type Segment,
  type TrendMode
} from './trendSeries.js';

export interface StackedBarChartProps {
  bars: TrendBucket[];
  height?: number;
  /// 显式宽度用于受控布局；缺省时由 ResizeObserver 量取容器宽度。
  width?: number;
}

/// uPlot 的画布画不进 CSS 变量，所以把 --seg-*/--chart-* 解析成实际色值传给它。
/// 图例与 tooltip 用 DOM，仍可直接吃 var()，两边取同一批色值保持一致。
function resolveColors(el: HTMLElement) {
  const cs = getComputedStyle(el);
  const v = (name: string, fallback: string) => cs.getPropertyValue(name).trim() || fallback;
  const seg: Record<Segment, string> = {
    input: v('--seg-input', '#0fc5ed'),
    cacheWrite: v('--seg-cache-write', '#44ffb1'),
    cacheRead: v('--seg-cache-read', '#a277ff'),
    output: v('--seg-output', '#24eaf7')
  };
  return { seg, axis: v('--chart-axis', '#8ea0c4'), grid: v('--chart-grid', '#16324b') };
}

function xLabel(bucket: string): string {
  const space = bucket.indexOf(' ');
  if (space >= 0) return bucket.slice(space + 1); // 小时桶：'YYYY-MM-DD HH' → 'HH'
  return bucket.length > 5 ? bucket.slice(5) : bucket; // 日桶：'YYYY-MM-DD' → 'MM-DD'
}

const FONT = '11px -apple-system, BlinkMacSystemFont, system-ui, sans-serif';

/// 悬停跟随光标的 tooltip + 高亮当前柱子。uPlot 的 cursor 给出 idx / left(px)，
/// tooltip 就定位在【那一根柱子】旁并做右缘夹取——修掉旧实现写死 top:0/left:0 的 bug。
function hoverPlugin(bars: TrendBucket[], mode: TrendMode, seg: Record<Segment, string>): uPlot.Plugin {
  let tip: HTMLDivElement;
  let band: HTMLDivElement;

  const hide = () => {
    if (tip) tip.style.display = 'none';
    if (band) band.style.display = 'none';
  };

  return {
    hooks: {
      init: (u) => {
        const over = u.over;
        band = document.createElement('div');
        band.className = 'trend-chart__hover';
        band.style.display = 'none';
        over.appendChild(band);

        tip = document.createElement('div');
        tip.className = 'trend-chart__tooltip';
        tip.style.display = 'none';
        over.appendChild(tip);

        over.addEventListener('mouseleave', hide);
      },
      setCursor: (u) => {
        const { idx, left, top } = u.cursor;
        if (idx == null || left == null || left < 0 || !bars[idx]) {
          hide();
          return;
        }
        const bar = bars[idx];
        const overW = u.over.clientWidth;
        const overH = u.over.clientHeight;
        const cx = u.valToPos(idx, 'x');
        const slot = bars.length > 1 ? Math.abs(u.valToPos(1, 'x') - u.valToPos(0, 'x')) : overW * 0.6;
        const bandW = Math.max(6, slot * 0.82);

        band.style.left = `${cx - bandW / 2}px`;
        band.style.width = `${bandW}px`;
        band.style.height = `${overH}px`;
        band.style.display = 'block';

        const total = SEGMENTS.reduce((s, k) => s + bar[k], 0);
        const pct = (v: number) => (total > 0 ? ` · ${((100 * v) / total).toFixed(v / total >= 0.1 ? 0 : 1)}%` : '');
        tip.innerHTML =
          `<div class="trend-chart__tooltip-bucket">${bar.bucket}</div>` +
          tooltipRows(bar)
            .map(
              (r) =>
                `<div class="trend-chart__tooltip-row"><span><i class="trend-chart__tooltip-dot" style="background:${seg[r.segment]}"></i>${r.label}</span><b>${formatTokens(r.value)}${pct(r.value)}</b></div>`
            )
            .join('');
        tip.style.display = 'block';

        const tw = tip.offsetWidth;
        const th = tip.offsetHeight;
        let tx = cx + 14;
        if (tx + tw > overW) tx = cx - tw - 14; // 靠右缘时翻到光标左侧，末几根柱子的 tooltip 不出界
        tx = Math.max(4, Math.min(tx, overW - tw - 4));
        let ty = (top ?? 0) - th - 12; // 浮在光标上方
        if (ty < 4) ty = (top ?? 0) + 16; // 上方没地方就翻到下方
        ty = Math.max(4, Math.min(ty, overH - th - 4));
        tip.style.left = `${tx}px`;
        tip.style.top = `${ty}px`;
      }
    }
  };
}

export function StackedBarChart({ bars, height = 240, width: widthProp }: StackedBarChartProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const plotRef = useRef<HTMLDivElement>(null);
  const [measured, setMeasured] = useState(0);
  const [mode, setMode] = useState<TrendMode>('absolute');

  const width = widthProp ?? measured;
  const series = useMemo(() => buildStackedSeries(bars, mode), [bars, mode]);

  useEffect(() => {
    if (widthProp !== undefined) return;
    const el = containerRef.current;
    if (!el || typeof ResizeObserver === 'undefined') return;
    const ro = new ResizeObserver((entries) => setMeasured(entries[0].contentRect.width));
    ro.observe(el);
    return () => ro.disconnect();
  }, [widthProp]);

  useEffect(() => {
    const target = plotRef.current;
    if (!target || width <= 0 || bars.length === 0) return;
    // 画布不可用（jsdom 等无 canvas 环境）就不建 uPlot——组件外壳照常渲染，不抛错。
    const probe = document.createElement('canvas');
    if (!probe.getContext || !probe.getContext('2d')) return;

    const { seg, axis, grid } = resolveColors(containerRef.current ?? target);
    const stride = axisLabelStride(bars.length);
    const barsPath = uPlot.paths.bars?.({ size: [0.68, 46], align: 0 });

    // series/data 从「总量段」到「输入段」的顺序排列：uPlot 先画的在下、后画的覆盖在上，
    // 每条都从 0 基线画满到各自累积高度，靠覆盖叠出四段颜色（详见 trendSeries）。
    const fillsTopDown = [seg.output, seg.cacheRead, seg.cacheWrite, seg.input];
    const data: uPlot.AlignedData = [
      series.x,
      series.cumulative[3],
      series.cumulative[2],
      series.cumulative[1],
      series.cumulative[0]
    ];

    const opts: uPlot.Options = {
      width,
      height,
      padding: [8, 8, 0, 8],
      cursor: { x: true, y: false, points: { show: false }, drag: { x: false, y: false, setScale: false } },
      legend: { show: false },
      scales: {
        // x 轴不给 range 时，uPlot 按数据的 min/max（0 和 N-1）精确定边界，
        // 第一根/最后一根柱子的中心就正好落在画布边缘——柱宽被砍掉一半。
        // 两侧各留半格，让边缘柱子跟其余柱子一样两侧对称。
        x: { time: false, range: (_u, min, max) => [min - 0.5, max + 0.5] },
        y: { range: (_u, _min, max) => (mode === 'share' ? [0, 1] : [0, max * 1.04]) }
      },
      axes: [
        {
          stroke: axis,
          font: FONT,
          grid: { show: false },
          ticks: { show: false },
          gap: 6,
          splits: () => series.x.filter((i) => i % stride === 0),
          values: (_u, splits) => splits.map((i) => (bars[i] ? xLabel(bars[i].bucket) : ''))
        },
        {
          stroke: axis,
          font: FONT,
          size: 56,
          grid: { stroke: grid, width: 1 },
          ticks: { show: false },
          values: (_u, splits) =>
            splits.map((val) => (mode === 'share' ? `${Math.round(val * 100)}%` : formatTokens(val)))
        }
      ],
      series: [
        {},
        ...fillsTopDown.map((fill) => ({ stroke: fill, fill, width: 1, paths: barsPath, points: { show: false } }))
      ],
      plugins: [hoverPlugin(bars, mode, seg)]
    };

    const plot = new uPlot(opts, data, target);
    return () => plot.destroy();
  }, [bars, mode, width, height, series]);

  return (
    <div ref={containerRef} className="trend-chart">
      <div className="trend-chart__head">
        <ul className="trend-chart__legend" aria-label="图例">
          {SEGMENTS.map((s) => (
            <li key={s}>
              <span className="trend-chart__swatch" style={{ background: `var(--seg-${cssVar(s)})` }} aria-hidden="true" />
              {SEGMENT_LABEL[s]}
            </li>
          ))}
        </ul>
        <div className="metric-switch" role="group" aria-label="趋势图显示方式">
          <button type="button" className={mode === 'absolute' ? 'active' : ''} aria-pressed={mode === 'absolute'} onClick={() => setMode('absolute')}>
            总量
          </button>
          <button type="button" className={mode === 'share' ? 'active' : ''} aria-pressed={mode === 'share'} onClick={() => setMode('share')}>
            占比
          </button>
        </div>
      </div>

      <div ref={plotRef} className="trend-chart__plot" role="img" aria-label="Token 用量趋势" />

      {series.floored ? (
        <p className="trend-chart__note">
          极小的段（如缓存写、输出）按最小可见高度显示，悬停查看真实数值。
        </p>
      ) : null}
    </div>
  );
}

/// 段名到 CSS 变量后缀（cacheWrite → cache-write）。
function cssVar(segment: Segment): string {
  return segment.replace(/([A-Z])/g, '-$1').toLowerCase();
}
