import type { ReactNode } from 'react';

export type RouteName = 'dashboard' | 'sessions' | 'index' | 'settings';

const navItems: Array<{ route: RouteName; label: string }> = [
  { route: 'dashboard', label: 'Dashboard' },
  { route: 'sessions', label: 'Sessions' },
  { route: 'index', label: 'Index Status' },
  { route: 'settings', label: 'Settings' }
];

export function Layout({ route, onRoute, children }: { route: RouteName; onRoute: (route: RouteName) => void; children: ReactNode }) {
  return (
    <main className="app-shell">
      <aside className="sidebar">
        <div className="brand-block">
          <span className="brand-mark" aria-hidden="true">TM</span>
          <strong>TokenMeter</strong>
        </div>
        <nav aria-label="Primary">
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
