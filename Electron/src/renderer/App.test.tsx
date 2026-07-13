// @vitest-environment jsdom

import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Mock } from 'vitest';

import { AppShell } from './App.js';
import type { SettingsSnapshot } from './stores/settingsStore.js';

interface SettingsPatch {
  menuBarPrimaryProviderId?: string;
  autoRefreshSeconds?: number;
  enabledAgentKinds?: string[];
}

interface SettingsApplyRequest {
  requestedVersion: number;
  status: 'pending' | 'applied' | 'failed';
}

interface IndexStatusResult {
  roots: Array<{
    id: number;
    kind: string;
    rootPathLabel: string;
    displayName: string;
    enabled: boolean;
    scanMode: string;
    lastScanStartedAt: string | null;
    lastScanFinishedAt: string | null;
    lastSuccessfulCursor: string | null;
    lastError: string | null;
  }>;
  runs: Array<{
    id: number;
    scanRootId: number;
    startedAt: string;
    finishedAt: string | null;
    runKind: string;
    status: string;
    filesSeen: number;
    filesChanged: number;
    usageRowsAdded: number;
    bytesRead: number;
    errorSummary: string | null;
  }>;
  failedFiles: Array<{
    id: number;
    scanRootId: number;
    relativePath: string;
    fileType: string;
    parseError: string;
    updatedAt: string;
  }>;
}

interface DashboardOverview {
  sessionCount: number;
  totalTokens: number;
  activeModelCount: number;
  totalCostUsdMicros: number;
  modelBreakdown: Array<{
    modelName: string;
    sessionsCount: number;
    tokensTotal: number;
    costUsdMicros: number;
  }>;
  providerBreakdown: Array<{
    providerId: string;
    sessionsCount: number;
    tokensTotal: number;
  }>;
  dailyTrend: Array<{
    usageDate: string;
    tokensTotal: number;
    sessionsCount: number;
  }>;
}

interface TokenMeterApi {
  settings: {
    get: Mock<() => Promise<SettingsSnapshot>>;
    update: Mock<(patch: SettingsPatch, expectedVersion: number) => Promise<SettingsApplyRequest>>;
  };
  dashboard: {
    queryOverview: Mock<() => Promise<DashboardOverview>>;
  };
  overview: {
    query: Mock<() => Promise<{ dataState: string }>>;
    onInvalidate: Mock<(callback: () => void) => () => void>;
  };
  index: {
    status: Mock<() => Promise<IndexStatusResult>>;
    startFullReindex: Mock<() => Promise<unknown>>;
    onScanProgress: Mock<(callback: (progress: unknown) => void) => () => void>;
  };
}

const settingsSnapshot: SettingsSnapshot = {
  version: 12,
  menuBarPrimaryProviderId: 'codex',
  autoRefreshSeconds: 300,
  enabledAgentKinds: ['claudeCode', 'codex'],
  providerOverrides: [
    {
      providerId: 'codex',
      displayName: 'Codex',
      enabled: true,
      menuRank: 1,
      showInMenuBar: true,
      showInCharts: true
    },
    {
      providerId: 'claude-code',
      displayName: 'Claude Code',
      enabled: true,
      menuRank: 2,
      showInMenuBar: true,
      showInCharts: true
    }
  ]
};

const updatedSettingsSnapshot: SettingsSnapshot = {
  ...settingsSnapshot,
  version: 13,
  menuBarPrimaryProviderId: 'claude-code'
};

