import { BrowserWindow, type BrowserWindowConstructorOptions, type IpcMain } from 'electron';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { beforeEach, describe, expect, it, vi } from 'vitest';

type IpcHandle = IpcMain['handle'];

interface RegisteredIpcHandler {
  channel: string;
  listener: Parameters<IpcHandle>[1];
}

interface ExposedApi {
  key: string;
  api: Record<string, unknown>;
}

const mockElectron = vi.hoisted(() => ({
  exposedApis: [] as ExposedApi[],
  ipcHandlers: [] as RegisteredIpcHandler[],
  windowOptions: [] as BrowserWindowConstructorOptions[],
  senderWindow: null as { setWindowButtonVisibility: (visible: boolean) => void } | null,
  windowButtonVisibility: [] as boolean[]
}));

const mockDatabase = vi.hoisted(() => ({
  instance: { label: 'token-meter-test-db' }
}));

const mockSettingsRepository = vi.hoisted(() => ({
  constructor: vi.fn(),
  get: vi.fn(),
  update: vi.fn()
}));

const mockDashboardRepository = vi.hoisted(() => ({
  constructor: vi.fn(),
  overview: vi.fn()
}));

const mockOverviewRepository = vi.hoisted(() => ({
  constructor: vi.fn(),
  buildOverview: vi.fn()
}));

const mockSessionsRepository = vi.hoisted(() => ({
  constructor: vi.fn(),
  query: vi.fn()
}));

const mockIndexStatusRepository = vi.hoisted(() => ({
  constructor: vi.fn(),
  status: vi.fn(),
  isScanning: vi.fn()
}));

const mockModelsRepository = vi.hoisted(() => ({
  constructor: vi.fn(),
  query: vi.fn()
}));

const mockSwiftClient = vi.hoisted(() => ({
  notifySwift: vi.fn(),
  requestFullRescan: vi.fn(),
  subscribeEvents: vi.fn(
    (_onEvent: (event: { kind: string; [key: string]: string }) => void) => () => {}
  )
}));

vi.mock('./database.js', () => ({
  openTokenMeterDatabase: vi.fn(() => mockDatabase.instance)
}));

vi.mock('./settingsRepository.js', () => ({
  SettingsRepository: vi.fn(function SettingsRepositoryMock(database: unknown) {
    mockSettingsRepository.constructor(database);
    return {
      get: mockSettingsRepository.get,
      update: mockSettingsRepository.update
    };
  })
}));

vi.mock('./dashboardRepository.js', () => ({
  DashboardRepository: vi.fn(function DashboardRepositoryMock(database: unknown) {
    mockDashboardRepository.constructor(database);
    return {
      overview: mockDashboardRepository.overview
    };
  })
}));

vi.mock('./overviewRepository.js', () => ({
  OverviewRepository: vi.fn(function OverviewRepositoryMock(database: unknown) {
    mockOverviewRepository.constructor(database);
    return {
      buildOverview: mockOverviewRepository.buildOverview
    };
  })
}));

vi.mock('./sessionsRepository.js', () => ({
  SessionsRepository: vi.fn(function SessionsRepositoryMock(database: unknown) {
    mockSessionsRepository.constructor(database);
    return {
      query: mockSessionsRepository.query
    };
  })
}));

vi.mock('./indexStatusRepository.js', () => ({
  IndexStatusRepository: vi.fn(function IndexStatusRepositoryMock(database: unknown) {
    mockIndexStatusRepository.constructor(database);
    return {
      status: mockIndexStatusRepository.status,
      isScanning: mockIndexStatusRepository.isScanning
    };
  })
}));

vi.mock('./modelsRepository.js', () => ({
  ModelsRepository: vi.fn(function ModelsRepositoryMock(database: unknown) {
    mockModelsRepository.constructor(database);
    return {
      query: mockModelsRepository.query
    };
  })
}));

vi.mock('./tokenMeterSocketClient.js', () => ({
  notifySwift: mockSwiftClient.notifySwift,
  requestFullRescan: mockSwiftClient.requestFullRescan,
  subscribeEvents: mockSwiftClient.subscribeEvents
}));

