import type { BrowserWindowConstructorOptions } from 'electron';
import { beforeEach, describe, expect, it, vi } from 'vitest';

interface MockBrowserWindow {
  readonly options: BrowserWindowConstructorOptions;
  readonly closeHandlers: Array<() => void>;
  closed: boolean;
  minimized: boolean;
  loadFile: (filePath: string) => Promise<void>;
  loadURL: (url: string) => Promise<void>;
  on: (event: string, handler: () => void) => MockBrowserWindow;
  isMinimized: () => boolean;
  restore: () => void;
  focus: () => void;
  show: () => void;
}

interface AppHandler {
  readonly event: string;
  readonly handler: () => void;
}

const mockElectron = vi.hoisted(() => ({
  appHandlers: [] as AppHandler[],
  lockResult: true,
  quit: vi.fn(),
  focusApp: vi.fn(),
  requestSingleInstanceLock: vi.fn(() => mockElectron.lockResult),
  whenReadyCallbacks: [] as Array<() => void>,
  windows: [] as MockBrowserWindow[]
}));

const mockIpc = vi.hoisted(() => ({
  registerIpcHandlers: vi.fn()
}));

function makeWindow(options: BrowserWindowConstructorOptions): MockBrowserWindow {
  const window: MockBrowserWindow = {
    options,
    closeHandlers: [],
    closed: false,
    minimized: false,
    loadFile: vi.fn(async () => undefined),
    loadURL: vi.fn(async () => undefined),
    on: vi.fn((event: string, handler: () => void) => {
      if (event === 'closed') {
        window.closeHandlers.push(handler);
      }
      return window;
    }),
    isMinimized: vi.fn(() => window.minimized),
    restore: vi.fn(() => {
      window.minimized = false;
    }),
    focus: vi.fn(),
    show: vi.fn()
  };

  mockElectron.windows.push(window);
  return window;
}

function closeWindow(window: MockBrowserWindow): void {
  window.closed = true;
  for (const handler of window.closeHandlers) {
    handler();
  }
}

function findAppHandler(event: string): () => void {
  const match = mockElectron.appHandlers.find((entry) => entry.event === event);
  expect(match, `${event} handler should be registered`).toBeDefined();
  return match?.handler ?? (() => undefined);
}

vi.mock('electron', () => ({
  app: {
    focus: mockElectron.focusApp,
    on: vi.fn((event: string, handler: () => void) => {
      mockElectron.appHandlers.push({ event, handler });
    }),
    quit: mockElectron.quit,
    requestSingleInstanceLock: mockElectron.requestSingleInstanceLock,
    whenReady: vi.fn(() => ({
      then: vi.fn((handler: () => void) => {
        mockElectron.whenReadyCallbacks.push(handler);
      })
    }))
  },
  BrowserWindow: Object.assign(vi.fn(makeWindow), {
    getAllWindows: vi.fn(() => mockElectron.windows.filter((window) => !window.closed))
  })
}));

vi.mock('./ipc.js', () => ({
  registerIpcHandlers: mockIpc.registerIpcHandlers
}));

import { createWindow, getMainWindow, registerAppLifecycle } from './main.js';

describe('Electron main window lifecycle', () => {
  beforeEach(() => {
    for (const window of mockElectron.windows) {
      closeWindow(window);
    }

    mockElectron.appHandlers.length = 0;
    mockElectron.whenReadyCallbacks.length = 0;
    mockElectron.windows.length = 0;
    mockElectron.lockResult = true;
    vi.clearAllMocks();
  });

  it('keeps the BrowserWindow reachable until it closes', () => {
    const firstWindow = createWindow();
    const firstMockWindow = mockElectron.windows[0];

    expect(firstMockWindow).toBeDefined();
    expect(firstWindow).toBe(firstMockWindow);
    expect(getMainWindow()).toBe(firstMockWindow);
    expect(firstMockWindow?.show).toHaveBeenCalledOnce();
    expect(firstMockWindow?.focus).toHaveBeenCalledOnce();
    expect(mockElectron.focusApp).toHaveBeenCalledWith({ steal: true });

    closeWindow(firstMockWindow);

    expect(getMainWindow()).toBeNull();

    const secondWindow = createWindow();
    const secondMockWindow = mockElectron.windows[1];

    expect(secondWindow).not.toBe(firstWindow);
    expect(secondWindow).toBe(secondMockWindow);
    expect(getMainWindow()).toBe(secondMockWindow);
  });

  it('focuses the existing window when a second Electron instance starts', () => {
    registerAppLifecycle();
    createWindow();
    const window = mockElectron.windows[0];
    expect(window).toBeDefined();
    window.minimized = true;

    findAppHandler('second-instance')();

    expect(window.restore).toHaveBeenCalledOnce();
    expect(window.show).toHaveBeenCalledTimes(2);
    expect(window.focus).toHaveBeenCalledTimes(2);
    expect(mockElectron.focusApp).toHaveBeenLastCalledWith({ steal: true });

    vi.mocked(window.restore).mockClear();
    vi.mocked(window.focus).mockClear();
    vi.mocked(window.show).mockClear();
    window.minimized = false;

    findAppHandler('second-instance')();

    expect(window.restore).not.toHaveBeenCalled();
    expect(window.show).toHaveBeenCalledOnce();
    expect(window.focus).toHaveBeenCalledOnce();
  });

  it('creates a new window when macOS activates the app with no open windows', () => {
    registerAppLifecycle();

    findAppHandler('activate')();

    expect(mockElectron.windows).toHaveLength(1);
    expect(getMainWindow()).toBe(mockElectron.windows[0]);
  });
});
