import { describe, it, expect } from 'vitest';
import { buildCalendarGrid } from './calendar.js';

describe('buildCalendarGrid', () => {
  it('starts each column on the same weekday', () => {
    const grid = buildCalendarGrid('2026-07-10', 371);
    for (const col of grid) expect(col.length).toBeLessThanOrEqual(7);
    const firstDays = grid.filter(c => c.length === 7).map(c => new Date(c[0].date).getDay());
    expect(new Set(firstDays).size).toBe(1);
  });

  it('ends on the requested last day', () => {
    const grid = buildCalendarGrid('2026-07-10', 371);
    const flat = grid.flat();
    expect(flat[flat.length - 1].date).toBe('2026-07-10');
  });

  it('covers exactly the requested number of days', () => {
    expect(buildCalendarGrid('2026-07-10', 371).flat()).toHaveLength(371);
  });

  it('handles a DST-free timezone shift without dropping or duplicating a day', () => {
    // 用本地日期字符串推进，不用 epoch 加 86400000——后者在 DST 切换日会少一天或多一天。
    const dates = buildCalendarGrid('2026-07-10', 371).flat().map(d => d.date);
    expect(new Set(dates).size).toBe(371);
  });
});
