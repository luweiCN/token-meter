import { describe, expect, it } from 'vitest';
import { TOKEN_HEATMAP_BANDS, tokenHeatmapBand } from './tokenHeatmap.js';

describe('fixed token heatmap bands', () => {
  it('uses the agreed boundaries, including the lower edge of each band', () => {
    const cases = [
      [-1, 0], [0, 0], [1, 1], [99_999_999, 1], [100_000_000, 2],
      [299_999_999, 2], [300_000_000, 3], [599_999_999, 3],
      [600_000_000, 4], [999_999_999, 4], [1_000_000_000, 5],
      [1_999_999_999, 5], [2_000_000_000, 6], [4_000_000_000, 6],
    ];
    for (const [value, expected] of cases) expect(tokenHeatmapBand(value).level).toBe(expected);
  });

  it('derives all seven labels from the shared thresholds', () => {
    expect(TOKEN_HEATMAP_BANDS.map(band => band.rangeLabel)).toEqual([
      '0 Token', '非零，不足1亿 Token', '1亿至不足3亿 Token', '3亿至不足6亿 Token',
      '6亿至不足10亿 Token', '10亿至不足20亿 Token', '20亿及以上 Token',
    ]);
    expect(TOKEN_HEATMAP_BANDS.every(band => /^#[\da-f]{6}$/i.test(band.dark) && /^#[\da-f]{6}$/i.test(band.light))).toBe(true);
  });
});
