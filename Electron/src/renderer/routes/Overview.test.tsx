// @vitest-environment jsdom

import { render, screen, fireEvent, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Mock } from 'vitest';

import { Overview } from './Overview.js';
import type { OverviewPayload, ScanProgress } from '../api.js';

interface TokenMeterApi {
  overview: {
    query: Mock<() => Promise<OverviewPayload>>;
    dayModelBreakdown: Mock<(date: string) => Promise<unknown[]>>;
    onInvalidate: Mock<(cb: () => void) => () => void>;
    onSessionEvent: Mock<(cb: (event: unknown) => void) => () => void>;
  };
  index: {
    startFullReindex: Mock<() => Promise<unknown>>;
    onScanProgress: Mock<(cb: (p: ScanProgress) => void) => () => void>;
  };
  settings: {
    get: Mock<() => Promise<{ providerOverrides: Array<{ providerId: string; displayName?: string }> }>>;
  };
}

let api: TokenMeterApi;
let scanProgressCb: ((p: ScanProgress) => void) | null = null;
let invalidateCb: (() => void) | null = null;
let sessionEventCb: ((event: unknown) => void) | null = null;

function trendSeries(granularity: 'day' | 'week' | 'month') {
  return {
    granularity,
    from: '2026-07-09',
    to: '2026-07-10',
    buckets: ['2026-07-09', '2026-07-10'],
    rows: [
      { bucket: '2026-07-09', providerId: 'claude-code', tokens: 1000, costUsdMicros: 5000, sessions: 2 },
      { bucket: '2026-07-10', providerId: 'codex', tokens: 400, costUsdMicros: 2000, sessions: 1 }
    ]
  };
}

const readyPayload: OverviewPayload = {
  dataState: 'ready',
  today: '2026-07-10',
  kpis: {
    todayTokens: 12345,
    yesterdayTokens: 6789,
    todaySessions: 3,
    todayCostUsdMicros: 1_500_000,
    todayCostUnknownEvents: 4,
    monthTokens: 8_200_000,
    monthCostUsdMicros: 9_000_000,
    monthCostUnknownEvents: 4,
    weekTokens: 2_100_000,
    weekCostUsdMicros: 2_400_000,
    weekCostUnknownEvents: 0,
    totalTokens: 28_400_000,
    totalCostUsdMicros: 31_247_000_000,
    totalCostUnknownEvents: 4,
    totalEvents: 217_483,
    totalSessions: 3942,
    firstDate: '2025-02-03'
  },
  trend: [
    { bucket: '2026-07-09', input: 100, cacheWrite: 8, cacheRead: 900, output: 10 },
    { bucket: '2026-07-10', input: 200, cacheWrite: 0, cacheRead: 0, output: 20 }
  ],
  trendRange: { from: '2026-06-11', to: '2026-07-10', granularity: 'day' },
  agentTrend: { day: trendSeries('day'), week: trendSeries('week'), month: trendSeries('month') },
  heatmap: [{ date: '2026-07-10', tokens: 220, costUsdMicros: 100, sessions: 1, events: 2 }],
  heatmapLastDay: '2026-07-10',
  heatmapDays: 371,
  modelRanking: [
    { model: 'claude-fable-5', tokens: 1000, costUsdMicros: 500_000, costUnknownEvents: 0, providerId: 'claude-code' },
    { model: 'unpriced', tokens: 50, costUsdMicros: 0, costUnknownEvents: 4, providerId: null }
  ],
  sessionRail: [
    {
      sessionId: 1,
      sourceKind: 'claude_jsonl',
      sourceSessionKey: 'sess-1',
      providerId: 'claude-code',
      projectName: 'token-meter',
      primaryModel: 'claude-fable-5',
      tokensTotal: 110,
      firstEventEpochMs: 1,
      costUsdMicros: 1000,
      costUnknownEvents: 0,
      msSinceLastEvent: 30_000,
      isLive: true,
      isBlocked: false,
      subagentCount: 0,
      models: ['claude-fable-5']
    }
  ]
};