const indexStatusResult: IndexStatusResult = {
  roots: [
    {
      id: 1,
      kind: 'codex_jsonl',
      rootPathLabel: '~/.codex/records',
      displayName: 'Codex',
      enabled: true,
      scanMode: 'incremental',
      lastScanStartedAt: '2026-07-03T10:10:00Z',
      lastScanFinishedAt: '2026-07-03T10:10:05Z',
      lastSuccessfulCursor: 'cursor-123',
      lastError: null
    },
    {
      id: 2,
      kind: 'opencode_sqlite',
      rootPathLabel: '~/.local/share/opencode',
      displayName: 'OpenCode',
      enabled: false,
      scanMode: 'disabled',
      lastScanStartedAt: '2026-07-03T09:00:00Z',
      lastScanFinishedAt: '2026-07-03T09:00:01Z',
      lastSuccessfulCursor: null,
      lastError: 'database operation failed'
    }
  ],
  runs: [
    {
      id: 42,
      scanRootId: 2,
      startedAt: '2026-07-03T10:15:00Z',
      finishedAt: '2026-07-03T10:15:06Z',
      runKind: 'full',
      status: 'partial',
      filesSeen: 8,
      filesChanged: 3,
      usageRowsAdded: 6,
      bytesRead: 4096,
      errorSummary: '1 file failed'
    }
  ],
  failedFiles: [
    {
      id: 100,
      scanRootId: 2,
      relativePath: 'bad/session.jsonl',
      fileType: 'jsonl_session',
      parseError: 'database operation failed',
      updatedAt: '2026-07-03T11:00:09Z'
    }
  ]
};

const healthyIndexStatusResult: IndexStatusResult = {
  ...indexStatusResult,
  roots: indexStatusResult.roots.map((root) => ({ ...root, lastError: null })),
  runs: [
    {
      ...indexStatusResult.runs[0],
      id: 43,
      status: 'ok',
      errorSummary: null
    }
  ],
  failedFiles: []
};

const dashboardOverview: DashboardOverview = {
  sessionCount: 2250,
  totalTokens: 41729280449,
  activeModelCount: 3,
  totalCostUsdMicros: 36000,
  modelBreakdown: [
    { modelName: 'claude-sonnet', sessionsCount: 1200, tokensTotal: 23000000000, costUsdMicros: 24000 },
    { modelName: 'gpt-5', sessionsCount: 900, tokensTotal: 18000000000, costUsdMicros: 12000 }
  ],
  providerBreakdown: [
    { providerId: 'claude-code', sessionsCount: 1200, tokensTotal: 23000000000 },
    { providerId: 'codex', sessionsCount: 900, tokensTotal: 18000000000 }
  ],
  dailyTrend: [
    { usageDate: '2026-07-01', tokensTotal: 1000, sessionsCount: 2 },
    { usageDate: '2026-07-02', tokensTotal: 2000, sessionsCount: 3 }
  ]
};

function expectNoEnglishScaffold() {
  for (const text of ['Task 14 will connect', 'Dashboard', 'Sessions', 'Index Status', 'Settings', 'Waiting for data']) {
    expect(screen.queryAllByText(text, { exact: false })).toHaveLength(0);
  }
}

function installTokenMeterApi(): TokenMeterApi {
  const api: TokenMeterApi = {
    settings: {
      get: vi.fn<() => Promise<SettingsSnapshot>>(),
      update: vi.fn<(patch: SettingsPatch, expectedVersion: number) => Promise<SettingsApplyRequest>>()
    },
    dashboard: {
      queryOverview: vi.fn<() => Promise<DashboardOverview>>()
    },
    overview: {
      query: vi.fn<() => Promise<{ dataState: string }>>(),
      onInvalidate: vi.fn<(callback: () => void) => () => void>(() => () => {})
    },
    index: {
      status: vi.fn<() => Promise<IndexStatusResult>>(),
      startFullReindex: vi.fn<() => Promise<unknown>>(),
      onScanProgress: vi.fn<(callback: (progress: unknown) => void) => () => void>(() => () => {})
    }
  };

  Object.defineProperty(window, 'tokenMeter', {
    configurable: true,
    value: api
  });

  return api;
}

