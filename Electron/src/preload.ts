import { contextBridge, ipcRenderer } from 'electron';
import type { ModelsFilter, SessionsFilter, SettingsPatch } from './renderer/api.js';


contextBridge.exposeInMainWorld('tokenMeter', {
  settings: {
    get: () => ipcRenderer.invoke('settings:get'),
    update: (patch: SettingsPatch, expectedVersion: number) => ipcRenderer.invoke('settings:update', patch, expectedVersion)
  },
  dashboard: {
    queryOverview: () => ipcRenderer.invoke('dashboard:overview')
  },
  overview: {
    query: () => ipcRenderer.invoke('overview:query'),
    subagentBreakdown: (sessionId: number) => ipcRenderer.invoke('overview:subagentBreakdown', sessionId),
    dayModelBreakdown: (date: string) => ipcRenderer.invoke('overview:dayModelBreakdown', date),
    dayProjectBreakdown: (date: string) => ipcRenderer.invoke('overview:dayProjectBreakdown', date),
    // 事件驱动刷新：Swift 扫描完成 → 主进程发 dashboard:invalidate。renderer 收到后
    // 走单飞守卫重取，不会与轮询堆并发。返回取消订阅函数，供组件卸载时清理。
    onInvalidate: (callback: () => void) => {
      const listener = () => callback();
      ipcRenderer.on('dashboard:invalidate', listener);
      return () => ipcRenderer.removeListener('dashboard:invalidate', listener);
    },
    // hooks 事件的细节转发：renderer 据此就地翻转对应会话卡的状态，不等全量重取。
    onSessionEvent: (callback: (event: unknown) => void) => {
      const listener = (_event: unknown, payload: unknown) => callback(payload);
      ipcRenderer.on('session:stateChanged', listener);
      return () => ipcRenderer.removeListener('session:stateChanged', listener);
    }
  },
  sessions: {
    query: (filter: SessionsFilter) => ipcRenderer.invoke('sessions:query', filter),
    trend: (filter: SessionsFilter) => ipcRenderer.invoke('sessions:trend', filter),
    projects: () => ipcRenderer.invoke('sessions:projects')
  },
  models: {
    query: (filter: ModelsFilter) => ipcRenderer.invoke('models:query', filter),
    trend: (filter: ModelsFilter) => ipcRenderer.invoke('models:trend', filter)
  },
  projects: {
    list: () => ipcRenderer.invoke('projects:list'),
    detail: (projectId: number) => ipcRenderer.invoke('projects:detail', projectId)
  },
  index: {
    status: () => ipcRenderer.invoke('index:status'),
    setRootEnabled: (id: number, enabled: boolean) => ipcRenderer.invoke('index:setRootEnabled', id, enabled),
    startFullReindex: (rootId?: string) => ipcRenderer.invoke('index:fullReindex', rootId),
    onScanProgress: (callback: (progress: unknown) => void) => {
      const listener = (_event: unknown, progress: unknown) => callback(progress);
      ipcRenderer.on('index:scanProgress', listener);
      return () => ipcRenderer.removeListener('index:scanProgress', listener);
    }
  },
  agents: {
    detect: () => ipcRenderer.invoke('agents:detect')
  },
  credentials: {
    set: (providerId: string, token: string) => ipcRenderer.invoke('credentials:set', providerId, token),
    state: (providerId: string) => ipcRenderer.invoke('credentials:state', providerId)
  },
  notifications: {
    state: () => ipcRenderer.invoke('notifications:state'),
    requestAuthorization: () => ipcRenderer.invoke('notifications:requestAuthorization')
  },
  windowControls: {
    setButtonsVisible: (visible: boolean) => ipcRenderer.invoke('window:setButtonsVisible', visible)
  }
});
