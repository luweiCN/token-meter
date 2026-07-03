import { contextBridge, ipcRenderer } from 'electron';

contextBridge.exposeInMainWorld('tokenMeter', {
  settings: {
    get: () => ipcRenderer.invoke('settings:get'),
    update: (patch: unknown, expectedVersion: number) => ipcRenderer.invoke('settings:update', patch, expectedVersion)
  },
  dashboard: {
    queryOverview: (filter: unknown) => ipcRenderer.invoke('dashboard:overview', filter),
    queryDailyUsage: (filter: unknown) => ipcRenderer.invoke('dashboard:dailyUsage', filter)
  },
  sessions: {
    query: (filter: unknown) => ipcRenderer.invoke('sessions:query', filter)
  },
  index: {
    status: () => ipcRenderer.invoke('index:status'),
    startFullReindex: (rootId?: string) => ipcRenderer.invoke('index:fullReindex', rootId)
  }
});
