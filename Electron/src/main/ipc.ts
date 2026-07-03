import { ipcMain } from 'electron';
import { DashboardRepository } from './dashboardRepository.js';
import { IndexStatusRepository } from './indexStatusRepository.js';
import { SessionsRepository } from './sessionsRepository.js';

import { openTokenMeterDatabase } from './database.js';
import { SettingsRepository } from './settingsRepository.js';
import { notifySwift } from './tokenMeterSocketClient.js';

export function registerIpcHandlers() {
  const db = openTokenMeterDatabase();
  const settings = new SettingsRepository(db);
  const dashboard = new DashboardRepository(db);
  const sessions = new SessionsRepository(db);
  const indexStatus = new IndexStatusRepository(db);
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
  ipcMain.handle('dashboard:dailyUsage', async (_event, filter) => dashboard.dailyUsage(filter));
  ipcMain.handle('sessions:query', async (_event, filter) => sessions.query(filter));
  ipcMain.handle('index:status', async () => indexStatus.status());
  ipcMain.handle('index:fullReindex', async () => notifySwift('scanNow'));
}
