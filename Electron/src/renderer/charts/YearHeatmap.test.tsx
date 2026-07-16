// @vitest-environment jsdom

import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { YearHeatmap } from './YearHeatmap.js';

const days = [
  { date: '2026-07-10', tokens: 1_000_000_000, costUsdMicros: 5_000_000, sessions: 3, events: 40 }, // 峰值 → level 4
  { date: '2026-07-09', tokens: 0, costUsdMicros: 0, sessions: 0, events: 0 }               // 零值 → level 0
];

const breakdown = [
  { model: 'claude-fable-5', tokens: 320_690_000, costUsdMicros: 3_000_000, sessions: 5, events: 120 },
  { model: 'gpt-5.5', tokens: 100_220_000, costUsdMicros: 2_000_000, sessions: 2, events: 30 }
];

const projectBreakdown = [
  { project: 'token-meter', tokens: 200_000_000, costUsdMicros: 2_500_000, sessions: 4, events: 90 },
  { project: 'herdr', tokens: 120_000_000, costUsdMicros: 1_500_000, sessions: 3, events: 60 }
];

beforeEach(() => {
  (window as unknown as { tokenMeter: unknown }).tokenMeter = {
    overview: {
      dayModelBreakdown: vi.fn().mockResolvedValue(breakdown),
      dayProjectBreakdown: vi.fn().mockResolvedValue(projectBreakdown)
    }
  };
});

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

  it('renders the 少→多 legend with all five levels', () => {
    const { container } = render(<YearHeatmap days={days} lastDay="2026-07-10" />);

    expect(screen.getByText('少')).toBeTruthy();
    expect(screen.getByText('多')).toBeTruthy();
    expect(container.querySelectorAll('.hscale i')).toHaveLength(5);
  });

  it('shows all four day totals on hover (Token first), regardless of the selected metric', () => {
    const { container } = render(<YearHeatmap days={days} lastDay="2026-07-10" metric="events" />);
    expect(screen.queryByRole('tooltip')).toBeNull();
    fireEvent.mouseOver(container.querySelector('[data-date="2026-07-10"]')!);

    const card = screen.getByRole('tooltip');
    expect(card.textContent).toContain('2026-07-10');
    expect(card.textContent).toContain('1000.0M'); // 单日锁 M 单位（不升 B），百万级变化可见
    expect(card.textContent).toContain('$5.00'); // 花费
    expect(card.textContent).toContain('40');    // 事件（第四栏，曾经缺失）
    // Token 栏排在花费栏前面（token 首位、花费第二位）
    const labels = Array.from(card.querySelectorAll('.dp-stats span')).map(el => el.textContent);
    expect(labels).toEqual(['Token', '花费', '会话', '事件']);
  });

  it('hides the hover card again once the mouse leaves', () => {
    const { container } = render(<YearHeatmap days={days} lastDay="2026-07-10" />);
    fireEvent.mouseOver(container.querySelector('[data-date="2026-07-10"]')!);
    expect(screen.queryByRole('tooltip')).not.toBeNull();
    fireEvent.mouseLeave(container.querySelector('.year-heatmap__grid')!);
    expect(screen.queryByRole('tooltip')).toBeNull();
  });

  it('loads the per-model breakdown for the hovered day and lists it in the card', async () => {
    const { container } = render(<YearHeatmap days={days} lastDay="2026-07-10" />);
    fireEvent.mouseOver(container.querySelector('[data-date="2026-07-10"]')!);

    await waitFor(() => expect(screen.getByText('claude-fable-5')).toBeTruthy());
    expect(screen.getByText('320.69M')).toBeTruthy(); // formatTokens(320_690_000)
    expect(window.tokenMeter.overview.dayModelBreakdown).toHaveBeenCalledWith('2026-07-10');
  });

  it('shows the per-model values in the currently selected metric, not always tokens', async () => {
    const { container } = render(<YearHeatmap days={days} lastDay="2026-07-10" metric="costUsdMicros" />);
    fireEvent.mouseOver(container.querySelector('[data-date="2026-07-10"]')!);

    await waitFor(() => expect(screen.getByText('claude-fable-5')).toBeTruthy());
    // 切到成本：模型行显示各自成本，而不是 token 数
    expect(screen.getByText('$3.00')).toBeTruthy();
    expect(screen.queryByText('320.69M')).toBeNull();
  });

  it('switches the breakdown to projects for the sessions/events metrics', async () => {
    // 「按模型数会话/事件」没有意义（一个会话可用多个模型）——这两个指标按项目列明细。
    const { container } = render(<YearHeatmap days={days} lastDay="2026-07-10" metric="sessions" />);
    fireEvent.mouseOver(container.querySelector('[data-date="2026-07-10"]')!);

    await waitFor(() => expect(screen.getByText('token-meter')).toBeTruthy());
    expect(screen.getByText('herdr')).toBeTruthy();
    expect(screen.queryByText('claude-fable-5')).toBeNull();
    expect(window.tokenMeter.overview.dayProjectBreakdown).toHaveBeenCalledWith('2026-07-10');
    expect(window.tokenMeter.overview.dayModelBreakdown).not.toHaveBeenCalled();
  });

  it('serves repeat hovers from the per-day cache instead of refetching', async () => {
    const { container } = render(<YearHeatmap days={days} lastDay="2026-07-10" />);
    const peak = container.querySelector('[data-date="2026-07-10"]')!;

    fireEvent.mouseOver(peak);
    await waitFor(() => expect(screen.getByText('claude-fable-5')).toBeTruthy());
    fireEvent.mouseOver(container.querySelector('[data-date="2026-07-09"]')!);
    fireEvent.mouseOver(peak);
    await waitFor(() => expect(screen.getByText('claude-fable-5')).toBeTruthy());

    // 两个不同日期各取一次；回到第一天吃缓存，不再打第三次
    expect(window.tokenMeter.overview.dayModelBreakdown).toHaveBeenCalledTimes(2);
  });
});
