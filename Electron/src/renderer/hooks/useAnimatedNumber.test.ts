// @vitest-environment jsdom

import { renderHook, waitFor } from '@testing-library/react';
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { useAnimatedNumber } from './useAnimatedNumber.js';

describe('useAnimatedNumber', () => {
  // 用同步、可控的时钟替代真实 requestAnimationFrame：真实 RAF 依赖挂钟，vitest
  // 并发跑时会被别的测试挤到超时，导致这几个测试间歇性 flaky。这里让每帧的时间
  // 直接跳过任何 duration，一帧就跑到终点，动画变确定、不再靠真实时间。
  let clock = 0;
  beforeEach(() => {
    clock = 0;
    vi.spyOn(performance, 'now').mockImplementation(() => clock);
    vi.stubGlobal('requestAnimationFrame', (cb: FrameRequestCallback) => {
      clock += 1000;
      cb(clock);
      return 1;
    });
    vi.stubGlobal('cancelAnimationFrame', () => {});
  });
  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });

  it('shows the initial value immediately on mount, without animating up from zero', () => {
    const { result } = renderHook(() => useAnimatedNumber(1000));
    expect(result.current).toBe(1000);
  });

  it('animates toward a new value and settles exactly on it', async () => {
    const { result, rerender } = renderHook(({ value }) => useAnimatedNumber(value, 30), {
      initialProps: { value: 1000 }
    });

    rerender({ value: 2000 });

    await waitFor(() => {
      expect(result.current).toBe(2000);
    });
  });

  it('re-targets smoothly from wherever it currently is if the value changes again mid-animation', async () => {
    const { result, rerender } = renderHook(({ value }) => useAnimatedNumber(value, 100), {
      initialProps: { value: 0 }
    });

    rerender({ value: 1000 });
    rerender({ value: 500 });

    await waitFor(() => {
      expect(result.current).toBe(500);
    });
  });
});
