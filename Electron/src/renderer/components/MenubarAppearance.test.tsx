// @vitest-environment jsdom

import { fireEvent, render, screen } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import type { SettingsSnapshot } from '../api.js';
import { settingsStore } from '../stores/settingsStore.js';
import { MenubarAppearance, elementLocks, stylePatch } from './MenubarAppearance.js';

function snapshotWith(partial?: Partial<SettingsSnapshot['menubarAppearance']>): SettingsSnapshot {
  return {
    version: 3,
    autoRefreshSeconds: 300,
    enabledAgentKinds: [],
    providerOverrides: [
      { providerId: 'codex', enabled: true },
      { providerId: 'claude-code', enabled: true },
      { providerId: 'zhipu', enabled: true }
    ],
    quotaUsedThresholdPercent: 0,
    menubarAppearance: {
      style: 'rings',
      showName: true,
      showGlyph: true,
      showNumber: true,
      usage: 'tok',
      windowOrder: 'longFirst',
      ...partial
    }
  };
}

describe('MenubarAppearance', () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    window.tokenMeter = {
      settings: {
        get: vi.fn(async () => snapshotWith()),
        update: vi.fn(async () => ({ requestedVersion: 4, status: 'pending' as const }))
      }
    } as unknown as typeof window.tokenMeter;
  });

  async function mount(partial?: Partial<SettingsSnapshot['menubarAppearance']>) {
    (window.tokenMeter.settings.get as ReturnType<typeof vi.fn>).mockResolvedValue(snapshotWith(partial));
    await settingsStore.load();
    return render(<MenubarAppearance onBack={() => {}} />);
  }

  it('gallery click applies style patch with side effects', async () => {
    const spy = vi
      .spyOn(settingsStore, 'applyPatch')
      .mockResolvedValue({ requestedVersion: 4, status: 'pending' });
    await mount();

    fireEvent.click(screen.getByRole('button', { name: /纯数字/ }));
    expect(spy).toHaveBeenCalledWith(expect.objectContaining({ menubarStyle: 'digits', menubarShowGlyph: false }));

    fireEvent.click(screen.getByRole('button', { name: /双层堆叠/ }));
    expect(spy).toHaveBeenCalledWith(
      expect.objectContaining({ menubarStyle: 'deck2', menubarShowNumber: true, menubarShowGlyph: false })
    );
  });

  it('locks element switches per style', async () => {
    await mount({ style: 'tagnum' });
    // 数字支：图形与数字锁死
    expect((screen.getByRole('button', { name: '图形' }) as HTMLButtonElement).disabled).toBe(true);
    expect((screen.getByRole('button', { name: '剩余百分比数字' }) as HTMLButtonElement).disabled).toBe(true);
    expect((screen.getByRole('button', { name: '品牌短名' }) as HTMLButtonElement).disabled).toBe(false);
  });

  it('disables the last remaining element switch', async () => {
    await mount({ showName: false, showGlyph: true, showNumber: false });
    // 只剩图形开着 → 图形开关禁用（至少保一）
    expect((screen.getByRole('button', { name: '图形' }) as HTMLButtonElement).disabled).toBe(true);
    expect(screen.getByText('至少保留一个元素')).toBeTruthy();
  });

  it('provider rows patch visibility and windows', async () => {
    const spy = vi
      .spyOn(settingsStore, 'applyPatch')
      .mockResolvedValue({ requestedVersion: 4, status: 'pending' });
    await mount();

    fireEvent.click(screen.getByRole('button', { name: 'Codex 菜单栏显示' }));
    expect(spy).toHaveBeenCalledWith(expect.objectContaining({ providerMenubarVisible: { codex: false } }));

    // Codex 行的图形窗口切 5h
    const codexRow = screen.getByRole('button', { name: 'Codex 菜单栏显示' }).closest('tr');
    expect(codexRow).not.toBeNull();
    const seg = codexRow?.querySelectorAll('.seg.mini')[0];
    const shortButton = Array.from(seg?.querySelectorAll('button') ?? []).find((b) => b.textContent === '5h');
    expect(shortButton).toBeTruthy();
    fireEvent.click(shortButton as HTMLButtonElement);
    expect(spy).toHaveBeenCalledWith(expect.objectContaining({ providerGlyphWindow: { codex: 'short' } }));
  });

  it('window order segment patches menubarWindowOrder', async () => {
    const spy = vi
      .spyOn(settingsStore, 'applyPatch')
      .mockResolvedValue({ requestedVersion: 4, status: 'pending' });
    await mount();

    fireEvent.click(screen.getByRole('button', { name: '5h 在前' }));
    expect(spy).toHaveBeenCalledWith(expect.objectContaining({ menubarWindowOrder: 'shortFirst' }));
  });
});

describe('stylePatch / elementLocks（spec §3 表）', () => {
  it('encodes gallery side effects', () => {
    expect(stylePatch('digits', { showName: true, showNumber: true })).toEqual({
      menubarStyle: 'digits',
      menubarShowGlyph: false
    });
    expect(stylePatch('monogram', { showName: false, showNumber: true })).toEqual({
      menubarStyle: 'monogram',
      menubarShowName: true,
      menubarShowGlyph: false
    });
    expect(stylePatch('ringdeck', { showName: true, showNumber: false })).toEqual({
      menubarStyle: 'ringdeck',
      menubarShowNumber: true,
      menubarShowGlyph: true
    });
    expect(stylePatch('grid', { showName: true, showNumber: true })).toEqual({
      menubarStyle: 'grid',
      menubarShowGlyph: true
    });
    // 名称与数字全关时切普通样式 → 图形兜底开
    expect(stylePatch('vbars', { showName: false, showNumber: false })).toEqual({
      menubarStyle: 'vbars',
      menubarShowGlyph: true
    });
    expect(stylePatch('rings', { showName: true, showNumber: true })).toEqual({ menubarStyle: 'rings' });
  });

  it('encodes element locks', () => {
    expect(elementLocks('digits')).toEqual({ glyph: true });
    expect(elementLocks('monogram')).toEqual({ name: true, glyph: true });
    expect(elementLocks('deck2')).toEqual({ glyph: true, pct: true });
    expect(elementLocks('barsdeck')).toEqual({ glyph: true, pct: true });
    expect(elementLocks('sentinel')).toEqual({ glyph: true });
    expect(elementLocks('rings')).toEqual({});
  });
});
