import type { BrowserWindowConstructorOptions, IpcMain } from 'electron';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it, vi } from 'vitest';

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

describe('Electron secure scaffold', () => {
  it('registerIpcHandlers registers only the renderer IPC channel whitelist', () => {
    mockElectron.ipcHandlers.length = 0;

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
});
