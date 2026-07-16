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
/// - 单飞 + 尾随合并：一次刷新在途时不起第二次（定时轮询与事件会撞在一起，一次慢查询
///   期间不去重就能堆出五个并发查询），但在途期间到达的请求【不能丢】——hooks 事件驱动的
///   dashboard:invalidate 若恰好撞上慢查询被丢弃，新状态要等下一个 60s 轮询才显示
///   （用户实测「agent 状态变化滞后」的根因之一）。合并成一个尾随标记：当前完成后立即补跑一次。
/// - 卸载时清理计时器：不清理的 interval 会在热重载里叠加，页面看着正常，CPU 却在空转。
export function useAutoRefresh(
  refresh: () => Promise<void>,
  { intervalMs }: AutoRefreshOptions
): () => Promise<void> {
  const refreshRef = useRef(refresh);
  refreshRef.current = refresh;
  const inFlightRef = useRef<Promise<void> | null>(null);
  const trailingRef = useRef(false);

  // 返回本次刷新落定的 promise：手动刷新按钮据此显示 loading。在途时合并进
  // 尾随补跑并返回在途的 promise（按钮等到的是「最近一次数据落地」，足够）。
  const refreshNow = useCallback((): Promise<void> => {
    if (inFlightRef.current) {
      trailingRef.current = true;                    // 在途：合并成一次尾随补跑，不丢更新
      return inFlightRef.current;
    }
    const flight = Promise.resolve(refreshRef.current()).finally(() => {
      inFlightRef.current = null;
      if (trailingRef.current) {
        trailingRef.current = false;
        void refreshNow();
      }
    });
    inFlightRef.current = flight;
    return flight;
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
        void refreshNow();                           // 再次可见立即补取一次
        startTimer();
      }
    };

    void refreshNow();                               // 挂载先取一次
    startTimer();
    document.addEventListener('visibilitychange', onVisibility);

    return () => {
      document.removeEventListener('visibilitychange', onVisibility);
      stopTimer();
    };
  }, [intervalMs, refreshNow]);

  return refreshNow;
}
