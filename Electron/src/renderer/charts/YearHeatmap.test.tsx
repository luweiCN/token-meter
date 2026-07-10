// @vitest-environment jsdom

import { render, screen, fireEvent } from '@testing-library/react';
import { describe, it, expect } from 'vitest';
import { YearHeatmap } from './YearHeatmap.js';

const days = [
  { date: '2026-07-10', tokens: 1_000_000_000, costUsdMicros: 5_000_000, sessions: 3, events: 40 }, // 峰值 → level 4
  { date: '2026-07-09', tokens: 0, costUsdMicros: 0, sessions: 0, events: 0 }               // 零值 → level 0
];

describe('YearHeatmap', () => {
  it('renders one cell per day in the window, with levels from logBucket', () => {
    const { container } = render(<YearHeatmap days={days} lastDay="2026-07-10" />);
    expect(container.querySelectorAll('[data-date]')).toHaveLength(371);

    // 有数据但为零的一天是 level 0，不是空洞
    expect(container.querySelector('[data-date="2026-07-09"]')!.getAttribute('data-level')).toBe('0');
    // 峰值那天是最高档
    expect(container.querySelector('[data-date="2026-07-10"]')!.getAttribute('data-level')).toBe('4');
    // 窗口内没有数据的日子由网格补成 level 0（repository 不为空日造行）
    expect(container.querySelector('[data-date="2026-01-01"]')!.getAttribute('data-level')).toBe('0');
  });

  it('shows a card with the day\'s total tokens on hover, regardless of the selected metric', () => {
    const { container } = render(<YearHeatmap days={days} lastDay="2026-07-10" metric="events" />);
    expect(screen.queryByRole('tooltip')).toBeNull();
    fireEvent.mouseOver(container.querySelector('[data-date="2026-07-10"]')!);

    const card = screen.getByRole('tooltip');
    expect(card.textContent).toContain('2026-07-10');
    expect(card.textContent).toContain('1.00B'); // formatTokens(1_000_000_000)
  });

  it('hides the hover card again once the mouse leaves, when nothing is pinned', () => {
    const { container } = render(<YearHeatmap days={days} lastDay="2026-07-10" />);
    fireEvent.mouseOver(container.querySelector('[data-date="2026-07-10"]')!);
    expect(screen.queryByRole('tooltip')).not.toBeNull();
    fireEvent.mouseLeave(container.querySelector('.year-heatmap__grid')!);
    expect(screen.queryByRole('tooltip')).toBeNull();
  });

  it('pins the card on click so it survives mouse leave, and shows a close button', () => {
    const { container } = render(<YearHeatmap days={days} lastDay="2026-07-10" />);
    fireEvent.click(container.querySelector('[data-date="2026-07-10"]')!);
    fireEvent.mouseLeave(container.querySelector('.year-heatmap__grid')!);

    const card = screen.getByRole('tooltip');
    expect(card.textContent).toContain('2026-07-10');
    expect(screen.queryByRole('button', { name: '关闭' })).not.toBeNull();
  });

  it('unpins on a second click of the same day, or via the close button', () => {
    const { container } = render(<YearHeatmap days={days} lastDay="2026-07-10" />);
    const cell = container.querySelector('[data-date="2026-07-10"]')!;

    fireEvent.click(cell);
    fireEvent.click(cell);
    fireEvent.mouseLeave(container.querySelector('.year-heatmap__grid')!);
    expect(screen.queryByRole('tooltip')).toBeNull();

    fireEvent.click(cell);
    fireEvent.click(screen.getByRole('button', { name: '关闭' }));
    expect(screen.queryByRole('tooltip')).toBeNull();
  });
});