vi.mock('electron', () => ({
  app: {
    focus: vi.fn(),
    on: vi.fn(),
    quit: vi.fn(),
    requestSingleInstanceLock: vi.fn(() => true),
    whenReady: vi.fn(() => ({ then: vi.fn() }))
  },
  BrowserWindow: Object.assign(vi.fn(function BrowserWindowMock(options: BrowserWindowConstructorOptions) {
    mockElectron.windowOptions.push(options);

    return {
      focus: vi.fn(),
      isMinimized: vi.fn(() => false),
      loadFile: vi.fn(),
      loadURL: vi.fn(),
      on: vi.fn(),
      restore: vi.fn(),
      show: vi.fn()
    };
  }), {
    getAllWindows: vi.fn(() => []),
    fromWebContents: vi.fn(() => mockElectron.senderWindow)
  }),
  contextBridge: {
    exposeInMainWorld: vi.fn((key: string, api: Record<string, unknown>) => {
      mockElectron.exposedApis.push({ key, api });
    })
  },
  ipcMain: {
    handle: vi.fn((channel: string, listener: Parameters<IpcHandle>[1]) => {
      mockElectron.ipcHandlers.push({ channel, listener });
    })
  },
  ipcRenderer: {
    invoke: vi.fn()
  }
}));

import { registerIpcHandlers } from './ipc.js';
import { createWindow } from './main.js';
import '../preload.js';

const allowedIpcChannels: Record<string, true> = {
  'agents:detect': true,
  'credentials:set': true,
  'credentials:state': true,
  'dashboard:overview': true,
  'overview:query': true,
  'overview:subagentBreakdown': true,
  'overview:dayModelBreakdown': true,
  'overview:dayProjectBreakdown': true,
  'index:fullReindex': true,
  'index:isScanning': true,
  'index:setRootEnabled': true,
  'index:status': true,
  'models:query': true,
  'models:trend': true,
  'notifications:state': true,
  'notifications:requestAuthorization': true,
  'projects:list': true,
  'projects:detail': true,
  'sessions:projects': true,
  'sessions:query': true,
  'sessions:trend': true,
  'settings:get': true,
  'settings:update': true,
  'window:setButtonsVisible': true
};

const allowedPreloadApiShape: Record<string, string[]> = {
  agents: ['detect'],
  credentials: ['set', 'state'],
  dashboard: ['queryOverview'],
  overview: ['dayModelBreakdown', 'dayProjectBreakdown', 'onInvalidate', 'onSessionEvent', 'query', 'subagentBreakdown'],
  index: ['isScanning', 'onScanProgress', 'setRootEnabled', 'startFullReindex', 'status'],
  models: ['query', 'trend'],
  notifications: ['requestAuthorization', 'state'],
  projects: ['detail', 'list'],
  sessions: ['projects', 'query', 'trend'],
  settings: ['get', 'update'],
  windowControls: ['setButtonsVisible']
};

function registerAndFindHandler(channel: string) {
  registerIpcHandlers();
  const handler = mockElectron.ipcHandlers.find((entry) => entry.channel === channel);
  expect(handler).toBeDefined();
  return handler?.listener as Parameters<IpcHandle>[1];
}

