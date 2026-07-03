import { useState } from 'react';
import { createRoot } from 'react-dom/client';

import { Layout, type RouteName } from './components/Layout.js';
import { Dashboard } from './routes/Dashboard.js';
import { IndexStatus } from './routes/IndexStatus.js';
import { Sessions } from './routes/Sessions.js';
import { Settings } from './routes/Settings.js';
import './styles.css';

export function AppShell() {
  const [route, setRoute] = useState<RouteName>('dashboard');

  return (
    <Layout route={route} onRoute={setRoute}>
      {route === 'dashboard' && <Dashboard />}
      {route === 'sessions' && <Sessions />}
      {route === 'index' && <IndexStatus />}
      {route === 'settings' && <Settings />}
    </Layout>
  );
}

const root = document.getElementById('root');
if (root !== null) {
  createRoot(root).render(<AppShell />);
}
