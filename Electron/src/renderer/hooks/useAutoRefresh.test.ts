// @vitest-environment jsdom

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { useAutoRefresh } from './useAutoRefresh.js';

function setVisibility(state: 'visible' | 'hidden') {
  Object.defineProperty(document, 'visibilityState', { value: state, configurable: true });
  document.dispatchEvent(new Event('visibilitychange'));
}

beforeEach(() => { vi.useFakeTimers(); setVisibility('visible'); });
afterEach(() => { vi.useRealTimers(); vi.restoreAllMocks(); });

describe('useAutoRefresh', () => {
  it('polls on the configured interval while visible', async () => {
    const refresh = vi.fn().mockResolvedValue(undefined);
    renderHook(() => useAutoRefresh(refresh, { intervalMs: 60_000 }));
    expect(refresh).toHaveBeenCalledTimes(1);          // 挂载时先取一次，否则首屏是空的
    // 用 async 版推进定时器：单飞守卫靠 promise resolve 落定，同步的 advanceTimersByTime
    // 不会把挂载那次刷新的 .finally 微任务冲刷掉，下一 tick 会误判为「仍在途」而跳过。
    // 详见报告：计划这条测试的同步计时器 harness 与单飞去重互斥（test4 反向为证）。
    await act(async () => { await vi.advanceTimersByTimeAsync(60_000); });
    expect(refresh).toHaveBeenCalledTimes(2);
  });

  it('does not poll while the window is hidden', async () => {
    const refresh = vi.fn().mockResolvedValue(undefined);
    renderHook(() => useAutoRefresh(refresh, { intervalMs: 60_000 }));
    // 先落定挂载刷新的 in-flight，否则删掉可见性守卫时，被复用的单飞守卫会替它挡住轮询，
    // 这条测试就抓不到「隐藏仍在轮询」的突变（详见报告的 mutation (a)）。用 async 推进定时器，
    // 一旦隐藏时仍在轮询，微任务会冲刷、后续 tick 也会继续打进来，突变必然暴露。
    await act(async () => { await Promise.resolve(); });
    refresh.mockClear();
    await act(async () => { setVisibility('hidden'); await vi.advanceTimersByTimeAsync(5 * 60_000); });
    expect(refresh).not.toHaveBeenCalled();            // 常驻应用隐藏时不该继续查库
  });

  it('refreshes once immediately when the window becomes visible again', async () => {
    const refresh = vi.fn().mockResolvedValue(undefined);
    renderHook(() => useAutoRefresh(refresh, { intervalMs: 60_000 }));
    // 冲刷挂载那次刷新的 in-flight，否则变可见时的补取会被单飞守卫误判为「仍在途」而跳过。
    await act(async () => { await Promise.resolve(); });
    act(() => { setVisibility('hidden'); vi.advanceTimersByTime(5 * 60_000); });
    refresh.mockClear();
    act(() => { setVisibility('visible'); });
    expect(refresh).toHaveBeenCalledTimes(1);          // 补上隐藏期间跳过的，但只补一次
  });

  it('does not start a second refresh while one is still in flight', () => {
    let resolveIt: () => void = () => {};
    const refresh = vi.fn(() => new Promise<void>(r => { resolveIt = r; }));
    renderHook(() => useAutoRefresh(refresh, { intervalMs: 1_000 }));
    act(() => { vi.advanceTimersByTime(5_000); });
    expect(refresh).toHaveBeenCalledTimes(1);          // 一次慢查询不该堆出五次并发
    act(() => { resolveIt(); });
  });

  it('coalesces refreshes requested during flight into one trailing run', async () => {
    let resolveIt: () => void = () => {};
    const refresh = vi.fn(() => new Promise<void>(r => { resolveIt = r; }));
    const { result } = renderHook(() => useAutoRefresh(refresh, { intervalMs: 60_000 }));
    expect(refresh).toHaveBeenCalledTimes(1);          // 挂载那次，慢查询在途

    // 在途期间连发三次事件驱动的刷新（dashboard:invalidate 连发的写照）：不并发……
    act(() => { result.current(); result.current(); result.current(); });
    expect(refresh).toHaveBeenCalledTimes(1);

    // ……但也不能丢：完成后合并补跑【一】次，否则 agent 状态要等 60s 轮询才显示。
    const resolveFirst = resolveIt;
    await act(async () => { resolveFirst(); await Promise.resolve(); });
    expect(refresh).toHaveBeenCalledTimes(2);

    // 尾随只补一次，不自激振荡。
    await act(async () => { resolveIt(); await Promise.resolve(); });
    expect(refresh).toHaveBeenCalledTimes(2);
  });

  it('stops the timer on unmount', () => {
    const refresh = vi.fn().mockResolvedValue(undefined);
    const { unmount } = renderHook(() => useAutoRefresh(refresh, { intervalMs: 1_000 }));
    unmount();
    refresh.mockClear();
    act(() => { vi.advanceTimersByTime(10_000); });
    expect(refresh).not.toHaveBeenCalled();            // 不清理的 interval 会在热重载里堆积
  });
});