describe('AppShell renderer routes', () => {
  let api: TokenMeterApi;

  beforeEach(() => {
    document.body.innerHTML = '<div id="root"></div>';
    api = installTokenMeterApi();
    api.settings.get.mockResolvedValue(settingsSnapshot);
    api.settings.update.mockResolvedValue({ requestedVersion: 13, status: 'pending' });
    api.index.status.mockResolvedValue(indexStatusResult);
    api.dashboard.queryOverview.mockResolvedValue(dashboardOverview);
    api.overview.query.mockResolvedValue({ dataState: 'needs-reindex' });
    api.index.startFullReindex.mockResolvedValue({ ok: true });
  });

  afterEach(() => {
    vi.restoreAllMocks();
    Reflect.deleteProperty(window, 'tokenMeter');
  });

  it('renders Chinese primary route buttons and marks the active route', async () => {
    render(<AppShell />);

    const nav = screen.getByRole('navigation');
    expect(within(nav).getByRole('button', { name: '总览' }).getAttribute('aria-current')).toBe('page');
    expect(within(nav).getByRole('button', { name: '会话' }).getAttribute('aria-current')).toBeNull();
    expect(within(nav).getByRole('button', { name: '索引状态' }).getAttribute('aria-current')).toBeNull();
    expect(within(nav).getByRole('button', { name: '设置' }).getAttribute('aria-current')).toBeNull();
    // 「项目」「查询」的页面稿未接入：先渲染禁用态占位，不产生路由。
    expect((within(nav).getByRole('button', { name: '项目' }) as HTMLButtonElement).disabled).toBe(true);
    expect((within(nav).getByRole('button', { name: '查询' }) as HTMLButtonElement).disabled).toBe(true);
    expect(document.querySelectorAll('a:not([href])')).toHaveLength(0);
    expectNoEnglishScaffold();
  });

  it('renders the overview page from its own query on the default route', async () => {
    // 概览页（Overview）自持数据，App 不再把索引摘要塞进首页；索引健康在「索引状态」页。
    render(<AppShell />);

    expect(await screen.findByText('数据结构已更新，需要重新索引一次')).toBeTruthy();
    await waitFor(() => {
      expect(api.overview.query).toHaveBeenCalledTimes(1);
    });
    expect(screen.queryByText('等待数据')).toBeNull();
    expectNoEnglishScaffold();
  });

  it('refreshes the index status when the window regains focus', async () => {
    const user = userEvent.setup();
    api.index.status.mockResolvedValueOnce(indexStatusResult).mockResolvedValue(healthyIndexStatusResult);
    render(<AppShell />);

    await user.click(screen.getByRole('button', { name: '索引状态' }));
    expect(await screen.findByText('扫描 #42 · 部分失败')).toBeTruthy();

    window.dispatchEvent(new Event('focus'));

    await waitFor(() => {
      expect(api.index.status.mock.calls.length).toBeGreaterThanOrEqual(2);
    });
    expect(await screen.findByText('扫描 #43 · 成功')).toBeTruthy();
  });

  it('changes the visible route content when sidebar controls are clicked', async () => {
    const user = userEvent.setup();
    render(<AppShell />);

    expect(screen.getByRole('heading', { level: 1, name: '总览' })).toBeTruthy();
    expectNoEnglishScaffold();

    await user.click(screen.getByRole('button', { name: '会话' }));
    expect(screen.getByRole('heading', { level: 1, name: '会话' })).toBeTruthy();
    expect(screen.getByText(/会话.*用量|筛选用量/)).toBeTruthy();
    expectNoEnglishScaffold();

    await user.click(screen.getByRole('button', { name: '索引状态' }));
    expect(screen.getByRole('heading', { level: 1, name: '索引状态' })).toBeTruthy();
    expect(screen.getAllByText(/扫描根|失败文件/).length).toBeGreaterThan(0);
    expectNoEnglishScaffold();

    await user.click(screen.getByRole('button', { name: '设置' }));
    expect(screen.getByRole('heading', { level: 1, name: '设置' })).toBeTruthy();
    expect(screen.getAllByText(/提供商设置|菜单栏优先显示/).length).toBeGreaterThan(0);
    expectNoEnglishScaffold();
  });

  it('loads index status from the preload API and renders roots, recent runs, and failed files', async () => {
    const user = userEvent.setup();
    render(<AppShell />);

    await user.click(screen.getByRole('button', { name: '索引状态' }));

    await waitFor(() => {
      expect(api.index.status).toHaveBeenCalledTimes(1);
    });
    expect(await screen.findByText('Codex')).toBeTruthy();
    expect(screen.getByText('~/.codex/records')).toBeTruthy();
    expect(screen.getByText('OpenCode')).toBeTruthy();
    expect(screen.getByText('~/.local/share/opencode')).toBeTruthy();
    expect(screen.getByText(/最近扫描|扫描记录/)).toBeTruthy();
    expect(screen.getByText('扫描 #42 · 部分失败')).toBeTruthy();
    expect(screen.getByText('2026-07-03T10:15:00Z')).toBeTruthy();
    expect(screen.getByText('3 / 8')).toBeTruthy();
    expect(screen.getByText('1 file failed')).toBeTruthy();
    expect(screen.getAllByText(/失败文件/).length).toBeGreaterThan(0);
    expect(screen.getByText('bad/session.jsonl')).toBeTruthy();
    expect(screen.getAllByText('database operation failed').length).toBeGreaterThan(0);
    expectNoEnglishScaffold();
  });

  it('starts a reindex from the index status page and refreshes the displayed status', async () => {
    const user = userEvent.setup();
    const refreshedStatus: IndexStatusResult = {
      ...indexStatusResult,
      roots: indexStatusResult.roots.map((root) => ({ ...root, lastError: null })),
      runs: [
        {
          ...indexStatusResult.runs[0],
          id: 43,
          status: 'ok',
          errorSummary: null
        }
      ],
      failedFiles: []
    };
    api.index.status.mockResolvedValueOnce(indexStatusResult).mockResolvedValueOnce(refreshedStatus);
    render(<AppShell />);

    await user.click(screen.getByRole('button', { name: '索引状态' }));
    await screen.findByText('扫描 #42 · 部分失败');
    await user.click(screen.getByRole('button', { name: '重新索引' }));

    await waitFor(() => {
      expect(api.index.startFullReindex).toHaveBeenCalledTimes(1);
    });
    await waitFor(() => {
      expect(api.index.status).toHaveBeenCalledTimes(2);
    });
    expect(await screen.findByText('扫描 #43 · 成功')).toBeTruthy();
  });

  it('loads settings on the Settings route and persists primary provider changes through the whitelisted API', async () => {
    const user = userEvent.setup();
    api.settings.get.mockResolvedValueOnce(settingsSnapshot).mockResolvedValueOnce(updatedSettingsSnapshot);
    render(<AppShell />);

    await user.click(screen.getByRole('button', { name: '设置' }));
    const primaryProviderSelect = await screen.findByLabelText('主要提供商');

    expect(primaryProviderSelect).toHaveProperty('value', 'codex');
    await user.selectOptions(primaryProviderSelect, 'claude-code');

    await waitFor(() => {
      expect(api.settings.update).toHaveBeenCalledWith({ menuBarPrimaryProviderId: 'claude-code' }, 12);
    });
    expectNoEnglishScaffold();
  });

  it('shows a failed settings status when the whitelisted update rejects', async () => {
    const user = userEvent.setup();
    api.settings.update.mockRejectedValueOnce(new Error('stale version'));
    render(<AppShell />);

    await user.click(screen.getByRole('button', { name: '设置' }));
    const primaryProviderSelect = await screen.findByLabelText('主要提供商');
    await user.selectOptions(primaryProviderSelect, 'claude-code');

    await waitFor(() => {
      expect(screen.getByRole('status').textContent).toMatch(/设置保存失败/);
    });
    expect(screen.getByRole('status').textContent).toMatch(/stale version/);
    expectNoEnglishScaffold();
  });

  it('shows a failed settings status when initial settings load rejects', async () => {
    const user = userEvent.setup();
    api.settings.get.mockRejectedValueOnce(new Error('SQLite unavailable'));
    render(<AppShell />);

    await user.click(screen.getByRole('button', { name: '设置' }));

    await waitFor(() => {
      expect(screen.getByRole('status').textContent).toMatch(/设置加载失败/);
    });
    expect(screen.getByRole('status').textContent).toMatch(/SQLite unavailable/);
    expectNoEnglishScaffold();
  });
});
