import { ipcMain } from 'electron';

import { openTokenMeterDatabase } from './database.js';
import { SettingsRepository } from './settingsRepository.js';
import { notifySwift } from './tokenMeterSocketClient.js';

export function registerIpcHandlers() {
  const settings = new SettingsRepository(openTokenMeterDatabase());

  ipcMain.handle('settings:get', async () => settings.get());
  ipcMain.handle('settings:update', async (_event, patch, expectedVersion) => {
    const result = settings.update(patch, expectedVersion);
    try {
      await notifySwift('settingsChanged', { version: String(result.requestedVersion) });
      return { ...result, status: 'applied' };
    } catch {
      return result;
    }
  });
  ipcMain.handle('dashboard:overview', async () => ({ providers: [], totalTokens: 0 }));
  ipcMain.handle('dashboard:dailyUsage', async () => []);
  ipcMain.handle('sessions:query', async () => ({ items: [], total: 0 }));
  ipcMain.handle('index:status', async () => ({ runs: [], roots: [] }));
  ipcMain.handle('index:fullReindex', async () => notifySwift('scanNow'));
}
