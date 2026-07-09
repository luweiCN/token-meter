import type { ReactNode } from 'react';

export type RouteName = 'dashboard' | 'sessions' | 'index' | 'settings';

const navItems: Array<{ route: RouteName; label: string }> = [
  { route: 'dashboard', label: '概览' },
  { route: 'sessions', label: '会话' },
  { route: 'index', label: '索引状态' },
  { route: 'settings', label: '设置' }
];

export function Layout({ route, onRoute, children }: { route: RouteName; onRoute: (route: RouteName) => void; children: ReactNode }) {
  return (
    <main className="app-shell">
      <aside className="sidebar">
        <div className="brand-block">
          <span className="brand-mark" aria-hidden="true">TM</span>
          <strong>TokenMeter</strong>
        </div>
        <nav aria-label="主导航">
          {navItems.map((item) => (
            <button
              key={item.route}
              type="button"
              className={route === item.route ? 'active' : ''}
              aria-current={route === item.route ? 'page' : undefined}
              onClick={() => onRoute(item.route)}
            >
              {item.label}
            </button>
          ))}
        </nav>
      </aside>
      <section className="content">{children}</section>
    </main>
  );
}
