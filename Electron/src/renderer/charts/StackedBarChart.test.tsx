// @vitest-environment jsdom

import { render, screen, fireEvent, within } from '@testing-library/react';
import { describe, it, expect } from 'vitest';
import { StackedBarChart } from './StackedBarChart.js';

// jsdom 没有 canvas，uPlot 不会构建（组件里有 getContext 护栏），所以这里断言的是
// 用户可见的外壳：无障碍标签、四段图例、总量/占比切换、以及被压扁段的说明标注。
// 画布内实际画成什么样，由真机截图验证（uPlot 的内部不该在这里测）。
const skew = [
  { bucket: '2026-07-09', input: 34_000_000, cacheWrite: 293_213, cacheRead: 800_000_000, output: 3_400_000 },
  { bucket: '2026-07-10', input: 0, cacheWrite: 0, cacheRead: 0, output: 0 }
];

describe('StackedBarChart', () => {
  it('exposes the accessible chart region and a full four-segment legend', () => {
    render(<StackedBarChart bars={skew} />);
    expect(screen.getByLabelText('Token 用量趋势')).toBeTruthy();
    const legend = screen.getByLabelText('图例');
    for (const label of ['输入', '缓存写', '缓存读', '输出']) {
      expect(within(legend).getByText(label)).toBeTruthy();
    }
  });

  it('lets the user switch between absolute and share views', () => {
    render(<StackedBarChart bars={skew} />);
    const abs = screen.getByRole('button', { name: '总量' });
    const share = screen.getByRole('button', { name: '占比' });
    expect(abs.getAttribute('aria-pressed')).toBe('true');

    fireEvent.click(share);
    expect(share.getAttribute('aria-pressed')).toBe('true');
    expect(abs.getAttribute('aria-pressed')).toBe('false');
  });

  it('warns when tiny segments had to be floored to stay visible', () => {
    render(<StackedBarChart bars={skew} />);
    expect(screen.getByText(/按最小可见高度显示/)).toBeTruthy();
  });

  it('omits the floor note when segments are already comparable', () => {
    const even = [{ bucket: 'x', input: 100, cacheWrite: 100, cacheRead: 100, output: 100 }];
    render(<StackedBarChart bars={even} />);
    expect(screen.queryByText(/按最小可见高度显示/)).toBeNull();
  });
});
