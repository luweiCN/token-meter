import type { BrowserWindowConstructorOptions, IpcMain } from 'electron';
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
  windowOptions: [] as BrowserWindowConstructorOptions[]
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
  dailyUsage: vi.fn()
}));

const mockSessionsRepository = vi.hoisted(() => ({
  constructor: vi.fn(),
  query: vi.fn()
}));

const mockIndexStatusRepository = vi.hoisted(() => ({
  constructor: vi.fn(),
  status: vi.fn()
}));

const mockSwiftClient = vi.hoisted(() => ({
  notifySwift: vi.fn()
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
      dailyUsage: mockDashboardRepository.dailyUsage
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
      status: mockIndexStatusRepository.status
    };
  })
}));

vi.mock('./tokenMeterSocketClient.js', () => ({
  notifySwift: mockSwiftClient.notifySwift
}));

vi.mock('electron', () => ({
  app: {
    on: vi.fn(),
    quit: vi.fn(),
    whenReady: vi.fn(() => ({ then: vi.fn() }))
  },
  BrowserWindow: vi.fn(function BrowserWindowMock(options: BrowserWindowConstructorOptions) {
    mockElectron.windowOptions.push(options);

    return {
      loadFile: vi.fn(),
      loadURL: vi.fn()
    };
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
  'dashboard:dailyUsage': true,
  'dashboard:overview': true,
  'index:fullReindex': true,
  'index:status': true,
  'sessions:query': true,
  'settings:get': true,
  'settings:update': true
};

const allowedPreloadApiShape: Record<string, string[]> = {
  dashboard: ['queryDailyUsage', 'queryOverview'],
  index: ['startFullReindex', 'status'],
  sessions: ['query'],
  settings: ['get', 'update']
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
    mockSettingsRepository.get.mockReturnValue({
      version: 3,
      menuBarPrimaryProviderId: 'codex',
      autoRefreshSeconds: 300,
      enabledAgentKinds: ['claudeCode', 'codex'],
      providerOverrides: []
    });
    mockSettingsRepository.update.mockReturnValue({ requestedVersion: 4, status: 'pending' });
    mockDashboardRepository.dailyUsage.mockReturnValue([
      { usageDate: '2026-07-03', providerId: 'codex', sourceKind: 'codex_jsonl', tokensTotal: 185 }
    ]);
    mockSessionsRepository.query.mockReturnValue({ items: [{ sessionKey: 'codex-session' }], total: 1 });
    mockIndexStatusRepository.status.mockReturnValue({ roots: [{ id: 1, displayName: 'Codex' }], runs: [], failedFiles: [] });
  });

  it('registerIpcHandlers registers only the renderer IPC channel whitelist', () => {
    registerIpcHandlers();

    const registeredChannels = mockElectron.ipcHandlers.map((entry) => entry.channel);
    expect([...registeredChannels].sort()).toEqual(Object.keys(allowedIpcChannels).sort());

    for (const channel of registeredChannels) {
      expect(allowedIpcChannels[channel]).toBe(true);
    }
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

  it('settings:update still returns the pending repository result when Swift notification fails', async () => {
    const patch = { autoRefreshSeconds: 60 };
    mockSwiftClient.notifySwift.mockRejectedValue(new Error('Swift IPC unavailable'));
    const updateHandler = registerAndFindHandler('settings:update');

    await expect(updateHandler({} as never, patch, 3)).resolves.toEqual({ requestedVersion: 4, status: 'pending' });

    expect(mockSettingsRepository.update).toHaveBeenCalledWith(patch, 3);
    expect(mockSwiftClient.notifySwift).toHaveBeenCalledWith('settingsChanged', { version: '4' });
  });

  it('dashboard:dailyUsage reads through DashboardRepository with renderer filter args', async () => {
    const filter = { from: '2026-07-01', to: '2026-07-04', providerId: 'codex', projectId: 10 };
    const dailyUsageHandler = registerAndFindHandler('dashboard:dailyUsage');

    await expect(dailyUsageHandler({} as never, filter)).resolves.toEqual([
      { usageDate: '2026-07-03', providerId: 'codex', sourceKind: 'codex_jsonl', tokensTotal: 185 }
    ]);

    expect(mockDashboardRepository.constructor).toHaveBeenCalledWith(mockDatabase.instance);
    expect(mockDashboardRepository.dailyUsage).toHaveBeenCalledWith(filter);
  });

  it('sessions:query reads through SessionsRepository with renderer filter args', async () => {
    const filter = { providerId: 'codex', limit: 25, offset: 50 };
    const sessionsHandler = registerAndFindHandler('sessions:query');

    await expect(sessionsHandler({} as never, filter)).resolves.toEqual({ items: [{ sessionKey: 'codex-session' }], total: 1 });

    expect(mockSessionsRepository.constructor).toHaveBeenCalledWith(mockDatabase.instance);
    expect(mockSessionsRepository.query).toHaveBeenCalledWith(filter);
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
});
