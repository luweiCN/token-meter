import { useEffect, useState, type ReactNode } from 'react';

import { formatRelative } from '../format.js';

export type RouteName = 'dashboard' | 'sessions' | 'index' | 'settings';

/// 侧栏按 OpenDesign 稿：6 个导航项。「项目」「查询」的页面稿未接入，先渲染禁用态，
/// 路由类型保持 4 个不变——禁用项不产生路由。
const NAV: Array<{ route?: RouteName; label: string; icon: ReactNode; disabled?: boolean }> = [
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
    label: '项目',
    disabled: true,
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
    route: 'index',
    label: '索引状态',
    icon: (
      <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
        <circle cx="7" cy="7" r="5.5" stroke="currentColor" strokeWidth="1.4" />
        <path d="M7 3.5V7l2.5 1.5" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
      </svg>
    )
  },
  {
    label: '查询',
    disabled: true,
    icon: (
      <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
        <circle cx="6" cy="6" r="4.4" stroke="currentColor" strokeWidth="1.4" />
        <path d="m9.4 9.4 3.1 3.1" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
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

type Theme = 'dark' | 'light';

function initialTheme(): Theme {
  return localStorage.getItem('tm-theme') === 'light' ? 'light' : 'dark';
}

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
  const [theme, setTheme] = useState<Theme>(initialTheme);

  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    localStorage.setItem('tm-theme', theme);
  }, [theme]);

  return (
    <div className="app">
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
              className={item.route !== undefined && route === item.route ? 'on' : ''}
              aria-current={item.route !== undefined && route === item.route ? 'page' : undefined}
              disabled={item.disabled}
              title={item.disabled ? '即将推出' : undefined}
              onClick={item.route !== undefined ? () => onRoute(item.route as RouteName) : undefined}
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
          <button
            type="button"
            className="theme-btn"
            title="切换外观"
            aria-label={theme === 'dark' ? '切换到浅色外观' : '切换到深色外观'}
            onClick={() => setTheme(theme === 'dark' ? 'light' : 'dark')}
          >
            {theme === 'dark' ? (
              <svg width="13" height="13" viewBox="0 0 13 13" fill="none" aria-hidden="true">
                <path d="M11.5 8.2A5 5 0 0 1 4.8 1.5a5 5 0 1 0 6.7 6.7Z" stroke="currentColor" strokeWidth="1.4" strokeLinejoin="round" />
              </svg>
            ) : (
              <svg width="13" height="13" viewBox="0 0 13 13" fill="none" aria-hidden="true">
                <circle cx="6.5" cy="6.5" r="2.6" stroke="currentColor" strokeWidth="1.4" />
                <path d="M6.5 0.8v1.6M6.5 10.6v1.6M0.8 6.5h1.6M10.6 6.5h1.6M2.5 2.5l1.1 1.1M9.4 9.4l1.1 1.1M10.5 2.5 9.4 3.6M3.6 9.4l-1.1 1.1" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
              </svg>
            )}
          </button>
        </div>
      </aside>
      <main className="main">{children}</main>
    </div>
  );
}
