// @vitest-environment jsdom

import { render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Mock } from 'vitest';

import { AppShell } from './App.js';
import type { SettingsSnapshot } from './stores/settingsStore.js';

interface SettingsPatch {
  menuBarPrimaryProviderId?: string;
  autoRefreshSeconds?: number;
  enabledAgentKinds?: string[];
}

interface SettingsApplyRequest {
  requestedVersion: number;
  status: 'pending' | 'applied';
}

interface TokenMeterApi {
  settings: {
    get: Mock<() => Promise<SettingsSnapshot>>;
    update: Mock<(patch: SettingsPatch, expectedVersion: number) => Promise<SettingsApplyRequest>>;
  };
}

const settingsSnapshot: SettingsSnapshot = {
  version: 12,
  menuBarPrimaryProviderId: 'codex',
  autoRefreshSeconds: 300,
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

const updatedSettingsSnapshot: SettingsSnapshot = {
  ...settingsSnapshot,
  version: 13,
  menuBarPrimaryProviderId: 'claude-code'
};

function installTokenMeterApi(): TokenMeterApi {
  const api: TokenMeterApi = {
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

describe('AppShell renderer routes', () => {
  let api: TokenMeterApi;

  beforeEach(() => {
    document.body.innerHTML = '<div id="root"></div>';
    api = installTokenMeterApi();
    api.settings.get.mockResolvedValue(settingsSnapshot);
    api.settings.update.mockResolvedValue({ requestedVersion: 13, status: 'pending' });
  });

  afterEach(() => {
    vi.restoreAllMocks();
    Reflect.deleteProperty(window, 'tokenMeter');
  });

  it('renders accessible primary route buttons and marks the active route', async () => {
    render(<AppShell />);

    const nav = screen.getByRole('navigation', { name: /primary/i });
    expect(within(nav).getByRole('button', { name: 'Dashboard' }).getAttribute('aria-current')).toBe('page');
    expect(within(nav).getByRole('button', { name: 'Sessions' }).getAttribute('aria-current')).toBeNull();
    expect(within(nav).getByRole('button', { name: 'Index Status' }).getAttribute('aria-current')).toBeNull();
    expect(within(nav).getByRole('button', { name: 'Settings' }).getAttribute('aria-current')).toBeNull();
    expect(document.querySelectorAll('a:not([href])')).toHaveLength(0);
  });

  it('changes the visible route content when sidebar controls are clicked', async () => {
    const user = userEvent.setup();
    render(<AppShell />);

    expect(screen.getByRole('heading', { level: 1, name: 'Dashboard' })).toBeTruthy();

    await user.click(screen.getByRole('button', { name: 'Sessions' }));
    expect(screen.getByRole('heading', { level: 1, name: 'Sessions' })).toBeTruthy();
    expect(screen.getByText(/session usage/i)).toBeTruthy();

    await user.click(screen.getByRole('button', { name: 'Index Status' }));
    expect(screen.getByRole('heading', { level: 1, name: 'Index Status' })).toBeTruthy();
    expect(screen.getByText(/scan roots/i)).toBeTruthy();

    await user.click(screen.getByRole('button', { name: 'Settings' }));
    expect(screen.getByRole('heading', { level: 1, name: 'Settings' })).toBeTruthy();
    expect(screen.getByText(/provider access/i)).toBeTruthy();
  });

  it('loads settings on the Settings route and persists primary provider changes through the whitelisted API', async () => {
    const user = userEvent.setup();
    api.settings.get.mockResolvedValueOnce(settingsSnapshot).mockResolvedValueOnce(updatedSettingsSnapshot);
    render(<AppShell />);

    await user.click(screen.getByRole('button', { name: 'Settings' }));
    const primaryProviderSelect = await screen.findByLabelText('Primary provider');

    expect(primaryProviderSelect).toHaveProperty('value', 'codex');
    await user.selectOptions(primaryProviderSelect, 'claude-code');

    await waitFor(() => {
      expect(api.settings.update).toHaveBeenCalledWith({ menuBarPrimaryProviderId: 'claude-code' }, 12);
    });
    await waitFor(() => {
      expect(primaryProviderSelect).toHaveProperty('value', 'claude-code');
    });
  });
});
