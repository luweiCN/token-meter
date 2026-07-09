// @vitest-environment jsdom

import { render, screen, fireEvent } from '@testing-library/react';
import { describe, it, expect, vi } from 'vitest';
import { YearHeatmap } from './YearHeatmap.js';

const days = [
  { date: '2026-07-10', tokens: 1_000_000_000, costUsdMicros: 0, sessions: 0, events: 0 }, // 峰值 → level 4
  { date: '2026-07-09', tokens: 0, costUsdMicros: 0, sessions: 0, events: 0 }               // 零值 → level 0
];

describe('YearHeatmap', () => {
  it('renders one cell per day in the window, with levels from logBucket', () => {
    const { container } = render(
      <YearHeatmap days={days} lastDay="2026-07-10" onSelectDate={() => {}} />
    );
    expect(container.querySelectorAll('[data-date]')).toHaveLength(371);

    // 有数据但为零的一天是 level 0，不是空洞
    expect(container.querySelector('[data-date="2026-07-09"]')!.getAttribute('data-level')).toBe('0');
    // 峰值那天是最高档
    expect(container.querySelector('[data-date="2026-07-10"]')!.getAttribute('data-level')).toBe('4');
    // 窗口内没有数据的日子由网格补成 level 0（repository 不为空日造行）
    expect(container.querySelector('[data-date="2026-01-01"]')!.getAttribute('data-level')).toBe('0');
  });

  it('calls onSelectDate with the clicked cell date', () => {
    const onSelectDate = vi.fn();
    const { container } = render(
      <YearHeatmap days={days} lastDay="2026-07-10" onSelectDate={onSelectDate} />
    );
    fireEvent.click(container.querySelector('[data-date="2026-07-10"]')!);
    expect(onSelectDate).toHaveBeenCalledWith('2026-07-10');
  });

  it('shows a tooltip with the hovered cell date via one delegated listener', () => {
    const { container } = render(
      <YearHeatmap days={days} lastDay="2026-07-10" onSelectDate={() => {}} />
    );
    expect(screen.queryByRole('tooltip')).toBeNull();
    fireEvent.mouseOver(container.querySelector('[data-date="2026-07-10"]')!);
    expect(screen.getByRole('tooltip').textContent).toContain('2026-07-10');
  });
});