function install(): TokenMeterApi {
  scanProgressCb = null;
  invalidateCb = null;
  sessionEventCb = null;
  const value: TokenMeterApi = {
    overview: {
      query: vi.fn<() => Promise<OverviewPayload>>(),
      dayModelBreakdown: vi.fn<(date: string) => Promise<unknown[]>>().mockResolvedValue([
        { model: 'claude-fable-5', tokens: 180, costUsdMicros: 90 }
      ]),
      onInvalidate: vi.fn((cb: () => void) => {
        invalidateCb = cb;
        return () => { invalidateCb = null; };
      }),
      onSessionEvent: vi.fn((cb: (event: unknown) => void) => {
        sessionEventCb = cb;
        return () => { sessionEventCb = null; };
      })
    },
    index: {
      startFullReindex: vi.fn<() => Promise<unknown>>().mockResolvedValue({ ok: true }),
      onScanProgress: vi.fn((cb: (p: ScanProgress) => void) => {
        scanProgressCb = cb;
        return () => { scanProgressCb = null; };
      })
    },
    settings: {
      get: vi.fn().mockResolvedValue({ providerOverrides: [] })
    }
  };
  Object.defineProperty(window, 'tokenMeter', { configurable: true, value });
  return value;
}

beforeEach(() => {
  document.body.innerHTML = '<div id="root"></div>';
  api = install();
});

afterEach(() => {
  vi.restoreAllMocks();
  Reflect.deleteProperty(window, 'tokenMeter');
});

describe('Overview (ready)', () => {
  beforeEach(() => { api.overview.query.mockResolvedValue(readyPayload); });

  it('flips a session card state in place when a hooks event arrives, without re-querying', async () => {
    const { act } = await import('@testing-library/react');
    render(<Overview />);
    // fixture 会话是 isLive（「运行中」），等首屏渲染完成。
    await waitFor(() => expect(screen.getByText('运行中')).toBeTruthy());
    const queriesBefore = api.overview.query.mock.calls.length;

    // blocked 事件 → 卡片就地变「阻塞」，不触发新查询。
    act(() => sessionEventCb?.({ sourceKind: 'claude_jsonl', sessionKey: 'sess-1', event: 'blocked' }));
    expect(screen.getByText('阻塞')).toBeTruthy();

    // stop 事件 → 熄灭。最近 30 秒有活动的非 live 会话按时间推断显示「等待输入」
    //（与随后全量刷新的口径一致），15 分钟后才是「已结束」。
    act(() => sessionEventCb?.({ sourceKind: 'claude_jsonl', sessionKey: 'sess-1', event: 'stop' }));
    expect(screen.getByText('等待输入')).toBeTruthy();
    expect(screen.queryByText('运行中')).toBeNull();

    // 对不上的会话（新会话）不动任何卡片、也不查询——等全量刷新自然出现。
    act(() => sessionEventCb?.({ sourceKind: 'codex_jsonl', sessionKey: 'unknown', event: 'start' }));
    expect(api.overview.query.mock.calls.length).toBe(queriesBefore);
  });

  it('renders provider aliases from settings in the model ranking', async () => {
    api.settings.get.mockResolvedValue({
      providerOverrides: [{ providerId: 'claude-code', displayName: '克劳德' }]
    });
    render(<Overview />);
    // 排行的 provider 列与趋势图例都应显示别名而不是内置名。
    await waitFor(() => expect(screen.getAllByText('克劳德').length).toBeGreaterThan(0));
    expect(screen.queryByText('Claude Code')).toBeNull();
  });

  it('shows the loading skeleton first, then swaps in the real content', async () => {
    let resolveQuery: (payload: OverviewPayload) => void = () => {};
    api.overview.query.mockReturnValueOnce(new Promise<OverviewPayload>((resolve) => { resolveQuery = resolve; }));
    const { container } = render(<Overview />);

    expect(screen.getByLabelText('正在加载概览')).toBeTruthy();
    expect(container.querySelectorAll('.skl .stat')).toHaveLength(4);

    resolveQuery(readyPayload);
    await screen.findByText('28.40M');
    expect(container.querySelector('.skl')).toBeNull();
  });

  it('fetches once on mount and renders stat tiles, trend chart, heatmap, ranking and live cards', async () => {
    render(<Overview />);

    await waitFor(() => { expect(api.overview.query).toHaveBeenCalledTimes(1); });

    expect(await screen.findByText('28.40M')).toBeTruthy();                  // 累计 Token 卡
    expect(screen.getByText(/自 2025-02-03 起/)).toBeTruthy();              // 页头副标题
    expect(screen.getByLabelText('用量趋势直方图')).toBeTruthy();           // 趋势图 svg
    expect(document.querySelectorAll('.year-heatmap__cell')).toHaveLength(371); // 热力图 371 格
    const ranking = screen.getByLabelText('模型用量排行');
    expect(within(ranking).getByText('claude-fable-5')).toBeTruthy();      // 模型排行
    expect(within(ranking).getByText('Claude Code')).toBeTruthy();         // 服务商列显示名
    expect(within(ranking).getByText('混合')).toBeTruthy();                // 多服务商模型
    expect(screen.getByText('token-meter')).toBeTruthy();                  // 实时会话卡
  });

  it('switches the trend chart metric and granularity locally without another query', async () => {
    const user = userEvent.setup();
    render(<Overview />);
    await screen.findByText('token-meter');

    await user.click(screen.getByRole('button', { name: '花费' }));
    await user.click(screen.getByRole('button', { name: '周' }));
    expect(screen.getByText('每周花费')).toBeTruthy();
    expect(api.overview.query).toHaveBeenCalledTimes(1);   // 三档数据随 payload 一次返回
  });

  it('surfaces unknown-cost events so a zero cost is not mistaken for a free one', async () => {
    render(<Overview />);
    // 「部分未知」必须在成本旁可见：模型排行有完整文案，总计卡以 † 标注，
    // 当月/今日卡显示未知条数。
    await waitFor(() => { expect(screen.getAllByText(/4 条事件价格未知/).length).toBeGreaterThanOrEqual(1); });
    expect(screen.getAllByText(/4 条未知/).length).toBeGreaterThanOrEqual(2);   // 当月 + 今日
    expect(screen.getByText(/†/)).toBeTruthy();                                  // 总计卡
  });

  it('shows one hover card with the day totals plus its model breakdown', async () => {
    render(<Overview />);
    await screen.findByText('token-meter');

    const cell = document.querySelector('.year-heatmap__cell[data-date="2026-07-10"]') as HTMLElement;
    expect(cell).toBeTruthy();
    fireEvent.mouseOver(cell);

    // 唯一的浮层卡：汇总在上，按模型明细异步补在下面。
    const card = screen.getByRole('tooltip');
    expect(card.textContent).toContain('2026-07-10');
    expect(card.textContent).toContain('220'); // heatmap fixture 里那天的 tokens
    await waitFor(() => expect(card.textContent).toContain('claude-fable-5'));
    expect(api.overview.dayModelBreakdown).toHaveBeenCalledWith('2026-07-10');
  });

  it('refreshes on demand when the manual refresh button is clicked', async () => {
    const user = userEvent.setup();
    render(<Overview />);
    await waitFor(() => { expect(api.overview.query).toHaveBeenCalledTimes(1); });

    await user.click(screen.getByRole('button', { name: '刷新' }));
    await waitFor(() => { expect(api.overview.query).toHaveBeenCalledTimes(2); });
  });

  it('reloads when a dashboard:invalidate event arrives', async () => {
    render(<Overview />);
    await waitFor(() => { expect(api.overview.query).toHaveBeenCalledTimes(1); });

    expect(invalidateCb).not.toBeNull();
    invalidateCb?.();
    await waitFor(() => { expect(api.overview.query).toHaveBeenCalledTimes(2); });
  });
});

