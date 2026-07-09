import { describe, it, expect } from 'vitest';
import { allowedGranularities, isAllowed, barCount, type Granularity } from './granularity.js';

describe('allowedGranularities', () => {
  it('opens hour only for ranges of at most 2 days', () => {
    expect(allowedGranularities('2026-07-09', '2026-07-10')).toContain('hour');
    expect(allowedGranularities('2026-07-08', '2026-07-10')).not.toContain('hour');
  });

  it('opens month only for ranges of at least 90 days', () => {
    expect(allowedGranularities('2026-04-11', '2026-07-10')).toContain('month');
    expect(allowedGranularities('2026-04-12', '2026-07-10')).not.toContain('month');
  });

  it('drops day once it would exceed the readable bar ceiling', () => {
    expect(allowedGranularities('2026-07-10', '2026-07-10')).toContain('day');
    expect(allowedGranularities('2020-01-01', '2026-07-10')).not.toContain('day');  // 2383 根柱子
  });

  it('always offers at least one granularity, however wide the range', () => {
    // 这条与 barCount 的上限测试互为约束：任何范围都得有一个能画的粒度，
    // 且每个被放行的粒度都得画得下。两条一起把「约束表」钉死。
    for (const [from, to] of [['2026-07-10','2026-07-10'], ['2026-07-08','2026-07-10'],
                              ['2026-06-11','2026-07-10'], ['2020-01-01','2026-07-10']] as const) {
      expect(allowedGranularities(from, to).length).toBeGreaterThan(0);
    }
  });

  it('rejects an inverted range rather than silently swapping it', () => {
    expect(() => allowedGranularities('2026-07-10', '2026-07-09')).toThrow(/from.*after.*to/i);
  });
});

describe('barCount', () => {
  it('counts inclusive days', () => {
    expect(barCount('2026-07-10', '2026-07-10', 'day')).toBe(1);
    expect(barCount('2026-07-08', '2026-07-10', 'day')).toBe(3);
  });

  it('counts hours across a 2-day span', () => {
    expect(barCount('2026-07-09', '2026-07-10', 'hour')).toBe(48);
  });

  it('never exceeds the readable ceiling for an allowed combination', () => {
    // 任何被 allowedGranularities 放行的组合，柱子数都必须画得下。
    // 这条把「约束表」与「可读性上限」绑在一起：改了任何一个，另一个会红。
    const ranges: Array<[string, string]> = [
      ['2026-07-09', '2026-07-10'],  // 2 天
      ['2026-06-11', '2026-07-10'],  // 30 天
      ['2026-04-11', '2026-07-10'],  // 91 天
      ['2020-01-01', '2026-07-10']   // 多年
    ];
    for (const [from, to] of ranges) {
      for (const g of allowedGranularities(from, to)) {
        expect(barCount(from, to, g)).toBeLessThanOrEqual(120);
      }
    }
  });
});

describe('isAllowed', () => {
  it('rejects hour over a 30-day range', () => {
    expect(isAllowed('2026-06-11', '2026-07-10', 'hour')).toBe(false);
  });
});
