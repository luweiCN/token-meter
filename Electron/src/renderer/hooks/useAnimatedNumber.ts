import { useEffect, useRef, useState } from 'react';

const DEFAULT_DURATION_MS = 450;

function easeOutCubic(t: number): number {
  return 1 - Math.pow(1 - t, 3);
}

/// 数字变化时用短暂过渡代替瞬间跳变，让"刷新后数字变了"这件事本身可感知。
/// 首次挂载【不】animate——否则每次开窗口都要看着 KPI 从 0 爬到实际值，纯噪音，
/// 只在 value 真的变化时才动。若动画进行中 value 又变了，从当前显示位置
/// （而不是上一次的起点）继续插值到新目标，避免画面往回跳。
export function useAnimatedNumber(value: number, durationMs = DEFAULT_DURATION_MS): number {
  const [display, setDisplay] = useState(value);
  const displayRef = useRef(value);
  const mountedRef = useRef(false);
  const rafRef = useRef<number | undefined>(undefined);

  useEffect(() => {
    if (!mountedRef.current) {
      mountedRef.current = true;
      displayRef.current = value;
      setDisplay(value);
      return;
    }

    if (rafRef.current !== undefined) cancelAnimationFrame(rafRef.current);

    const from = displayRef.current;
    const delta = value - from;
    if (delta === 0) return;

    const start = performance.now();
    const tick = (now: number) => {
      const t = Math.min(1, (now - start) / durationMs);
      const next = from + delta * easeOutCubic(t);
      displayRef.current = next;
      setDisplay(next);
      if (t < 1) {
        rafRef.current = requestAnimationFrame(tick);
      }
    };
    rafRef.current = requestAnimationFrame(tick);

    return () => {
      if (rafRef.current !== undefined) cancelAnimationFrame(rafRef.current);
    };
  }, [value, durationMs]);

  return display;
}
