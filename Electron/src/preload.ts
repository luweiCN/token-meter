import { contextBridge, ipcRenderer } from 'electron';
import type { DailyUsageFilter, SessionsFilter, SettingsPatch } from './renderer/api.js';


contextBridge.exposeInMainWorld('tokenMeter', {
  settings: {
    get: () => ipcRenderer.invoke('settings:get'),
    update: (patch: SettingsPatch, expectedVersion: number) => ipcRenderer.invoke('settings:update', patch, expectedVersion)
  },
  dashboard: {
    queryOverview: () => ipcRenderer.invoke('dashboard:overview'),
    queryDailyUsage: (filter: DailyUsageFilter) => ipcRenderer.invoke('dashboard:dailyUsage', filter)
  },
  sessions: {
    query: (filter: SessionsFilter) => ipcRenderer.invoke('sessions:query', filter)
  },
  index: {
    status: () => ipcRenderer.invoke('index:status'),
    startFullReindex: (rootId?: string) => ipcRenderer.invoke('index:fullReindex', rootId),
    onScanProgress: (callback: (progress: unknown) => void) => {
      const listener = (_event: unknown, progress: unknown) => callback(progress);
      ipcRenderer.on('index:scanProgress', listener);
      return () => ipcRenderer.removeListener('index:scanProgress', listener);
    }
  }
});
