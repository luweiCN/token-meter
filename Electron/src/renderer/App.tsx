import { useCallback, useEffect, useState } from 'react';
import { createRoot } from 'react-dom/client';

import type { IndexStatusResult } from './api.js';
import { Layout, type RouteName } from './components/Layout.js';
import { IndexStatus } from './routes/IndexStatus.js';
import { Overview } from './routes/Overview.js';
import { Sessions } from './routes/Sessions.js';
import { Settings } from './routes/Settings.js';
import './styles.css';

export type IndexStatusState =
  | { kind: 'loading' }
  | { kind: 'loaded'; status: IndexStatusResult }
  | { kind: 'failed'; message: string };

function errorMessage(unknownError: unknown, fallback: string) {
  return unknownError instanceof Error ? unknownError.message : fallback;
}

function indexStatusErrorMessage(unknownError: unknown) {
  return errorMessage(unknownError, '索引状态加载失败');
}

export function AppShell() {
  const [route, setRoute] = useState<RouteName>('dashboard');
  const [indexStatusState, setIndexStatusState] = useState<IndexStatusState>({ kind: 'loading' });

  // 概览页（Overview）自持数据与自动刷新；App 只负责索引状态，供「索引状态」页与重扫后刷新用。
  const refreshIndexStatus = useCallback(async () => {
    try {
      setIndexStatusState({ kind: 'loaded', status: await window.tokenMeter.index.status() });
    } catch (unknownError: unknown) {
      const message = indexStatusErrorMessage(unknownError);
      setIndexStatusState({ kind: 'failed', message });
      throw new Error(message);
    }
  }, []);

  useEffect(() => {
    let cancelled = false;
    void window.tokenMeter.index
      .status()
      .then((status) => {
        if (!cancelled) setIndexStatusState({ kind: 'loaded', status });
      })
      .catch((unknownError: unknown) => {
        if (!cancelled) setIndexStatusState({ kind: 'failed', message: indexStatusErrorMessage(unknownError) });
      });

    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    const handleFocus = () => {
      void refreshIndexStatus().catch(() => {});
    };
    window.addEventListener('focus', handleFocus);
    return () => {
      window.removeEventListener('focus', handleFocus);
    };
  }, [refreshIndexStatus]);

  return (
    <Layout route={route} onRoute={setRoute}>
      {route === 'dashboard' && <Overview />}
      {route === 'sessions' && <Sessions />}
      {route === 'index' && <IndexStatus indexState={indexStatusState} onRefresh={refreshIndexStatus} />}
      {route === 'settings' && <Settings />}
    </Layout>
  );
}

const root = document.getElementById('root');
if (root !== null) {
  createRoot(root).render(<AppShell />);
}
