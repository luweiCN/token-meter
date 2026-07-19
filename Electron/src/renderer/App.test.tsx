// @vitest-environment jsdom

import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Mock } from 'vitest';

import { AppShell } from './App.js';
import { dismissToast } from './components/toast.js';
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
    fileCount: number;
    totalSizeBytes: number;
    eventsCount: number;
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
    onSessionEvent: Mock<(callback: (event: unknown) => void) => () => void>;
  };
  sessions: {
    query: Mock<() => Promise<{ items: unknown[]; total: number }>>;
    trend: Mock<() => Promise<{ buckets: string[]; rows: unknown[] }>>;
    projects: Mock<() => Promise<unknown[]>>;
  };
  projects: {
    list: Mock<() => Promise<unknown[]>>;
    detail: Mock<(projectId: number) => Promise<unknown>>;
  };
  index: {
    status: Mock<() => Promise<IndexStatusResult>>;
    setRootEnabled: Mock<(id: number, enabled: boolean) => Promise<void>>;
    startFullReindex: Mock<() => Promise<unknown>>;
    onScanProgress: Mock<(callback: (progress: unknown) => void) => () => void>;
  };
  agents: {
    detect: Mock<() => Promise<Array<{ kind: string; found: boolean; path?: string | null; version?: string | null }> | null>>;
  };
  credentials: {
    set: Mock<(providerId: string, token: string) => Promise<boolean>>;
    state: Mock<(providerId: string) => Promise<boolean | null>>;
  };
  notifications: {
    state: Mock<() => Promise<string>>;
    requestAuthorization: Mock<() => Promise<string>>;
  };
  windowControls: {
    setButtonsVisible: Mock<(visible: boolean) => Promise<void>>;
  };
}