describe('Overview (empty states)', () => {
  it('shows the never-used copy without a rescan button', async () => {
    api.overview.query.mockResolvedValue({ dataState: 'never-used' });
    render(<Overview />);

    expect(await screen.findByText('未检测到本地 agent 会话')).toBeTruthy();
    expect(screen.queryByRole('button', { name: '重新索引' })).toBeNull();
  });

  it('shows the needs-reindex copy with a rescan button and streams progress', async () => {
    api.overview.query.mockResolvedValue({ dataState: 'needs-reindex' });
    const user = userEvent.setup();
    render(<Overview />);

    expect(await screen.findByText('数据结构已更新，需要重新索引一次')).toBeTruthy();
    const button = screen.getByRole('button', { name: '重新索引' });

    // 让 startFullReindex 挂起，以便断言进度在完成前就能显示。
    let finish: () => void = () => {};
    api.index.startFullReindex.mockImplementationOnce(() => new Promise((r) => { finish = () => r({ ok: true }); }));
    await user.click(button);

    await waitFor(() => { expect(api.index.startFullReindex).toHaveBeenCalledTimes(1); });
    expect(scanProgressCb).not.toBeNull();
    scanProgressCb?.({ kind: 'scan.progress', filesTotal: 4, filesDone: 1, bytesTotal: 100, bytesDone: 25, currentRoot: 'Claude' });

    expect(await screen.findByText(/Claude/)).toBeTruthy();
    expect(screen.getByText(/1 \/ 4 个文件/)).toBeTruthy();
    finish();
  });
});
