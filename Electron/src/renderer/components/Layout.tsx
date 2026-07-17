import { useEffect, type ReactNode } from 'react';

import { formatRelative } from '../format.js';
import { applyThemePref, storedThemePref, watchSystemTheme } from '../theme.js';
import { ToastHost } from './toast.js';
import { TrafficLightHover } from './TrafficLightHover.js';

export type RouteName = 'dashboard' | 'projects' | 'sessions' | 'models' | 'settings';

/// 侧栏导航。索引状态已并入设置页「数据」区，不再单列。
const NAV: Array<{ route: RouteName; label: string; icon: ReactNode }> = [
  {
    route: 'dashboard',
    label: '总览',
    icon: (
      <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
        <path d="M1.5 12.5V8M5.5 12.5V4M9.5 12.5V6.5M13 12.5V1.5" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
      </svg>
    )
  },
  {
    route: 'projects',
    label: '项目',
    icon: (
      <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
        <path d="M1.5 4.5v6a1.5 1.5 0 0 0 1.5 1.5h8a1.5 1.5 0 0 0 1.5-1.5V5.8a1.5 1.5 0 0 0-1.5-1.5H7L5.6 2.6a1 1 0 0 0-.7-.3H3A1.5 1.5 0 0 0 1.5 3.8v.7Z" stroke="currentColor" strokeWidth="1.4" strokeLinejoin="round" />
      </svg>
    )
  },
  {
    route: 'sessions',
    label: '会话',
    icon: (
      <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
        <rect x="1.5" y="2" width="11" height="3" rx="1" stroke="currentColor" strokeWidth="1.4" />
        <rect x="1.5" y="9" width="11" height="3" rx="1" stroke="currentColor" strokeWidth="1.4" />
      </svg>
    )
  },
  {
    route: 'models',
    label: '模型',
    icon: (
      <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
        <path d="M7 1.5 12.5 4.5v5L7 12.5 1.5 9.5v-5L7 1.5Z" stroke="currentColor" strokeWidth="1.4" strokeLinejoin="round" />
        <path d="M1.5 4.5 7 7.5l5.5-3M7 7.5v5" stroke="currentColor" strokeWidth="1.4" strokeLinejoin="round" />
      </svg>
    )
  },
  {
    route: 'settings',
    label: '设置',
    icon: (
      <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
        <circle cx="7" cy="7" r="2" stroke="currentColor" strokeWidth="1.4" />
        <path d="M7 1v2M7 11v2M1 7h2M11 7h2M2.8 2.8l1.4 1.4M9.8 9.8l1.4 1.4M11.2 2.8 9.8 4.2M4.2 9.8l-1.4 1.4" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
      </svg>
    )
  }
];

export function Layout({
  route,
  onRoute,
  lastScanEpochMs,
  children
}: {
  route: RouteName;
  onRoute: (route: RouteName) => void;
  lastScanEpochMs: number | null;
  children: ReactNode;
}) {
  // 主题切换已收进设置页「外观」；这里启动时应用持久化的选择，
  // 偏好为「跟随系统」时订阅 macOS 外观变化即时跟随。
  useEffect(() => {
    applyThemePref(storedThemePref());
    return watchSystemTheme();
  }, []);

  return (
    <div className="app">
      <TrafficLightHover />
      <ToastHost />
      <aside className="sidebar">
        <div className="sidebar-drag" aria-hidden="true" />
        <div className="brand">
          <svg width="22" height="22" viewBox="0 0 22 22" fill="none" aria-hidden="true">
            <rect x="1" y="1" width="20" height="20" rx="5" stroke="var(--accent)" strokeWidth="1.6" />
            <path d="M6 13.5 9 8.5l2.6 3.6L14 6.5l2 7" stroke="var(--accent)" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
          <b>TokenMeter</b>
        </div>
        <nav className="nav" aria-label="主导航">
          {NAV.map((item) => (
            <button
              key={item.label}
              type="button"
              className={route === item.route ? 'on' : ''}
              aria-current={route === item.route ? 'page' : undefined}
              onClick={() => onRoute(item.route)}
            >
              {item.icon}
              {item.label}
            </button>
          ))}
        </nav>
        <div className="side-foot">
          <span className="scan">
            {lastScanEpochMs !== null ? `上次扫描 ${formatRelative(Date.now() - lastScanEpochMs)}` : '尚未扫描'}
          </span>
        </div>
      </aside>
      <main className="main">{children}</main>
    </div>
  );
}
