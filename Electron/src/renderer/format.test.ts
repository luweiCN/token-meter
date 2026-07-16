import { describe, expect, it } from 'vitest';

import { formatTokens } from './format.js';

describe('formatTokens', () => {
  it('uses K/M/B for aggregated (multi-day) values', () => {
    expect(formatTokens(775)).toBe('775');
    expect(formatTokens(3_400)).toBe('3.40K');
    expect(formatTokens(521_319_916)).toBe('521.32M');
    expect(formatTokens(2_398_499_879)).toBe('2.40B');
  });

  it('locks daily-scale values to the M unit so million-level changes stay visible', () => {
    // 单日数字不升 B：2.4B 写成 2398.5M，每涨一百万都看得见（用户裁定）。
    expect(formatTokens(2_398_499_879, true)).toBe('2398.5M');
    expect(formatTokens(521_319_916, true)).toBe('521.32M');   // 未过 1B 时格式不变
    expect(formatTokens(3_400, true)).toBe('3.40K');
  });
});
