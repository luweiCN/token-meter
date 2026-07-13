import { app, BrowserWindow } from 'electron';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { registerIpcHandlers } from './ipc.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// dev 模式用独立的用户数据目录：与正式安装版共用时触发 Chromium 的
// singleton 冲突，后启动的实例白屏或直接退出。
if (process.env.VITE_DEV_SERVER_URL) {
  app.setPath('userData', `${app.getPath('userData')}-dev`);
}

// 同一份 userData 只允许一个实例：重复启动（连点两次「打开应用」）的
// 第二个实例同样会撞 singleton 白屏——拿不到锁就退出，把已有窗口带到前台。
if (!app.requestSingleInstanceLock()) {
  app.quit();
}
app.on('second-instance', () => {
  const window = getMainWindow();
  if (window) {
    if (window.isMinimized()) window.restore();
    window.show();
    window.focus();
  }
});

let mainWindow: BrowserWindow | null = null;

export function getMainWindow(): BrowserWindow | null {
  return mainWindow;
}

export function createWindow(): BrowserWindow {
  const window = new BrowserWindow({
    width: 1180,
    height: 760,
    // 概览页在约 720px 以下无处可去（右栏已收进浮层、主区已单列），设下限止损（spec §7.5）。
    minWidth: 720,
    // OpenDesign 稿：红绿灯融进侧栏顶部（.sidebar-drag 留出拖拽区）。
    titleBarStyle: 'hiddenInset',
    webPreferences: {
      preload: path.join(__dirname, '../preload.js'),
      nodeIntegration: false,
      contextIsolation: true,
      sandbox: true
    }
  });

  mainWindow = window;
  window.on('closed', () => {
    if (mainWindow === window) {
      mainWindow = null;
    }
  });

  if (process.env.VITE_DEV_SERVER_URL) {
    void window.loadURL(process.env.VITE_DEV_SERVER_URL);
  } else {
    void window.loadFile(path.join(__dirname, '../../dist-renderer/index.html'));
  }

  focusMainWindow();

  return window;
}

export function focusMainWindow(): void {
  if (!mainWindow) {
    createWindow();
    return;
  }

  if (mainWindow.isMinimized()) {
    mainWindow.restore();
  }

  mainWindow.show();
  mainWindow.focus();
  app.focus({ steal: true });
}

export function registerAppLifecycle(): void {
  if (!app.requestSingleInstanceLock()) {
    app.quit();
    return;
  }

  app.on('second-instance', () => {
    focusMainWindow();
  });

  app.whenReady().then(() => {
    registerIpcHandlers();
    createWindow();
  });

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
      return;
    }

    focusMainWindow();
  });

  app.on('window-all-closed', () => {
    if (process.platform !== 'darwin') app.quit();
  });
}

registerAppLifecycle();
