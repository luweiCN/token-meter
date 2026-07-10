import type { TrendBucket } from '../../main/overviewRepository.js';

/// 自下而上的堆叠顺序。图例、颜色、tooltip 全部依赖它，改这里就要一起改。
export const SEGMENTS = ['input', 'cacheWrite', 'cacheRead', 'output'] as const;
export type Segment = (typeof SEGMENTS)[number];

export const SEGMENT_LABEL: Record<Segment, string> = {
  input: '输入',
  cacheWrite: '缓存写',
  cacheRead: '缓存读',
  output: '输出'
};

export type TrendMode = 'absolute' | 'share';

/// 每段至少占 y 轴量程的这一比例（≈3px @ 212px 画布）。本机数据里 cacheRead 长期
/// 占单柱的 76%–96%，input/cacheWrite/output 线性映射后是零点几像素——直接消失。
/// 归一化（占比图）救不了它：cacheRead 在【每一根】柱子里都是九成，占比图里其余三段
/// 依旧是发丝。真正让它们可见的，是给每个非零段一个最小可见高度（下方有说明标注）。
const FLOOR_FRAC = 0.014;

export interface StackedSeries {
  /// x 索引 0..n-1。
  x: number[];
  /// 每段一条累积数组（自底向上），第 i 条 = 本段及其下所有段的显示值之和。
  /// uPlot 以「从 0 基线画实心柱、后画覆盖先画」的方式叠色，故需要累积值。
  cumulative: number[][];
  /// y 轴上界：absolute 取最高柱的显示总量；share 恒为 1。
  yMax: number;
  /// 是否有任何段被抬到了最小可见高度（决定要不要显示「按最小高度显示」的说明）。
  floored: boolean;
}

/// 把趋势桶转成 uPlot 可直接堆叠的累积序列。
///
/// 关键动作是「最小可见高度」：对每根柱子，把非零且非最大的段抬到 floorVal，
/// 抬高的量从该柱最大的段（本机数据里恒为 cacheRead）借出，从而【保持柱子总量不变】——
/// tooltip 里展示的仍是真实数值，图上只是保证极小的段也画得出来。
export function buildStackedSeries(bars: TrendBucket[], mode: TrendMode): StackedSeries {
  const x = bars.map((_, i) => i);
  const realTotals = bars.map((b) => SEGMENTS.reduce((s, k) => s + b[k], 0));
  const yMaxReal = Math.max(0, ...realTotals);

  const display: number[][] = SEGMENTS.map(() => new Array<number>(bars.length).fill(0));
  let floored = false;

  bars.forEach((bar, bi) => {
    const total = realTotals[bi];
    if (total <= 0) return; // 全零柱：留全零，不画（也不造假的最小段）

    const ref = mode === 'share' ? total : yMaxReal;
    const floorVal = FLOOR_FRAC * ref;

    // 借出源 = 本柱最大的段。
    let maxIdx = 0;
    SEGMENTS.forEach((k, si) => {
      if (bar[k] > bar[SEGMENTS[maxIdx]]) maxIdx = si;
    });

    const vals = SEGMENTS.map((k) => bar[k]);
    let added = 0;
    SEGMENTS.forEach((_k, si) => {
      if (si === maxIdx || vals[si] <= 0) return;
      if (vals[si] < floorVal) {
        added += floorVal - vals[si];
        vals[si] = floorVal;
        floored = true;
      }
    });

    // 从最大段借出，保证它仍不低于量程的 10%（本机数据永远够借；这是边界护栏）。
    const maxBorrow = Math.max(0, vals[maxIdx] - 0.1 * ref);
    const scale = added > maxBorrow && added > 0 ? maxBorrow / added : 1;
    if (scale < 1) {
      SEGMENTS.forEach((k, si) => {
        if (si === maxIdx || bar[k] <= 0) return;
        vals[si] = bar[k] + (vals[si] - bar[k]) * scale;
      });
      added *= scale;
    }
    vals[maxIdx] -= added;

    if (mode === 'share') {
      const sum = vals.reduce((s, v) => s + v, 0) || 1;
      SEGMENTS.forEach((_k, si) => {
        display[si][bi] = vals[si] / sum;
      });
    } else {
      SEGMENTS.forEach((_k, si) => {
        display[si][bi] = vals[si];
      });
    }
  });

  const cumulative: number[][] = [];
  const running = new Array<number>(bars.length).fill(0);
  SEGMENTS.forEach((_k, si) => {
    for (let bi = 0; bi < bars.length; bi++) running[bi] += display[si][bi];
    cumulative.push(running.slice());
  });

  return { x, cumulative, yMax: mode === 'share' ? 1 : yMaxReal, floored };
}

export interface TooltipRow {
  segment: Segment;
  label: string;
  value: number;
}

/// tooltip 逐段展示【真实】数值（不是抬高后的显示值）。
export function tooltipRows(bar: TrendBucket): TooltipRow[] {
  return SEGMENTS.map((segment) => ({ segment, label: SEGMENT_LABEL[segment], value: bar[segment] }));
}

/// X 轴标签抽稀：超过 12 根时每 ceil(n/12) 根显示一个，避免标签叠字。
export function axisLabelStride(count: number): number {
  return count > 12 ? Math.ceil(count / 12) : 1;
}