describe('Electron secure scaffold', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockElectron.ipcHandlers.length = 0;
    mockElectron.windowOptions.length = 0;
    mockElectron.windowButtonVisibility.length = 0;
    mockElectron.senderWindow = {
      setWindowButtonVisibility: (visible: boolean) => {
        mockElectron.windowButtonVisibility.push(visible);
      }
    };
    mockSettingsRepository.get.mockReturnValue({
      version: 3,
      menuBarPrimaryProviderId: 'codex',
      autoRefreshSeconds: 300,
      enabledAgentKinds: ['claudeCode', 'codex'],
      providerOverrides: []
    });
    mockSettingsRepository.update.mockReturnValue({ requestedVersion: 4, status: 'pending' });
    mockSessionsRepository.query.mockReturnValue({ items: [{ sessionKey: 'codex-session' }], total: 1 });
    mockIndexStatusRepository.status.mockReturnValue({ roots: [{ id: 1, displayName: 'Codex' }], runs: [], failedFiles: [] });
    mockIndexStatusRepository.isScanning.mockReturnValue(false);
  });

  it('registerIpcHandlers registers only the renderer IPC channel whitelist', () => {
    registerIpcHandlers();

    const registeredChannels = mockElectron.ipcHandlers.map((entry) => entry.channel);
    expect([...registeredChannels].sort()).toEqual(Object.keys(allowedIpcChannels).sort());

    for (const channel of registeredChannels) {
      expect(allowedIpcChannels[channel]).toBe(true);
    }
  });

  it('window:setButtonsVisible toggles the sender window buttons and coerces non-boolean payloads to false', async () => {
    const handler = registerAndFindHandler('window:setButtonsVisible');
    const event = { sender: { id: 1 } };

    await handler(event as never, true);
    await handler(event as never, false);
    await handler(event as never, 'yes');

    expect(mockElectron.windowButtonVisibility).toEqual([true, false, false]);
  });

  it('window:setButtonsVisible is a no-op when the sender window is already gone', async () => {
    const handler = registerAndFindHandler('window:setButtonsVisible');
    mockElectron.senderWindow = null;

    await expect(handler({ sender: {} } as never, true)).resolves.toBeUndefined();
    expect(mockElectron.windowButtonVisibility).toEqual([]);
  });

  it('creates the main BrowserWindow with Node disabled, isolated sandbox, and preload bundle path', () => {
    mockElectron.windowOptions.length = 0;

    createWindow();

    expect(mockElectron.windowOptions).toHaveLength(1);
    const webPreferences = mockElectron.windowOptions[0]?.webPreferences;

    expect(webPreferences).toMatchObject({
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true
    });
    expect(webPreferences?.preload).toEqual(expect.stringMatching(/[\\/]preload\.js$/));

    const packageJsonPath = path.join(path.dirname(fileURLToPath(import.meta.url)), '../../package.json');
    const packageJson = JSON.parse(readFileSync(packageJsonPath, 'utf8')) as { scripts?: Record<string, string> };
    const buildScript = packageJson.scripts?.build ?? '';
    expect(buildScript).toContain('vite build --mode preload');
    expect(buildScript).not.toContain('src/preload.ts');
  });

  it('exposes only window.tokenMeter whitelist APIs and never generic IPC, Node, fs, or sqlite access', () => {
    const tokenMeterExposure = mockElectron.exposedApis.find((exposure) => exposure.key === 'tokenMeter');
    expect(tokenMeterExposure).toBeDefined();

    const tokenMeterApi = tokenMeterExposure?.api ?? {};
    expect(Object.keys(tokenMeterApi).sort()).toEqual(Object.keys(allowedPreloadApiShape).sort());
    expect(tokenMeterApi).not.toHaveProperty('invoke');
    expect(tokenMeterApi).not.toHaveProperty('send');
    expect(tokenMeterApi).not.toHaveProperty('require');
    expect(tokenMeterApi).not.toHaveProperty('fs');
    expect(tokenMeterApi).not.toHaveProperty('sqlite');

    for (const [namespace, methods] of Object.entries(allowedPreloadApiShape)) {
      const namespaceApi = tokenMeterApi[namespace];
      expect(namespaceApi).toEqual(expect.any(Object));
      expect(Object.keys(namespaceApi as Record<string, unknown>).sort()).toEqual([...methods].sort());
      expect(namespaceApi).not.toHaveProperty('invoke');
      expect(namespaceApi).not.toHaveProperty('send');
    }

    const preloadSourcePath = path.join(path.dirname(fileURLToPath(import.meta.url)), '../preload.ts');
    const preloadSource = readFileSync(preloadSourcePath, 'utf8');
    const forbiddenPreloadImports: Record<string, RegExp> = {
      fs: /from\s+['"](?:node:)?fs(?:\/promises)?['"]|require\(['"](?:node:)?fs(?:\/promises)?['"]\)/,
      keychain: /from\s+['"][^'"]*keychain[^'"]*['"]|require\(['"][^'"]*keychain[^'"]*['"]\)/i,
      nodeRequire: /\brequire\s*\(/,
      sqlite: /from\s+['"][^'"]*sqlite[^'"]*['"]|require\(['"][^'"]*sqlite[^'"]*['"]\)/i
    };

    for (const [capability, pattern] of Object.entries(forbiddenPreloadImports)) {
      expect(preloadSource, `${capability} must not be reachable from preload or renderer API`).not.toMatch(pattern);
    }
  });

  it('settings:update writes through SettingsRepository and reports applied after Swift acknowledges the change', async () => {
    const patch = {
      menuBarPrimaryProviderId: 'claude-code',
      autoRefreshSeconds: 60,
      enabledAgentKinds: ['claudeCode', 'omp']
    };
    mockSwiftClient.notifySwift.mockResolvedValue({ ok: true, result: { status: 'settingsApplied' } });
    const updateHandler = registerAndFindHandler('settings:update');

    await expect(updateHandler({} as never, patch, 3)).resolves.toEqual({ requestedVersion: 4, status: 'applied' });

    expect(mockSettingsRepository.constructor).toHaveBeenCalledWith(mockDatabase.instance);
    expect(mockSettingsRepository.update).toHaveBeenCalledWith(patch, 3);
    expect(mockSwiftClient.notifySwift).toHaveBeenCalledWith('settingsChanged', { version: '4' });
  });

  it('settings:update surfaces Swift notification rejections with the requested version instead of returning silent pending', async () => {
    const patch = { autoRefreshSeconds: 60 };
    mockSwiftClient.notifySwift.mockRejectedValue(new Error('Swift IPC unavailable'));
    const updateHandler = registerAndFindHandler('settings:update');

    await expect(updateHandler({} as never, patch, 3)).resolves.toMatchObject({
      requestedVersion: 4,
      status: 'failed',
      error: {
        requestedVersion: 4,
        message: expect.stringContaining('Swift IPC unavailable')
      }
    });

    expect(mockSettingsRepository.update).toHaveBeenCalledWith(patch, 3);
    expect(mockSwiftClient.notifySwift).toHaveBeenCalledWith('settingsChanged', { version: '4' });
  });

  it('settings:update surfaces Swift failure responses with the requested version instead of reporting applied', async () => {
    const patch = { autoRefreshSeconds: 60 };
    mockSwiftClient.notifySwift.mockResolvedValue({ ok: false, error: 'settings reload failed' });
    const updateHandler = registerAndFindHandler('settings:update');

    await expect(updateHandler({} as never, patch, 3)).resolves.toMatchObject({
      requestedVersion: 4,
      status: 'failed',
      error: {
        requestedVersion: 4,
        message: expect.stringContaining('settings reload failed')
      }
    });

    expect(mockSettingsRepository.update).toHaveBeenCalledWith(patch, 3);
    expect(mockSwiftClient.notifySwift).toHaveBeenCalledWith('settingsChanged', { version: '4' });
  });

  it('settings:update returns a structured failed result when SQLite settings update rejects', async () => {
    const patch = { autoRefreshSeconds: 60 };
    mockSettingsRepository.update.mockImplementationOnce(() => {
      throw new Error('stale settings version: expected 3, actual 4');
    });
    const updateHandler = registerAndFindHandler('settings:update');

    await expect(updateHandler({} as never, patch, 3)).resolves.toMatchObject({
      requestedVersion: 3,
      status: 'failed',
      error: {
        requestedVersion: 3,
        message: expect.stringContaining('stale settings version')
      }
    });

    expect(mockSwiftClient.notifySwift).not.toHaveBeenCalled();
  });

  it('overview:query reads the assembled payload through OverviewRepository without renderer args', async () => {
    const payload = { dataState: 'needs-reindex' };
    mockOverviewRepository.buildOverview.mockReturnValue(payload);
    const overviewHandler = registerAndFindHandler('overview:query');

    await expect(overviewHandler({} as never, { ignored: true })).resolves.toBe(payload);

    expect(mockOverviewRepository.constructor).toHaveBeenCalledWith(mockDatabase.instance);
    expect(mockOverviewRepository.buildOverview).toHaveBeenCalledWith();
  });

  it('sessions:query reads through SessionsRepository with renderer filter args', async () => {
    const filter = { providerId: 'codex', limit: 25, offset: 50 };
    const sessionsHandler = registerAndFindHandler('sessions:query');

    await expect(sessionsHandler({} as never, filter)).resolves.toEqual({ items: [{ sessionKey: 'codex-session' }], total: 1 });

    expect(mockSessionsRepository.constructor).toHaveBeenCalledWith(mockDatabase.instance);
    expect(mockSessionsRepository.query).toHaveBeenCalledWith(filter);
  });

  it('models:query reads through ModelsRepository with renderer filter args', async () => {
    mockModelsRepository.query.mockReturnValue({ items: [{ model: 'gpt-5.6-sol' }] });
    const filter = { fromEpochMs: 1_000, toEpochMs: 2_000, sortBy: 'tokens' };
    const modelsHandler = registerAndFindHandler('models:query');

    await expect(modelsHandler({} as never, filter)).resolves.toEqual({ items: [{ model: 'gpt-5.6-sol' }] });

    expect(mockModelsRepository.constructor).toHaveBeenCalledWith(mockDatabase.instance);
    expect(mockModelsRepository.query).toHaveBeenCalledWith(filter);
  });

  it('index:status reads through IndexStatusRepository without renderer-supplied arguments', async () => {
    const indexStatusHandler = registerAndFindHandler('index:status');

    await expect(indexStatusHandler({} as never, { ignored: true })).resolves.toEqual({
      roots: [{ id: 1, displayName: 'Codex' }],
      runs: [],
      failedFiles: []
    });

    expect(mockIndexStatusRepository.constructor).toHaveBeenCalledWith(mockDatabase.instance);
    expect(mockIndexStatusRepository.status).toHaveBeenCalledWith();
  });

  it('index:isScanning returns the repository scan state without renderer-supplied arguments', async () => {
    mockIndexStatusRepository.isScanning.mockReturnValue(true);
    const isScanningHandler = registerAndFindHandler('index:isScanning');

    await expect(isScanningHandler({} as never, { ignored: true })).resolves.toBe(true);
    expect(mockIndexStatusRepository.isScanning).toHaveBeenCalledWith();
  });

  it('index:fullReindex streams through requestFullRescan, forwards progress, then invalidates the dashboard', async () => {
    // 关键行为变更：不再走 notifySwift('scanNow')（2 秒空闲超时，会在首次几分钟的索引里误报
    // timeout），改走流式的 requestFullRescan（30s 空闲超时）。requestFullRescan 内部的空闲超时
    // 语义——尤其是「开扫前沉默 3 秒不得拒绝」——由 tokenMeterSocketClient.test.ts 用真实的假
    // server + 真实的 requestFullRescan 在临时端口上验证；这里不绑定固定端口 47731，以免误连到
    // 正在运行的生产 App 并触发一次真实全量重扫。
    const progress = { kind: 'scan.progress', filesTotal: 3, filesDone: 1, bytesTotal: 100, bytesDone: 50, currentRoot: 'Claude' };
    mockSwiftClient.requestFullRescan.mockImplementation(async (onProgress: (event: unknown) => void) => {
      onProgress(progress);
    });
    const send = vi.fn();
    const fullReindexHandler = registerAndFindHandler('index:fullReindex');

    await expect(fullReindexHandler({ sender: { send } } as never)).resolves.toBeUndefined();

    expect(mockSwiftClient.requestFullRescan).toHaveBeenCalledTimes(1);
    // 不再依赖 notifySwift 的一问一答 2 秒超时路径。
    expect(mockSwiftClient.notifySwift).not.toHaveBeenCalled();
    expect(send).toHaveBeenNthCalledWith(1, 'index:scanProgress', progress);
    expect(send).toHaveBeenNthCalledWith(2, 'dashboard:invalidate');
  });

  /// 捕获 subscribeEvents 的回调，供测试手动注入 Swift 事件行。
  function captureSwiftEventCallback() {
    let onEvent: ((event: { kind: string; [key: string]: string }) => void) | undefined;
    mockSwiftClient.subscribeEvents.mockImplementation(
      (callback: (event: { kind: string; [key: string]: string }) => void) => {
        onEvent = callback;
        return () => {};
      }
    );
    const send = vi.fn();
    vi.mocked(BrowserWindow.getAllWindows).mockReturnValue([{ webContents: { send } } as never]);
    registerIpcHandlers();
    expect(onEvent).toBeDefined();
    return { emit: (event: Record<string, string>) => onEvent?.(event as never), send };
  }

  it('heartbeat/blocked session events flip card state only, without a full dashboard refetch', () => {
    // 心跳来自 PostToolUse，活跃对话约 2 秒一发；若每发都 invalidate，
    // renderer 会每 2 秒整页重取（用户实测：页面持续刷新 + CPU 高）。
    const { emit, send } = captureSwiftEventCallback();

    emit({ kind: 'agent.sessionEvent', agent: 'claudeCode', event: 'heartbeat', sessionId: 's-1' });
    emit({ kind: 'agent.sessionEvent', agent: 'codex', event: 'blocked', sessionId: 's-2' });

    expect(send).toHaveBeenCalledWith('session:stateChanged', {
      sourceKind: 'claude_jsonl',
      sessionKey: 's-1',
      event: 'heartbeat'
    });
    expect(send).toHaveBeenCalledWith('session:stateChanged', {
      sourceKind: 'codex_jsonl',
      sessionKey: 's-2',
      event: 'blocked'
    });
    expect(send).not.toHaveBeenCalledWith('dashboard:invalidate');
  });

  it('start/stop session events and data.changed still trigger the dashboard refetch', () => {
    // start 必须整页重取：新会话尚无索引行，占位卡要靠重新查询 sessionRail 才出现。
    const { emit, send } = captureSwiftEventCallback();

    emit({ kind: 'agent.sessionEvent', agent: 'claudeCode', event: 'start', sessionId: 's-1' });
    expect(send).toHaveBeenCalledWith('session:stateChanged', {
      sourceKind: 'claude_jsonl',
      sessionKey: 's-1',
      event: 'start'
    });
    expect(send).toHaveBeenCalledWith('dashboard:invalidate');

    send.mockClear();
    emit({ kind: 'agent.sessionEvent', agent: 'claudeCode', event: 'stop', sessionId: 's-1' });
    expect(send).toHaveBeenCalledWith('dashboard:invalidate');

    send.mockClear();
    emit({ kind: 'data.changed' });
    expect(send).toHaveBeenCalledWith('dashboard:invalidate');
    expect(send).toHaveBeenCalledTimes(1);
  });
});
