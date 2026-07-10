import { describe, it, expect } from 'vitest';
import { buildStackedSeries, tooltipRows, axisLabelStride, SEGMENTS } from './trendSeries.js';

// 贴近本机真实比例：cacheRead 独占九成，其余三段是零点几个百分点。
const skew = [
  { bucket: 'a', input: 34_000_000, cacheWrite: 293_213, cacheRead: 800_000_000, output: 3_400_000 },
  { bucket: 'b', input: 0, cacheWrite: 0, cacheRead: 0, output: 0 } // 全零
];

const totalA = SEGMENTS.reduce((s, k) => s + skew[0][k], 0);

describe('buildStackedSeries (absolute)', () => {
  it('stacks bottom-up so the top cumulative equals the real bar total (floor preserves totals)', () => {
    const { cumulative, yMax } = buildStackedSeries(skew, 'absolute');
    expect(cumulative).toHaveLength(4);
    // 顶段累积 = 真实总量：抬高极小段的量是从最大段借来的，总量不变。
    expect(cumulative[3][0]).toBeCloseTo(totalA, -3);
    expect(yMax).toBe(totalA); // 单柱，yMax = 该柱总量
  });

  it('gives every non-zero segment a visible minimum height so none disappears', () => {
    const { cumulative, floored } = buildStackedSeries(skew, 'absolute');
    const floorVal = 0.014 * totalA;
    // cacheWrite 真值 293,213（≈0.035%）被抬到最小可见高度：其带高 = cum[1]-cum[0]。
    const cacheWriteBand = cumulative[1][0] - cumulative[0][0];
    expect(cacheWriteBand).toBeCloseTo(floorVal, -3);
    // output 真值 3.4M 同样低于地板，被抬高。
    const outputBand = cumulative[3][0] - cumulative[2][0];
    expect(outputBand).toBeCloseTo(floorVal, -3);
    // input 34M 高于地板，保持真值，不被抬高。
    expect(cumulative[0][0]).toBe(34_000_000);
    expect(floored).toBe(true);
  });

  it('draws nothing for an all-zero bar', () => {
    const { cumulative } = buildStackedSeries(skew, 'absolute');
    for (const cum of cumulative) expect(cum[1]).toBe(0);
  });

  it('does not floor when segments are already comparable', () => {
    const even = [{ bucket: 'x', input: 100, cacheWrite: 100, cacheRead: 100, output: 100 }];
    const { floored, cumulative } = buildStackedSeries(even, 'absolute');
    expect(floored).toBe(false);
    expect(cumulative[3][0]).toBe(400);
  });
});

describe('buildStackedSeries (share)', () => {
  it('normalizes each non-zero bar to a full-height 100% column', () => {
    const { cumulative, yMax } = buildStackedSeries(skew, 'share');
    expect(yMax).toBe(1);
    expect(cumulative[3][0]).toBeCloseTo(1, 6); // 满高
    expect(cumulative[3][1]).toBe(0); // 全零柱仍是空
  });

  it('still floors small shares so their band is visible', () => {
    const { cumulative } = buildStackedSeries(skew, 'share');
    const cacheWriteShare = cumulative[1][0] - cumulative[0][0];
    expect(cacheWriteShare).toBeGreaterThanOrEqual(0.013); // ≈ FLOOR_FRAC
  });
});

describe('tooltipRows', () => {
  it('reports the real per-segment values in stack order', () => {
    const rows = tooltipRows(skew[0]);
    expect(rows.map((r) => r.segment)).toEqual([...SEGMENTS]);
    expect(rows.map((r) => r.value)).toEqual([34_000_000, 293_213, 800_000_000, 3_400_000]);
    expect(rows[2].label).toBe('缓存读');
  });
});

describe('axisLabelStride', () => {
  it('shows every label up to 12 bars, then thins to ~12 total', () => {
    expect(axisLabelStride(5)).toBe(1);
    expect(axisLabelStride(12)).toBe(1);
    expect(axisLabelStride(13)).toBe(2);
    expect(axisLabelStride(30)).toBe(3);
  });
});
