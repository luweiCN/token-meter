import { useEffect, useState } from 'react';

/// 全局页面 tip（用户裁定：成功/失败提示不再压在页面底部，统一浮在顶部）。
/// module 级单例：任何组件调 showToast，Layout 挂一个 ToastHost 渲染。

export interface Toast {
  kind: 'ok' | 'error';
  text: string;
}

let currentToast: Toast | null = null;
let listeners: Array<() => void> = [];

export function showToast(kind: Toast['kind'], text: string) {
  currentToast = { kind, text };
  for (const listener of listeners) listener();
}

/// 立即收起（module 单例，测试用例之间也靠它隔离残留）。
export function dismissToast() {
  currentToast = null;
  for (const listener of listeners) listener();
}

export function ToastHost() {
  const [toast, setToast] = useState<Toast | null>(currentToast);

  useEffect(() => {
    const listener = () => setToast(currentToast ? { ...currentToast } : null);
    listeners = [...listeners, listener];
    return () => {
      listeners = listeners.filter((item) => item !== listener);
    };
  }, []);

  useEffect(() => {
    if (!toast) return;
    // 失败停留更久，给用户读错误的时间。
    const timer = window.setTimeout(() => {
      currentToast = null;
      setToast(null);
    }, toast.kind === 'ok' ? 2400 : 6000);
    return () => window.clearTimeout(timer);
  }, [toast]);

  if (!toast) return null;
  return (
    <div className={`toast toast--${toast.kind}`} role="status">
      {toast.text}
    </div>
  );
}