const settingsSnapshot: SettingsSnapshot = {
  version: 12,
  menuBarPrimaryProviderId: 'codex',
  autoRefreshSeconds: 300,
  quotaUsedThresholdPercent: 0,
  menubarAppearance: {
    style: 'rings',
    showName: true,
    showGlyph: true,
    showNumber: true,
    usage: 'tok',
    windowOrder: 'longFirst'
  },
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
      lastError: null,
      fileCount: 4921,
      totalSizeBytes: 2048_000,
      eventsCount: 38455
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
      lastError: 'database operation failed',
      fileCount: 1584,
      totalSizeBytes: 512_000,
      eventsCount: 16447
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
      onInvalidate: vi.fn<(callback: () => void) => () => void>(() => () => {}),
      onSessionEvent: vi.fn<(callback: (event: unknown) => void) => () => void>(() => () => {})
    },
    sessions: {
      query: vi.fn(async () => ({ items: [], total: 0 })),
      trend: vi.fn(async () => ({ buckets: [], rows: [] })),
      projects: vi.fn(async () => [])
    },
    projects: {
      list: vi.fn(async () => [
        {
          id: 1, displayName: 'token-meter', pathLabel: '~/code/ai/token-meter',
          sessionsCount: 42, costUsdMicros: 1_300_000, costUnknownEvents: 0,
          tokensTotal: 999, spark: Array.from({ length: 14 }, () => 0), lastActiveDate: '2026-07-10'
        }
      ]),
      detail: vi.fn(async () => null)
    },
    index: {
      status: vi.fn<() => Promise<IndexStatusResult>>(),
      setRootEnabled: vi.fn<(id: number, enabled: boolean) => Promise<void>>(async () => {}),
      startFullReindex: vi.fn<() => Promise<unknown>>(),
      onScanProgress: vi.fn<(callback: (progress: unknown) => void) => () => void>(() => () => {})
    },
    agents: {
      detect: vi.fn(async () => [
        { kind: 'claudeCode', found: true, path: '/usr/local/bin/claude', version: '2.1.207 (Claude Code)' },
        { kind: 'codex', found: false, path: null, version: null },
        { kind: 'omp', found: true, path: '/opt/homebrew/bin/omp', version: 'omp/16.4.8' },
        { kind: 'opencode', found: true, path: '/opt/homebrew/bin/opencode', version: '1.17.18' }
      ])
    },
    credentials: {
      set: vi.fn<(providerId: string, token: string) => Promise<boolean>>(async (_id, token) => token !== ''),
      state: vi.fn<(providerId: string) => Promise<boolean | null>>(async () => false)
    },
    notifications: {
      state: vi.fn<() => Promise<string>>(async () => 'notDetermined'),
      requestAuthorization: vi.fn<() => Promise<string>>(async () => 'authorized')
    },
    windowControls: {
      setButtonsVisible: vi.fn<(visible: boolean) => Promise<void>>(async () => {})
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
    dismissToast();
    Reflect.deleteProperty(window, 'tokenMeter');
  });

  it('renders Chinese primary route buttons and marks the active route', async () => {
    render(<AppShell />);

    const nav = screen.getByRole('navigation');
    expect(within(nav).getByRole('button', { name: '总览' }).getAttribute('aria-current')).toBe('page');
    expect(within(nav).getByRole('button', { name: '会话' }).getAttribute('aria-current')).toBeNull();
    expect(within(nav).getByRole('button', { name: '设置' }).getAttribute('aria-current')).toBeNull();
    // 索引状态已并入设置页数据区，侧栏不再单列。
    expect(within(nav).queryByRole('button', { name: '索引状态' })).toBeNull();
    expect((within(nav).getByRole('button', { name: '项目' }) as HTMLButtonElement).disabled).toBe(false);
    expect((within(nav).getByRole('button', { name: '模型' }) as HTMLButtonElement).disabled).toBe(false);
    // 「查询」已移除（用户裁定 2026-07-17：不需要该页）。
    expect(within(nav).queryByRole('button', { name: '查询' })).toBeNull();
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

  it('refreshes the sidebar index summary when the window regains focus', async () => {
    api.index.status.mockResolvedValueOnce(indexStatusResult).mockResolvedValue(healthyIndexStatusResult);
    render(<AppShell />);

    await waitFor(() => {
      expect(api.index.status).toHaveBeenCalledTimes(1);
    });

    window.dispatchEvent(new Event('focus'));

    // App 只维护侧栏「上次扫描」摘要；聚焦时重拉一次。
    await waitFor(() => {
      expect(api.index.status.mock.calls.length).toBeGreaterThanOrEqual(2);
    });
  });

  it('changes the visible route content when sidebar controls are clicked', async () => {
    const user = userEvent.setup();
    render(<AppShell />);

    expect(screen.getByRole('heading', { level: 1, name: '总览' })).toBeTruthy();
    expectNoEnglishScaffold();

    await user.click(screen.getByRole('button', { name: '会话' }));
    expect(screen.getByRole('heading', { level: 1, name: '会话' })).toBeTruthy();
    expect(await screen.findByText('全部项目')).toBeTruthy();
    expect(screen.getByPlaceholderText('搜索会话标题 / 模型')).toBeTruthy();
    expectNoEnglishScaffold();

    await user.click(within(screen.getByRole('navigation')).getByRole('button', { name: '项目' }));
    expect(screen.getByRole('heading', { level: 1, name: '项目' })).toBeTruthy();
    // 项目卡：名称 + 脱敏路径 + 会话数。
    expect(await screen.findByText('token-meter')).toBeTruthy();
    expect(screen.getByText('~/code/ai/token-meter')).toBeTruthy();
    expect(screen.getByText('42 会话')).toBeTruthy();
    expect(document.querySelector('.pc-spark')?.classList.contains('chart-surface-in')).toBe(true);
    expectNoEnglishScaffold();

    await user.click(screen.getByRole('button', { name: '设置' }));
    expect(screen.getByRole('heading', { level: 1, name: '设置' })).toBeTruthy();
    expect(screen.getAllByText(/供应商额度接入|Coding Agent 集成/).length).toBeGreaterThan(0);
    expectNoEnglishScaffold();
  });

  it('uses the shared chart motion on project sparklines, columns, and distribution bars', async () => {
    const user = userEvent.setup();
    api.projects.detail.mockResolvedValue({
      id: 1,
      displayName: 'token-meter',
      pathLabel: '~/code/ai/token-meter',
      sessionsCount: 42,
      activeDays: 2,
      lastActiveDate: '2026-07-20',
      costUsdMicros: 1_300_000,
      costUnknownEvents: 0,
      tokensTotal: 999,
      dailyCost: [
        { date: '2026-07-19', costUsdMicros: 300_000 },
        { date: '2026-07-20', costUsdMicros: 1_000_000 }
      ],
      models: [{ model: 'gpt-5', tokens: 999, costUsdMicros: 1_300_000 }],
      agents: [{ providerId: 'codex', tokens: 999, costUsdMicros: 1_300_000 }]
    });
    render(<AppShell />);

    await user.click(within(screen.getByRole('navigation')).getByRole('button', { name: '项目' }));
    await screen.findByText('token-meter');
    expect(document.querySelector('.pc-spark')?.classList.contains('chart-surface-in')).toBe(true);
    await user.click(document.querySelector('.pcard')!);

    await waitFor(() => expect(document.querySelectorAll('.proj-day-bar .chart-bar-y-in')).toHaveLength(2));
    expect(document.querySelectorAll('.dist-row .chart-bar-x-in')).toHaveLength(2);
    expect((document.querySelectorAll('.proj-day-bar .chart-bar-y-in')[1] as HTMLElement).style.animationDelay).toBe('8ms');
  });

  it('renders one source card per scan root inside the data section of the settings page', async () => {
    const user = userEvent.setup();
    render(<AppShell />);

    await user.click(screen.getByRole('button', { name: '设置' }));

    // 每源一张卡：名称 + pill、路径、文件/事件数。
    expect(await screen.findByText('~/.codex/records')).toBeTruthy();
    expect(screen.getByText('已完成')).toBeTruthy();
    expect(screen.getByText('38,455')).toBeTruthy();       // Codex 事件数
    expect(screen.getByText('已停用')).toBeTruthy();       // enabled=false
    // 失败文件收进卡片错误行（1 个解析失败 + root 级错误合并展示）。
    expect(screen.getByText(/1 个文件解析失败/)).toBeTruthy();
    // 数据区汇总：总事件数 = 两源之和。
    expect(screen.getByText(/54,902/)).toBeTruthy();
    expectNoEnglishScaffold();
  });

  it('starts a full rescan from the settings data section and clears the error row after it finishes', async () => {
    const user = userEvent.setup();
    const refreshedStatus: IndexStatusResult = {
      ...indexStatusResult,
      roots: indexStatusResult.roots.map((root) => ({ ...root, lastError: null })),
      failedFiles: []
    };
    // App 侧栏摘要 + 设置页各拉一次，完成后设置页再拉 → 用最后一次返回干净状态。
    api.index.status.mockResolvedValueOnce(indexStatusResult).mockResolvedValueOnce(indexStatusResult).mockResolvedValue(refreshedStatus);
    render(<AppShell />);

    await user.click(screen.getByRole('button', { name: '设置' }));
    await screen.findByText(/1 个文件解析失败/);
    await user.click(screen.getByRole('button', { name: '重新扫描…' }));
    await user.click(await screen.findByRole('button', { name: '开始重建' }));

    await waitFor(() => {
      expect(api.index.startFullReindex).toHaveBeenCalledTimes(1);
    });
    // 重扫后失败清空：错误行消失。
    await waitFor(() => expect(screen.queryByText(/个文件解析失败/)).toBeNull());
  });

  it('toggles a coding agent kind through the whitelisted settings API', async () => {
    const user = userEvent.setup();
    render(<AppShell />);

    await user.click(screen.getByRole('button', { name: '设置' }));
    const toggle = await screen.findByRole('button', { name: 'OMP' });
    expect(toggle.getAttribute('aria-pressed')).toBe('false');

    await user.click(toggle);

    await waitFor(() => {
      expect(api.settings.update).toHaveBeenCalledWith({ enabledAgentKinds: ['claudeCode', 'codex', 'omp'] }, 12);
    });
  });

  it('changes the scan interval through the whitelisted settings API', async () => {
    const user = userEvent.setup();
    render(<AppShell />);

    await user.click(screen.getByRole('button', { name: '设置' }));
    await user.click(await screen.findByRole('button', { name: '30 秒' }));

    await waitFor(() => {
      expect(api.settings.update).toHaveBeenCalledWith({ autoRefreshSeconds: 30 }, 12);
    });
  });

  it('shows a failed settings status when the whitelisted update rejects', async () => {
    const user = userEvent.setup();
    api.settings.update.mockRejectedValueOnce(new Error('stale version'));
    render(<AppShell />);

    await user.click(screen.getByRole('button', { name: '设置' }));
    await user.click(await screen.findByRole('button', { name: 'OMP' }));

    await waitFor(() => {
      expect(screen.getByRole('status').textContent).toMatch(/设置保存失败/);
    });
    expect(screen.getByRole('status').textContent).toMatch(/stale version/);
    expectNoEnglishScaffold();
  });

  it('shows detected CLI versions and flags an enabled agent whose CLI is missing', async () => {
    const user = userEvent.setup();
    render(<AppShell />);
    await user.click(screen.getByRole('button', { name: '设置' }));

    // 检测到的 agent 显示版本 + 路径；开着却没 CLI 的（codex）打「未找到命令行」。
    expect(await screen.findByText(/2\.1\.207/)).toBeTruthy();
    expect(screen.getByText(/omp\/16\.4\.8/)).toBeTruthy();
    expect(screen.getByText('未找到命令行')).toBeTruthy();
    expect(api.agents.detect).toHaveBeenCalledTimes(1);

    await user.click(screen.getByRole('button', { name: '重新检测' }));
    await waitFor(() => expect(api.agents.detect).toHaveBeenCalledTimes(2));
    expectNoEnglishScaffold();
  });

  it('toggles a quota provider off via the row switch', async () => {
    const user = userEvent.setup();
    render(<AppShell />);
    await user.click(screen.getByRole('button', { name: '设置' }));

    // fixture 里 zhipu 无 override → 默认启用；点开关 = 停用。
    await user.click(await screen.findByRole('button', { name: '启用 智谱 GLM' }));

    await waitFor(() => {
      expect(api.settings.update).toHaveBeenCalledWith({ providerEnabled: { zhipu: false } }, 12);
    });
  });

  it('saves an in-app API key to the keychain and can clear it later', async () => {
    const user = userEvent.setup();
    api.credentials.state.mockResolvedValue(true);   // 已配置过 → 显示清除按钮
    render(<AppShell />);
    await user.click(screen.getByRole('button', { name: '设置' }));

    const keyInput = await screen.findByLabelText('智谱 GLM API Key');
    await user.type(keyInput, 'sk-test-123');
    await user.click(screen.getByRole('button', { name: '存入钥匙串' }));

    await waitFor(() => {
      expect(api.credentials.set).toHaveBeenCalledWith('zhipu', 'sk-test-123');
    });

    await user.click(screen.getByRole('button', { name: '清除' }));
    await waitFor(() => {
      expect(api.credentials.set).toHaveBeenCalledWith('zhipu', '');
    });
    expectNoEnglishScaffold();
  });

  it('toggles a scan root off via the row switch and refreshes the directory list', async () => {
    const user = userEvent.setup();
    render(<AppShell />);
    await user.click(screen.getByRole('button', { name: '设置' }));

    // fixture 里 root 1（Codex）enabled=true：点开关 = 暂停该目录。
    await user.click(await screen.findByRole('button', { name: 'Codex 目录启用开关' }));

    await waitFor(() => {
      expect(api.index.setRootEnabled).toHaveBeenCalledWith(1, false);
    });
    expect(api.index.status.mock.calls.length).toBeGreaterThan(1);   // 成功后重拉目录列表
    expectNoEnglishScaffold();
  });

  it('switches the appearance preference to follow-system', async () => {
    const user = userEvent.setup();
    render(<AppShell />);
    await user.click(screen.getByRole('button', { name: '设置' }));

    await user.click(await screen.findByRole('button', { name: '跟随系统' }));

    expect(localStorage.getItem('tm-theme')).toBe('system');
    // jsdom 的 matchMedia 由 setup 提供（prefers-color-scheme 不匹配 → light）。
    expect(document.documentElement.dataset.theme).toMatch(/dark|light/);
  });

  it('turns the quota alert on with the default threshold and requests notification authorization', async () => {
    const user = userEvent.setup();
    render(<AppShell />);
    await user.click(screen.getByRole('button', { name: '设置' }));

    await user.click(await screen.findByRole('button', { name: '额度告警开关' }));

    await waitFor(() => {
      expect(api.settings.update).toHaveBeenCalledWith({ quotaUsedThresholdPercent: 85 }, 12);
    });
    expect(api.notifications.requestAuthorization).toHaveBeenCalled();
    expectNoEnglishScaffold();
  });

  it('turns the quota alert off by writing threshold 0 without touching authorization', async () => {
    const user = userEvent.setup();
    api.settings.get.mockResolvedValue({ ...settingsSnapshot, quotaUsedThresholdPercent: 85 });
    render(<AppShell />);
    await user.click(screen.getByRole('button', { name: '设置' }));

    await user.click(await screen.findByRole('button', { name: '额度告警开关' }));

    await waitFor(() => {
      expect(api.settings.update).toHaveBeenCalledWith({ quotaUsedThresholdPercent: 0 }, 12);
    });
    expect(api.notifications.requestAuthorization).not.toHaveBeenCalled();
  });

  it('shows a failed settings status when initial settings load rejects', async () => {
    const user = userEvent.setup();
    // 持续拒绝：Overview 挂载时也会消耗一次 settings.get（别名映射），Once 会被它抢走。
    api.settings.get.mockRejectedValue(new Error('SQLite unavailable'));
    render(<AppShell />);

    await user.click(screen.getByRole('button', { name: '设置' }));

    await waitFor(() => {
      expect(screen.getByRole('status').textContent).toMatch(/设置加载失败/);
    });
    expect(screen.getByRole('status').textContent).toMatch(/SQLite unavailable/);
    expectNoEnglishScaffold();
  });
});
