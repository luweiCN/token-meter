// @vitest-environment jsdom

import { act, fireEvent, render } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { TrafficLightHover } from './TrafficLightHover.js';

type MediaChangeListener = (event: MediaQueryListEvent) => void;

/// 可控的 matchMedia：能改 matches 并派发 change，模拟窗口跨过 1100px 断点。
function installMatchMedia(initialMatches: boolean) {
  const listeners = new Set<MediaChangeListener>();
  const state = { matches: initialMatches };

  window.matchMedia = ((query: string) => ({
    get matches() {
      return state.matches;
    },
    media: query,
    onchange: null,
    addListener: () => {},
    removeListener: () => {},
    addEventListener: (_type: string, listener: MediaChangeListener) => {
      listeners.add(listener);
    },
    removeEventListener: (_type: string, listener: MediaChangeListener) => {
      listeners.delete(listener);
    },
    dispatchEvent: () => false
  })) as unknown as typeof window.matchMedia;

  return {
    setMatches(next: boolean) {
      state.matches = next;
      for (const listener of listeners) {
        listener({ matches: next } as MediaQueryListEvent);
      }
    }
  };
}

describe('TrafficLightHover', () => {
  let setButtonsVisible: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    vi.useFakeTimers();
    setButtonsVisible = vi.fn(async () => {});
    (window as unknown as { tokenMeter: unknown }).tokenMeter = {
      windowControls: { setButtonsVisible }
    };
  });

  afterEach(() => {
    vi.useRealTimers();
    Reflect.deleteProperty(window, 'tokenMeter');
  });

  it('renders nothing in the wide layout and keeps the native buttons visible', () => {
    installMatchMedia(false);
    const { container } = render(<TrafficLightHover />);

    expect(container.querySelector('.traffic-hot')).toBeNull();
    expect(setButtonsVisible).toHaveBeenLastCalledWith(true);
  });

  it('hides the buttons on mount in the compact layout, shows on hover, and hides after the leave delay', () => {
    installMatchMedia(true);
    const { container } = render(<TrafficLightHover />);

    const hot = container.querySelector('.traffic-hot');
    expect(hot).not.toBeNull();
    expect(setButtonsVisible).toHaveBeenLastCalledWith(false);

    fireEvent.mouseEnter(hot as Element);
    expect(setButtonsVisible).toHaveBeenLastCalledWith(true);
    expect((hot as Element).className).toContain('shown');

    fireEvent.mouseLeave(hot as Element);
    // 未到延迟前不收：指针滑进原生按钮时 web 会先收到 mouseleave。
    expect(setButtonsVisible).toHaveBeenLastCalledWith(true);

    act(() => {
      vi.advanceTimersByTime(200);
    });
    expect(setButtonsVisible).toHaveBeenLastCalledWith(false);
    expect((hot as Element).className).not.toContain('shown');
  });

  it('cancels the scheduled hide when the pointer re-enters before the delay elapses', () => {
    installMatchMedia(true);
    const { container } = render(<TrafficLightHover />);
    const hot = container.querySelector('.traffic-hot') as Element;

    fireEvent.mouseEnter(hot);
    fireEvent.mouseLeave(hot);
    fireEvent.mouseEnter(hot);
    act(() => {
      vi.advanceTimersByTime(500);
    });

    expect(setButtonsVisible).toHaveBeenLastCalledWith(true);
    expect(hot.className).toContain('shown');
  });

  it('collapses immediately when the window loses focus', () => {
    installMatchMedia(true);
    const { container } = render(<TrafficLightHover />);
    const hot = container.querySelector('.traffic-hot') as Element;

    fireEvent.mouseEnter(hot);
    expect(setButtonsVisible).toHaveBeenLastCalledWith(true);

    act(() => {
      window.dispatchEvent(new Event('blur'));
    });
    expect(setButtonsVisible).toHaveBeenLastCalledWith(false);
  });

  it('removes the hot zone and restores the buttons when the window crosses back over the breakpoint', () => {
    const media = installMatchMedia(true);
    const { container } = render(<TrafficLightHover />);
    expect(container.querySelector('.traffic-hot')).not.toBeNull();

    act(() => {
      media.setMatches(false);
    });

    expect(container.querySelector('.traffic-hot')).toBeNull();
    expect(setButtonsVisible).toHaveBeenLastCalledWith(true);
  });
});
