import { useSyncExternalStore } from 'react';

export type { SettingsApplyRequest, SettingsSnapshot } from '../api.js';
import type { SettingsSnapshot } from '../api.js';

const initialSnapshot: SettingsSnapshot = {
  version: 0,
  autoRefreshSeconds: 300,
  enabledAgentKinds: [],
  providerOverrides: []
};

let snapshot = initialSnapshot;
let listeners: Array<() => void> = [];

export const settingsStore = {
  async load() {
    snapshot = await window.tokenMeter.settings.get();
    emit();
  },

  async updatePrimaryProvider(providerId: string) {
    await window.tokenMeter.settings.update({ menuBarPrimaryProviderId: providerId }, snapshot.version);
    await this.load();
  },

  subscribe(listener: () => void) {
    listeners = [...listeners, listener];
    return () => {
      listeners = listeners.filter((item) => item !== listener);
    };
  },

  getSnapshot() {
    return snapshot;
  }
};

function emit() {
  for (const listener of listeners) listener();
}

export function useSettings() {
  return useSyncExternalStore(settingsStore.subscribe, settingsStore.getSnapshot, settingsStore.getSnapshot);
}
