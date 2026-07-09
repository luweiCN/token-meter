import { useCallback, useEffect, useRef } from 'react';

export interface AutoRefreshOptions {
  intervalMs: number;
}

/// 事件驱动为主、轮询兜底的自动刷新，专为「常驻打开」的工具应用降空闲开销而写。
///
/// - 挂载时立即取一次：否则首屏是空的。
/// - 每 `intervalMs` 轮询一次，兜底事件驱动漏掉的更新。
/// - 窗口隐藏时【停掉计时器】（`document.visibilityState === 'hidden'` 一处守卫）：
///   这是常驻应用在被忽略时不再花任何代价的最直接一招。再次可见时立即补取一次——
///   只补一次，不是把隐藏期间跳过的每个 tick 都补回来。
/// - 单飞（in-flight 去重）：一次刷新在途时不起第二次。定时轮询与 `scan.finished`
///   事件会撞在一起，一次慢查询期间不去重就能堆出五个并发查询。返回的 `refreshNow`
///   与轮询共用这道守卫，事件触发的刷新也不会绕过它。
/// - 卸载时清理计时器：不清理的 interval 会在热重载里叠加，页面看着正常，CPU 却在空转。
export function useAutoRefresh(
  refresh: () => Promise<void>,
  { intervalMs }: AutoRefreshOptions
): () => void {
  const refreshRef = useRef(refresh);
  refreshRef.current = refresh;
  const inFlightRef = useRef(false);

  const refreshNow = useCallback(() => {
    if (inFlightRef.current) return;                 // 单飞：在途则跳过（轮询/可见/事件共用）
    inFlightRef.current = true;
    void Promise.resolve(refreshRef.current()).finally(() => {
      inFlightRef.current = false;
    });
  }, []);

  useEffect(() => {
    let timer: ReturnType<typeof setInterval> | undefined;

    const startTimer = () => {
      if (timer !== undefined) return;
      timer = setInterval(refreshNow, intervalMs);
    };
    const stopTimer = () => {
      if (timer !== undefined) {
        clearInterval(timer);
        timer = undefined;
      }
    };

    const onVisibility = () => {
      if (document.visibilityState === 'hidden') {
        stopTimer();                                 // 隐藏即暂停轮询
      } else {
        refreshNow();                                // 再次可见立即补取一次
        startTimer();
      }
    };

    refreshNow();                                    // 挂载先取一次
    startTimer();
    document.addEventListener('visibilitychange', onVisibility);

    return () => {
      document.removeEventListener('visibilitychange', onVisibility);
      stopTimer();
    };
  }, [intervalMs, refreshNow]);

  return refreshNow;
}
