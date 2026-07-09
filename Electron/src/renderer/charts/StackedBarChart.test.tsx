// @vitest-environment jsdom

import { render, screen, fireEvent } from '@testing-library/react';
import { describe, it, expect } from 'vitest';
import { StackedBarChart } from './StackedBarChart.js';

const bars = [
  { bucket: '2026-07-09', input: 100, cacheWrite: 0, cacheRead: 0, output: 50 }, // 2 段非零
  { bucket: '2026-07-10', input: 0, cacheWrite: 0, cacheRead: 0, output: 30 }    // 1 段非零
];

describe('StackedBarChart', () => {
  it('draws exactly the non-zero segments plus one hover overlay per bar', () => {
    // 两根柱子之间共 3 个非零段 → 恰好 3 个 segment <rect>，外加每根一个 hover 覆盖层。
    const { container } = render(<StackedBarChart bars={bars} width={840} height={240} />);
    expect(container.querySelectorAll('rect[data-segment]')).toHaveLength(3);
    expect(container.querySelectorAll('rect[data-hover-bucket]')).toHaveLength(2);
  });

  it('shows a tooltip containing the bucket key on hover', () => {
    const { container } = render(<StackedBarChart bars={bars} width={840} height={240} />);
    expect(screen.queryByRole('tooltip')).toBeNull();

    const overlay = container.querySelector('rect[data-hover-bucket="2026-07-09"]')!;
    fireEvent.mouseEnter(overlay);

    const tooltip = screen.getByRole('tooltip');
    expect(tooltip.textContent).toContain('2026-07-09');
  });
});
