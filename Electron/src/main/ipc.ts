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
    try {
      const result = settings.update(patch, expectedVersion);
      try {
        const response = await notifySwift('settingsChanged', { version: String(result.requestedVersion) });
        if (!response.ok) {
          throw new Error(response.error ?? 'TokenMeter Swift IPC returned an error');
        }
        return { ...result, status: 'applied' };
      } catch (error) {
        const message = error instanceof Error ? error.message : 'Unknown Swift IPC failure';
        return {
          ...result,
          status: 'failed',
          error: { requestedVersion: result.requestedVersion, message }
        };
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Unknown settings update failure';
      const requestedVersion = typeof expectedVersion === 'number' && Number.isFinite(expectedVersion) ? expectedVersion : 0;
      return {
        requestedVersion,
        status: 'failed',
        error: { requestedVersion, message }
      };
    }
  });
  ipcMain.handle('dashboard:overview', async () => dashboard.overview());
  ipcMain.handle('dashboard:dailyUsage', async (_event, filter) => dashboard.dailyUsage(filter));
  ipcMain.handle('sessions:query', async (_event, filter) => sessions.query(filter));
  ipcMain.handle('index:status', async () => indexStatus.status());
  ipcMain.handle('index:fullReindex', async () => notifySwift('scanNow'));
}
