// @vitest-environment jsdom

import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { SessionRail } from './SessionRail.js';
import type { ActivityRow, SubagentRow } from '../api.js';

const base: ActivityRow = {
  sessionId: 1, providerId: 'codex', projectName: 'proj', primaryModel: 'gpt-5.5',
  tokensTotal: 1800, firstEventEpochMs: 0, costUsdMicros: 3000, costUnknownEvents: 0,
  msSinceLastEvent: 60_000, isLive: false, subagentCount: 2
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

  it('closes the popover on a second click of the same badge', async () => {
    render(<SessionRail sessions={[base]} now={Date.now()} />);
    const badge = screen.getByRole('button', { name: /2 个子代理/ });

    fireEvent.click(badge);
    await waitFor(() => expect(screen.getByText('explorer')).toBeTruthy());
    fireEvent.click(badge);
    await waitFor(() => expect(screen.queryByText('explorer')).toBeNull());
  });
});
