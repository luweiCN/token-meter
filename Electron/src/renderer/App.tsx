import { useCallback, useEffect, useState } from 'react';
import { createRoot } from 'react-dom/client';

import type { IndexStatusResult } from './api.js';
import { Layout, type RouteName } from './components/Layout.js';
import { parseUtcTimestamp } from './format.js';
import { Models } from './routes/Models.js';
import { Overview } from './routes/Overview.js';
import { Projects } from './routes/Projects.js';
import { Sessions } from './routes/Sessions.js';
import { Settings } from './routes/Settings.js';
import './styles.css';
// tailwind.css 在 styles.css 之后:utilities 未分层,与 styles.css 平级按
// specificity 竞争(shadcn 组件类稳赢元素级全局样式,详见 tailwind.css 头注)。
import './tailwind.css';

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
  const [isScanning, setIsScanning] = useState(false);

  // 概览页（Overview）自持数据与自动刷新；App 只维护索引状态摘要，
  // 供侧栏底部的「上次扫描」显示（索引状态明细已并入设置页数据区）。
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

  // 完整 index:status 会聚合文件/事件数，不适合高频轮询；扫描灯只查最新
  // scan_run 的轻量布尔值。短扫描来不及显示也无需闪烁，持续扫描会在 1s 内点亮。
  useEffect(() => {
    let cancelled = false;
    const refreshScanState = () => {
      void window.tokenMeter.index
        .isScanning()
        .then((active) => {
          if (!cancelled) setIsScanning(active);
        })
        .catch(() => {});
    };
    refreshScanState();
    const timer = window.setInterval(refreshScanState, 1_000);
    return () => {
      cancelled = true;
      window.clearInterval(timer);
    };
  }, []);

  // 自动扫描完成时 Swift 会发 data.changed；沿用 Overview 的失效事件刷新侧栏时间。
  useEffect(
    () => window.tokenMeter.overview.onInvalidate(() => {
      void refreshIndexStatus().catch(() => {});
    }),
    [refreshIndexStatus]
  );

  useEffect(() => {
    const handleFocus = () => {
      void refreshIndexStatus().catch(() => {});
    };
    window.addEventListener('focus', handleFocus);
    return () => {
      window.removeEventListener('focus', handleFocus);
    };
  }, [refreshIndexStatus]);

  const lastScanEpochMs =
    indexStatusState.kind === 'loaded'
      ? indexStatusState.status.roots.reduce<number | null>((latest, root) => {
          if (root.lastScanFinishedAt === null) return latest;
          const ms = parseUtcTimestamp(root.lastScanFinishedAt);
          if (Number.isNaN(ms)) return latest;
          return latest === null || ms > latest ? ms : latest;
        }, null)
      : null;

  return (
    <Layout route={route} onRoute={setRoute} lastScanEpochMs={lastScanEpochMs} isScanning={isScanning}>
      {route === 'dashboard' && <Overview />}
      {route === 'projects' && <Projects />}
      {route === 'sessions' && <Sessions />}
      {route === 'models' && <Models />}
      {route === 'settings' && <Settings />}
    </Layout>
  );
}

const root = document.getElementById('root');
if (root !== null) {
  createRoot(root).render(<AppShell />);
}
