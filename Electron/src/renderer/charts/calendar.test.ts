import { describe, it, expect } from 'vitest';
import { buildCalendarGrid } from './calendar.js';

describe('buildCalendarGrid', () => {
  it('every column is exactly 7 rows, real or padded — a clean rectangle', () => {
    const grid = buildCalendarGrid('2026-07-10', 371);
    for (const col of grid) expect(col).toHaveLength(7);
  });

  it('pads the last column with nulls past lastDay, out to Saturday', () => {
    // 2026-07-10（末日）是周五（getDay()=5），末列到周四为止都是真实日期，
    // 第 6 行（周六，也就是明天）必须是占位格——不补的话末列比其他列矮一截，
    // 整张热力图右下角缺一块，不是长方形。
    const grid = buildCalendarGrid('2026-07-10', 371);
    const last = grid[grid.length - 1];
    expect(last.slice(0, 6).every(c => c.date !== null)).toBe(true);
    expect(last[5].date).toBe('2026-07-10');
    expect(last[6].date).toBeNull();
  });

  it('places every real cell in the row matching its actual weekday', () => {
    // 这是「第一列位置摆错了」那个 bug 的钉子：起始日若不是周日，首列前几行
    // 必须是占位格，真实日期得落在它自己的星期行上，不能从数组下标 0 起堆叠。
    const grid = buildCalendarGrid('2026-07-10', 371);
    for (const col of grid) {
      col.forEach((cell, rowIndex) => {
        if (cell.date === null) return;
        const [y, m, d] = cell.date.split('-').map(Number);
        expect(new Date(y, m - 1, d).getDay()).toBe(rowIndex);
      });
    }
  });

  it('pads the first column with nulls up to the start date\'s weekday', () => {
    // 2025-07-05（371 天窗口的起始日）是周六（getDay()=6），前 6 行必须是占位格。
    const grid = buildCalendarGrid('2026-07-10', 371);
    const first = grid[0];
    expect(first.slice(0, 6).every(c => c.date === null)).toBe(true);
    expect(first[6].date).toBe('2025-07-05');
  });

  it('ends on the requested last day', () => {
    const grid = buildCalendarGrid('2026-07-10', 371);
    const flat = grid.flat().filter(c => c.date !== null);
    expect(flat[flat.length - 1].date).toBe('2026-07-10');
  });

  it('covers exactly the requested number of real days, padding aside', () => {
    const real = buildCalendarGrid('2026-07-10', 371).flat().filter(c => c.date !== null);
    expect(real).toHaveLength(371);
  });

  it('handles a DST-free timezone shift without dropping or duplicating a day', () => {
    // 用本地日期字符串推进，不用 epoch 加 86400000——后者在 DST 切换日会少一天或多一天。
    const dates = buildCalendarGrid('2026-07-10', 371).flat()
      .map(d => d.date).filter((d): d is string => d !== null);
    expect(new Set(dates).size).toBe(371);
  });
});
