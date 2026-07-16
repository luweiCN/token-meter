import { BrowserWindow, ipcMain } from 'electron';
import { DashboardRepository } from './dashboardRepository.js';
import { IndexStatusRepository } from './indexStatusRepository.js';
import { ModelsRepository } from './modelsRepository.js';
import { OverviewRepository } from './overviewRepository.js';
import { SessionsRepository } from './sessionsRepository.js';

import { openTokenMeterDatabase } from './database.js';
import { ProjectsRepository } from './projectsRepository.js';
import { SettingsRepository } from './settingsRepository.js';
import { notifySwift, requestFullRescan, subscribeEvents } from './tokenMeterSocketClient.js';

export function registerIpcHandlers() {
  const db = openTokenMeterDatabase();
  const settings = new SettingsRepository(db);
  const dashboard = new DashboardRepository(db);
  const overview = new OverviewRepository(db);
  const sessions = new SessionsRepository(db);
  const projects = new ProjectsRepository(db);
  const indexStatus = new IndexStatusRepository(db);
  const models = new ModelsRepository(db);
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
  ipcMain.handle('overview:dayProjectBreakdown', async (_event, date: string) => overview.dayProjectBreakdown(date));
  ipcMain.handle('sessions:query', async (_event, filter) => sessions.query(filter));
  ipcMain.handle('models:query', async (_event, filter) => models.query(filter));
  ipcMain.handle('sessions:projects', async () => sessions.projects());
  ipcMain.handle('projects:list', async () => projects.list());
  ipcMain.handle('projects:detail', async (_event, projectId: number) => projects.detail(Number(projectId)));
  ipcMain.handle('index:status', async () => indexStatus.status());
  ipcMain.handle('index:setRootEnabled', async (_event, id: number, enabled: boolean) => {
    indexStatus.setRootEnabled(Number(id), enabled === true);
  });
  // 全量重扫走流式路径：Swift 端要跑几分钟才写第一个字节，旧的 notifySwift('scanNow') 会在 2 秒
  // 空闲超时后误报 timeout（扫描其实在跑）。requestFullRescan 用 30s 空闲超时并逐条转发进度。
  ipcMain.handle('index:fullReindex', async (event) => {
    await requestFullRescan((progress) => {
      event.sender.send('index:scanProgress', progress);
    });
    event.sender.send('dashboard:invalidate');
  });
  // 应用内 API Key 存 macOS 钥匙串，读写都在 Swift 侧——Electron 只转发、不落明文。
  ipcMain.handle('credentials:set', async (_event, providerId: string, token: string) => {
    const response = await notifySwift('credentials.set', { providerId: String(providerId), token: String(token ?? '') });
    return response.result?.hasToken === 'true';
  });
  ipcMain.handle('credentials:state', async (_event, providerId: string) => {
    try {
      const response = await notifySwift('credentials.state', { providerId: String(providerId) });
      return response.result?.hasToken === 'true';
    } catch {
      return null;
    }
  });
  // agent CLI 检测由 Swift 执行（登录 shell PATH + --version 探测），设置页 A 区消费。
  // Swift 未运行时返回 null，页面按「检测不可用」展示。
  ipcMain.handle('agents:detect', async () => {
    try {
      // 4 个 CLI 串行 --version 最多几秒到 20s（node 启动慢），放宽超时。
      const response = await notifySwift('agents.detect', {}, { timeoutMs: 30_000 });
      return JSON.parse(response.result?.agents ?? '[]');
    } catch {
      return null;
    }
  });
  // macOS 通知授权只能由 Swift app 发起（UNUserNotificationCenter 归属 app bundle），
  // 设置页 D 区经此转发。Swift 未运行时回落 unknown，页面按「无法确认」展示。
  ipcMain.handle('notifications:state', async () => {
    try {
      const response = await notifySwift('notifications.state');
      return response.result?.state ?? 'unknown';
    } catch {
      return 'unknown';
    }
  });
  ipcMain.handle('notifications:requestAuthorization', async () => {
    try {
      // 系统授权弹窗要等用户点，2s 默认超时必误报——放宽到 60s。
      const response = await notifySwift('notifications.requestAuthorization', {}, { timeoutMs: 60_000 });
      return response.result?.state ?? 'unknown';
    } catch {
      return 'unknown';
    }
  });
  // 顶部栏（紧凑）布局把 logo 顶到左上角，原生红绿灯会压在上面。renderer 在
  // 紧凑布局下默认藏起按钮、悬停左上角热区才显示（setWindowButtonVisibility 仅 macOS）。
  ipcMain.handle('window:setButtonsVisible', async (event, visible) => {
    BrowserWindow.fromWebContents(event.sender)?.setWindowButtonVisibility(visible === true);
  });
  // Swift 事件推送 → 全窗口失效通知：hooks 上报（会话点亮/熄灭）与扫描完成
  // （data.changed）都触发 Overview 重取，实时性不再只依赖 60s 轮询兜底。
  // agent.sessionEvent 额外转发带细节的 session:stateChanged——renderer 先把
  // 匹配卡片的状态就地翻转（约百毫秒级），随后的全量重取只是校准。
  const AGENT_TO_SOURCE_KIND: Record<string, string> = {
    claudeCode: 'claude_jsonl',
    codex: 'codex_jsonl',
    omp: 'omp_jsonl',
    opencode: 'opencode_sqlite'
  };
  subscribeEvents((event) => {
    if (event.kind !== 'agent.sessionEvent' && event.kind !== 'data.changed') return;
    // heartbeat/blocked（PostToolUse 心跳，活跃对话约 2 秒一发）只做局部翻卡；
    // 整页重取留给低频事件：start（新会话占位卡要靠重新查询才出现）、stop、
    // 以及扫描完成的 data.changed——否则 renderer 每 2 秒整页重取。
    const isSessionEvent = event.kind === 'agent.sessionEvent';
    const shouldInvalidate = !isSessionEvent || event.event === 'start' || event.event === 'stop';
    for (const window of BrowserWindow.getAllWindows()) {
      if (isSessionEvent) {
        const sourceKind = AGENT_TO_SOURCE_KIND[event.agent];
        if (sourceKind && event.sessionId) {
          window.webContents.send('session:stateChanged', {
            sourceKind,
            sessionKey: event.sessionId,
            event: event.event
          });
        }
      }
      if (shouldInvalidate) {
        window.webContents.send('dashboard:invalidate');
      }
    }
  });
}
