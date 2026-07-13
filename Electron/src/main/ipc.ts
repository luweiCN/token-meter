import { ipcMain } from 'electron';
import { DashboardRepository } from './dashboardRepository.js';
import { IndexStatusRepository } from './indexStatusRepository.js';
import { OverviewRepository } from './overviewRepository.js';
import { SessionsRepository } from './sessionsRepository.js';

import { openTokenMeterDatabase } from './database.js';
import { SettingsRepository } from './settingsRepository.js';
import { notifySwift, requestFullRescan } from './tokenMeterSocketClient.js';

export function registerIpcHandlers() {
  const db = openTokenMeterDatabase();
  const settings = new SettingsRepository(db);
  const dashboard = new DashboardRepository(db);
  const overview = new OverviewRepository(db);
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
  ipcMain.handle('overview:query', async () => overview.buildOverview());
  ipcMain.handle('overview:subagentBreakdown', async (_event, sessionId: number) => overview.subagentBreakdown(sessionId));
  ipcMain.handle('overview:dayModelBreakdown', async (_event, date: string) => overview.dayModelBreakdown(date));
  ipcMain.handle('sessions:query', async (_event, filter) => sessions.query(filter));
  ipcMain.handle('index:status', async () => indexStatus.status());
  // 全量重扫走流式路径：Swift 端要跑几分钟才写第一个字节，旧的 notifySwift('scanNow') 会在 2 秒
  // 空闲超时后误报 timeout（扫描其实在跑）。requestFullRescan 用 30s 空闲超时并逐条转发进度。
  ipcMain.handle('index:fullReindex', async (event) => {
    await requestFullRescan((progress) => {
      event.sender.send('index:scanProgress', progress);
    });
    event.sender.send('dashboard:invalidate');
  });
}
