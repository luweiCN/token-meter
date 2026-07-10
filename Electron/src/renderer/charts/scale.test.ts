import { describe, it, expect } from 'vitest';
import { logBucket, HEATMAP_LEVELS } from './scale.js';

describe('logBucket', () => {
  it('maps zero to level 0 and the max to the top level', () => {
    expect(logBucket(0, 1000)).toBe(0);
    expect(logBucket(1000, 1000)).toBe(HEATMAP_LEVELS - 1);
  });

  it('separates a long tail that a linear scale would flatten', () => {
    // 中位数 1000、峰值 100000。线性映射下 1000 会落在 level 0（1000/100000 = 1%）。
    const linear = Math.floor((1000 / 100000) * (HEATMAP_LEVELS - 1));
    expect(linear).toBe(0);
    expect(logBucket(1000, 100000)).toBeGreaterThan(0);
  });

  it('is monotonic', () => {
    let prev = -1;
    for (const v of [0, 1, 10, 100, 1000, 10000, 100000]) {
      const b = logBucket(v, 100000);
      expect(b).toBeGreaterThanOrEqual(prev);
      prev = b;
    }
  });

  it('never divides by zero when every day is empty', () => {
    expect(logBucket(0, 0)).toBe(0);
  });

  it('clamps a value above max rather than overflowing the palette', () => {
    expect(logBucket(2000, 1000)).toBe(HEATMAP_LEVELS - 1);
  });
});
