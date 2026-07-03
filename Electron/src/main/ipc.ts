import { ipcMain } from 'electron';

export function registerIpcHandlers() {
  ipcMain.handle('settings:get', async () => ({ version: 0, providerOverrides: [] }));
  ipcMain.handle('settings:update', async (_event, _patch, _expectedVersion) => ({ requestedVersion: 1, status: 'pending' }));
  ipcMain.handle('dashboard:overview', async () => ({ providers: [], totalTokens: 0 }));
  ipcMain.handle('dashboard:dailyUsage', async () => []);
  ipcMain.handle('sessions:query', async () => ({ items: [], total: 0 }));
  ipcMain.handle('index:status', async () => ({ runs: [], roots: [] }));
  ipcMain.handle('index:fullReindex', async () => ({ status: 'queued' }));
}
