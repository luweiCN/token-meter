// @vitest-environment jsdom

import { createElement } from 'react';
import { render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Mock } from 'vitest';

import { settingsStore, useSettings } from './settingsStore.js';
import type { SettingsSnapshot } from './settingsStore.js';

interface SettingsPatch {
  menuBarPrimaryProviderId?: string;
  autoRefreshSeconds?: number;
  enabledAgentKinds?: string[];
}

interface SettingsApplyRequest {
  requestedVersion: number;
  status: 'pending' | 'applied';
}

interface TokenMeterSettingsApi {
  get: () => Promise<SettingsSnapshot>;
  update: (patch: SettingsPatch, expectedVersion: number) => Promise<SettingsApplyRequest>;
}

interface TokenMeterApi {
  settings: TokenMeterSettingsApi;
}

interface InstalledTokenMeterApi extends TokenMeterApi {
  settings: {
    get: Mock<() => Promise<SettingsSnapshot>>;
    update: Mock<(patch: SettingsPatch, expectedVersion: number) => Promise<SettingsApplyRequest>>;
  };
}

const codexSnapshot: SettingsSnapshot = {
  version: 7,
  menuBarPrimaryProviderId: 'codex',
  autoRefreshSeconds: 300,
  quotaUsedThresholdPercent: 0,
  menubarAppearance: {
    style: 'rings',
    showName: true,
    showGlyph: true,
    showNumber: true,
    usage: 'tok',
    windowOrder: 'longFirst'
  },
  enabledAgentKinds: ['claudeCode', 'codex'],
  providerOverrides: [
    {
      providerId: 'codex',
      displayName: 'Codex',
      enabled: true,
      menuRank: 1,
      showInMenuBar: true,
      showInCharts: true
    },
    {
      providerId: 'claude-code',
      displayName: 'Claude Code',
      enabled: true,
      menuRank: 2,
      showInMenuBar: true,
      showInCharts: true
    }
  ]
};

const claudeSnapshot: SettingsSnapshot = {
  ...codexSnapshot,
  version: 8,
  menuBarPrimaryProviderId: 'claude-code'
};

function installTokenMeterApi(): InstalledTokenMeterApi {
  const api = {
    settings: {
      get: vi.fn<() => Promise<SettingsSnapshot>>(),
      update: vi.fn<(patch: SettingsPatch, expectedVersion: number) => Promise<SettingsApplyRequest>>()
    }
  };

  Object.defineProperty(window, 'tokenMeter', {
    configurable: true,
    value: api
  });

  return api;
}

function SettingsObserver() {
  const settings = useSettings();
  return createElement('output', { 'aria-label': 'primary provider' }, settings.menuBarPrimaryProviderId);
}

describe('renderer settingsStore', () => {
  let api: InstalledTokenMeterApi;

  beforeEach(() => {
    api = installTokenMeterApi();
  });

  afterEach(() => {
    vi.restoreAllMocks();
    Reflect.deleteProperty(window, 'tokenMeter');
  });

  it('load replaces the settings snapshot and notifies subscribers exactly once per API snapshot', async () => {
    api.settings.get.mockResolvedValueOnce(codexSnapshot);
    const observedSnapshots: SettingsSnapshot[] = [];
    const unsubscribe = settingsStore.subscribe(() => {
      observedSnapshots.push(settingsStore.getSnapshot());
    });

    await settingsStore.load();

    unsubscribe();
    expect(api.settings.get).toHaveBeenCalledTimes(1);
    expect(settingsStore.getSnapshot()).toEqual(codexSnapshot);
    expect(observedSnapshots).toEqual([codexSnapshot]);
  });

  it('updatePrimaryProvider sends a whitelisted settings patch with the current version and reloads the accepted snapshot', async () => {
    api.settings.get.mockResolvedValueOnce(codexSnapshot).mockResolvedValueOnce(claudeSnapshot);
    api.settings.update.mockResolvedValueOnce({ requestedVersion: 8, status: 'pending' });

    await settingsStore.load();
    await settingsStore.updatePrimaryProvider('claude-code');

    expect(api.settings.update).toHaveBeenCalledTimes(1);
    expect(api.settings.update).toHaveBeenCalledWith({ menuBarPrimaryProviderId: 'claude-code' }, 7);
    expect(api.settings.get).toHaveBeenCalledTimes(2);
    expect(settingsStore.getSnapshot()).toEqual(claudeSnapshot);
  });

  it('useSettings re-renders subscribed React consumers when the external store snapshot changes', async () => {
    api.settings.get.mockResolvedValueOnce(codexSnapshot).mockResolvedValueOnce(claudeSnapshot);
    await settingsStore.load();

    render(createElement(SettingsObserver));
    expect(screen.getByLabelText('primary provider').textContent).toBe('codex');

    await settingsStore.load();

    await waitFor(() => {
      expect(screen.getByLabelText('primary provider').textContent).toBe('claude-code');
    });
  });
});
