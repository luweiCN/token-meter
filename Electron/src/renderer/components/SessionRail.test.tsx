// @vitest-environment jsdom

import { render, screen, fireEvent, waitFor, within } from '@testing-library/react';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { SessionRail } from './SessionRail.js';
import type { ActivityRow, SubagentRow } from '../api.js';

const base: ActivityRow = {
  sessionId: 1, providerId: 'codex', projectName: 'proj', primaryModel: 'gpt-5.5',
  tokensTotal: 1800, firstEventEpochMs: 0, costUsdMicros: 3000, costUnknownEvents: 0,
  msSinceLastEvent: 60_000, isLive: false, subagentCount: 2,
  models: ['gpt-5.5', 'gpt-5.6-sol']
};

const breakdown: SubagentRow[] = [
  { label: 'explorer', tokens: 300, costUsdMicros: 1500, durationMs: 60_000, model: 'm', lastEventMs: 2 },
  { label: 'worker', tokens: 500, costUsdMicros: 2000, durationMs: 60_000, model: 'm', lastEventMs: 1 }
];

beforeEach(() => {
  (window as unknown as { tokenMeter: unknown }).tokenMeter = {
    overview: { subagentBreakdown: vi.fn().mockResolvedValue(breakdown) }
  };
});

describe('SessionRail sub-agent drill-down', () => {
  it('renders the first model as a tag with an overflow count and the merged token total', () => {
    render(<SessionRail sessions={[base]} now={Date.now()} />);
    // lcard 只放一个模型标签；其余模型收进 +N 与 title
    const tag = screen.getByText(/gpt-5\.5 \+1/);
    expect(tag.getAttribute('title')).toContain('gpt-5.6-sol');
    expect(screen.getByText('1.80K')).toBeTruthy();   // formatTokens(1800)，含子代理的合计
  });

  it('maps freshness to the three card states: running / idle / done', () => {
    render(
      <SessionRail
        now={Date.now()}
        sessions={[
          { ...base, sessionId: 1, isLive: true },
          { ...base, sessionId: 2, isLive: false, msSinceLastEvent: 5 * 60_000 },
          { ...base, sessionId: 3, isLive: false, msSinceLastEvent: 30 * 60_000 }
        ]}
      />
    );
    expect(screen.getByText('运行中').closest('.lcard')?.getAttribute('data-state')).toBe('running');
    expect(screen.getByText('等待输入').closest('.lcard')?.getAttribute('data-state')).toBe('idle');
    expect(screen.getByText('已结束').closest('.lcard')?.getAttribute('data-state')).toBe('done');
  });

  it('shows a sub-agent count badge when a session has sub-agents', () => {
    render(<SessionRail sessions={[base]} now={Date.now()} />);
    expect(screen.getByRole('button', { name: /2 个子代理/ })).toBeTruthy();
  });

  it('shows no badge when subagentCount is 0', () => {
    render(<SessionRail sessions={[{ ...base, subagentCount: 0 }]} now={Date.now()} />);
    expect(screen.queryByRole('button', { name: /子代理/ })).toBeNull();
  });

  it('opens a popover listing each sub-agent when the badge is clicked', async () => {
    render(<SessionRail sessions={[base]} now={Date.now()} />);
    fireEvent.click(screen.getByRole('button', { name: /2 个子代理/ }));

    await waitFor(() => expect(screen.getByText('explorer')).toBeTruthy());
    expect(screen.getByText('worker')).toBeTruthy();
    expect(window.tokenMeter.overview.subagentBreakdown).toHaveBeenCalledWith(1);
  });

  it('opens a titled drawer and closes it via the close button', async () => {
    render(<SessionRail sessions={[base]} now={Date.now()} />);
    fireEvent.click(screen.getByRole('button', { name: /2 个子代理/ }));

    await waitFor(() => expect(screen.getByText('explorer')).toBeTruthy());
    // 抽屉头部：标题（会话名）与数量分行；卡片上也有同名项目，限定在 dialog 内断言
    const drawer = screen.getByRole('dialog', { name: '子代理明细' });
    expect(within(drawer).getByText('proj')).toBeTruthy();
    expect(within(drawer).getByText('2 个子代理')).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: '关闭' }));
    // 关闭有 250ms 出场动画，之后才卸载
    await waitFor(() => expect(screen.queryByText('explorer')).toBeNull());
  });

  it('sorts sub-agents (tokens desc by default, re-sortable by name)', async () => {
    render(<SessionRail sessions={[base]} now={Date.now()} />);
    fireEvent.click(screen.getByRole('button', { name: /2 个子代理/ }));
    await waitFor(() => expect(screen.getByText('explorer')).toBeTruthy());

    const order = () => screen.getAllByText(/^(explorer|worker)$/).map(e => e.textContent);
    expect(order()).toEqual(['worker', 'explorer']);  // 默认 token 降序：worker 500 > explorer 300

    fireEvent.click(screen.getByRole('button', { name: '名称' }));
    expect(order()).toEqual(['explorer', 'worker']);  // 名称升序
  });

  it('filters sub-agents by name', async () => {
    render(<SessionRail sessions={[base]} now={Date.now()} />);
    fireEvent.click(screen.getByRole('button', { name: /2 个子代理/ }));
    await waitFor(() => expect(screen.getByText('explorer')).toBeTruthy());

    fireEvent.change(screen.getByPlaceholderText('按名称筛选'), { target: { value: 'work' } });
    expect(screen.queryByText('explorer')).toBeNull();
    expect(screen.getByText('worker')).toBeTruthy();
  });
});
