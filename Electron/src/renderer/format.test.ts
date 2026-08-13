import { describe, expect, it } from 'vitest';

import { formatTokens, formatUsdMicros, setMoneyDisplay } from './format.js';

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

describe('formatUsdMicros money display', () => {
  it('defaults to USD until settings arrive', () => {
    expect(formatUsdMicros(1_500_000)).toBe('$1.50');
  });

  it('converts to CNY with the injected daily rate', () => {
    setMoneyDisplay('cny', 6.76);
    expect(formatUsdMicros(1_500_000)).toBe('¥10.14');
  });

  it('switches back to USD through the same formatter', () => {
    setMoneyDisplay('usd', 6.76);
    expect(formatUsdMicros(1_500_000)).toBe('$1.50');
  });
});
