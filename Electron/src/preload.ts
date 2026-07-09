import { contextBridge, ipcRenderer } from 'electron';
import type { SessionsFilter, SettingsPatch } from './renderer/api.js';


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
    // 事件驱动刷新：Swift 扫描完成 → 主进程发 dashboard:invalidate。renderer 收到后
    // 走单飞守卫重取，不会与轮询堆并发。返回取消订阅函数，供组件卸载时清理。
    onInvalidate: (callback: () => void) => {
      const listener = () => callback();
      ipcRenderer.on('dashboard:invalidate', listener);
      return () => ipcRenderer.removeListener('dashboard:invalidate', listener);
    }
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
