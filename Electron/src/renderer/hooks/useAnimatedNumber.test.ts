// @vitest-environment jsdom

import { renderHook, waitFor } from '@testing-library/react';
import { describe, it, expect } from 'vitest';
import { useAnimatedNumber } from './useAnimatedNumber.js';

describe('useAnimatedNumber', () => {
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
