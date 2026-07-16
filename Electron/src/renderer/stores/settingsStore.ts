import { useSyncExternalStore } from 'react';

export type { SettingsApplyRequest, SettingsSnapshot } from '../api.js';
import { MENUBAR_APPEARANCE_DEFAULT } from '../api.js';
import type { SettingsApplyRequest, SettingsPatch, SettingsSnapshot } from '../api.js';

const initialSnapshot: SettingsSnapshot = {
  version: 0,
  autoRefreshSeconds: 300,
  enabledAgentKinds: [],
  providerOverrides: [],
  quotaUsedThresholdPercent: 0,
  menubarAppearance: MENUBAR_APPEARANCE_DEFAULT
};

let snapshot = initialSnapshot;
let listeners: Array<() => void> = [];

export const settingsStore = {
  async load() {
    snapshot = await window.tokenMeter.settings.get();
    emit();
  },

  async updatePrimaryProvider(providerId: string): Promise<SettingsApplyRequest> {
    return this.applyPatch({ menuBarPrimaryProviderId: providerId });
  },

  /// 开关某个 coding agent：Swift 端收到 settingsChanged 后按 enabledAgentKinds
  /// 对账 hooks 装卸，统计过滤走同一份名单。
  async updateEnabledAgentKinds(kinds: string[]): Promise<SettingsApplyRequest> {
    return this.applyPatch({ enabledAgentKinds: kinds });
  },

  async applyPatch(patch: SettingsPatch): Promise<SettingsApplyRequest> {
    try {
      const result = await window.tokenMeter.settings.update(patch, snapshot.version);
      try {
        await this.load();
      } catch (error) {
        const message = error instanceof Error ? error.message : '设置重新加载失败';
        return {
          requestedVersion: result.requestedVersion,
          status: 'failed',
          error: { requestedVersion: result.requestedVersion, message }
        };
      }
      return result;
    } catch (error) {
      const message = error instanceof Error ? error.message : '设置保存失败';
      return {
        requestedVersion: snapshot.version,
        status: 'failed',
        error: { requestedVersion: snapshot.version, message }
      };
    }
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
