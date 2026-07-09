import { useCallback, useEffect, useState } from 'react';
import { createRoot } from 'react-dom/client';

import type { DashboardOverview, IndexStatusResult } from './api.js';
import { Layout, type RouteName } from './components/Layout.js';
import { Dashboard } from './routes/Dashboard.js';
import { IndexStatus } from './routes/IndexStatus.js';
import { Sessions } from './routes/Sessions.js';
import { Settings } from './routes/Settings.js';
import './styles.css';

export type IndexStatusState =
  | { kind: 'loading' }
  | { kind: 'loaded'; status: IndexStatusResult }
  | { kind: 'failed'; message: string };

export type DashboardOverviewState =
  | { kind: 'loading' }
  | { kind: 'loaded'; overview: DashboardOverview }
  | { kind: 'failed'; message: string };

function errorMessage(unknownError: unknown, fallback: string) {
  return unknownError instanceof Error ? unknownError.message : fallback;
}

function indexStatusErrorMessage(unknownError: unknown) {
  return errorMessage(unknownError, '索引状态加载失败');
}

function dashboardErrorMessage(unknownError: unknown) {
  return errorMessage(unknownError, '概览数据加载失败');
}

export function AppShell() {
  const [route, setRoute] = useState<RouteName>('dashboard');
  const [indexStatusState, setIndexStatusState] = useState<IndexStatusState>({ kind: 'loading' });
  const [dashboardOverviewState, setDashboardOverviewState] = useState<DashboardOverviewState>({ kind: 'loading' });

  const refreshIndexStatus = useCallback(async () => {
    try {
      setIndexStatusState({ kind: 'loaded', status: await window.tokenMeter.index.status() });
    } catch (unknownError: unknown) {
      const message = indexStatusErrorMessage(unknownError);
      setIndexStatusState({ kind: 'failed', message });
      throw new Error(message);
    }
  }, []);

  const refreshDashboardOverview = useCallback(async () => {
    try {
      setDashboardOverviewState({ kind: 'loaded', overview: await window.tokenMeter.dashboard.queryOverview() });
    } catch (unknownError: unknown) {
      const message = dashboardErrorMessage(unknownError);
      setDashboardOverviewState({ kind: 'failed', message });
      throw new Error(message);
    }
  }, []);

  const refreshAppData = useCallback(async () => {
    const results = await Promise.allSettled([refreshIndexStatus(), refreshDashboardOverview()]);
    const rejected = results.find((result): result is PromiseRejectedResult => result.status === 'rejected');
    if (rejected) throw rejected.reason;
  }, [refreshDashboardOverview, refreshIndexStatus]);

  useEffect(() => {
    let cancelled = false;
    void Promise.allSettled([
      window.tokenMeter.index.status(),
      window.tokenMeter.dashboard.queryOverview()
    ]).then(([indexResult, overviewResult]) => {
      if (cancelled) return;
      if (indexResult.status === 'fulfilled') {
        setIndexStatusState({ kind: 'loaded', status: indexResult.value });
      } else {
        setIndexStatusState({ kind: 'failed', message: indexStatusErrorMessage(indexResult.reason) });
      }
      if (overviewResult.status === 'fulfilled') {
        setDashboardOverviewState({ kind: 'loaded', overview: overviewResult.value });
      } else {
        setDashboardOverviewState({ kind: 'failed', message: dashboardErrorMessage(overviewResult.reason) });
      }
    });

    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    const handleFocus = () => {
      void refreshAppData().catch(() => {});
    };
    window.addEventListener('focus', handleFocus);
    return () => {
      window.removeEventListener('focus', handleFocus);
    };
  }, [refreshAppData]);

  return (
    <Layout route={route} onRoute={setRoute}>
      {route === 'dashboard' && <Dashboard indexState={indexStatusState} overviewState={dashboardOverviewState} onRefresh={refreshAppData} />}
      {route === 'sessions' && <Sessions />}
      {route === 'index' && <IndexStatus indexState={indexStatusState} onRefresh={refreshAppData} />}
      {route === 'settings' && <Settings />}
    </Layout>
  );
}

const root = document.getElementById('root');
if (root !== null) {
  createRoot(root).render(<AppShell />);
}
