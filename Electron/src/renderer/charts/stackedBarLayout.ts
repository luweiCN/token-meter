import type { TrendBucket } from '../../main/overviewRepository.js';

/// 自下而上的堆叠顺序。图例、颜色、tooltip 全部依赖它，改这里就要一起改。
export const SEGMENTS = ['input', 'cacheWrite', 'cacheRead', 'output'] as const;
export type Segment = (typeof SEGMENTS)[number];

export interface Rect {
  bucket: string; segment: Segment;
  x: number; y: number; width: number; height: number;
}

/// 覆盖整根柱子的 hover 区域。逐段接事件会在段间缝隙丢事件，所以由一个横跨整柱的
/// 透明层承接——它的坐标同样属于「算坐标」，由纯函数产出，组件只负责画。
export interface BarSlot { bucket: string; x: number; width: number; }

export interface LayoutBox { width: number; height: number; padding: number; }

export interface StackedBarLayout { rects: Rect[]; slots: BarSlot[]; maxTotal: number; }

export function layoutStackedBars(bars: TrendBucket[], box: LayoutBox): StackedBarLayout {
  const totals = bars.map(b => b.input + b.cacheWrite + b.cacheRead + b.output);
  const maxTotal = Math.max(0, ...totals);

  const slot = bars.length > 0 ? box.width / bars.length : 0;
  const barWidth = Math.max(1, slot - box.padding);
  // 每根柱子（含全零柱）都有一个 hover 覆盖层，否则空日无法 hover 出「0」。
  const slots: BarSlot[] = bars.map((bar, i) => ({ bucket: bar.bucket, x: i * slot, width: barWidth }));

  if (maxTotal === 0 || bars.length === 0) return { rects: [], slots, maxTotal };

  const rects: Rect[] = [];
  bars.forEach((bar, i) => {
    let cursorY = box.height;                       // 自底向上堆
    for (const segment of SEGMENTS) {
      const value = bar[segment];
      if (value <= 0) continue;                     // 零段不产出 rect：0 高的 <rect> 会被画成 1px 的线
      const height = (value / maxTotal) * box.height;
      cursorY -= height;
      rects.push({ bucket: bar.bucket, segment, x: i * slot, y: cursorY, width: barWidth, height });
    }
  });

  return { rects, slots, maxTotal };
}
