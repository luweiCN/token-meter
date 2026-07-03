import { useEffect } from 'react';

import { settingsStore, useSettings } from '../stores/settingsStore.js';

export function Settings() {
  const settings = useSettings();
  const providerOptions = settings.providerOverrides.filter((provider) => provider.enabled !== false);

  useEffect(() => {
    void settingsStore.load();
  }, []);

  return (
    <>
      <p className="eyebrow">Provider access</p>
      <h1>Settings</h1>
      <p className="lede">Choose which provider the Swift menu bar should show first. Changes are applied through the preload whitelist.</p>
      <label className="field">
        <span>Primary provider</span>
        <select
          value={settings.menuBarPrimaryProviderId ?? ''}
          onChange={(event) => void settingsStore.updatePrimaryProvider(event.target.value)}
        >
          <option value="">Automatic</option>
          {providerOptions.map((provider) => (
            <option key={provider.providerId} value={provider.providerId}>
              {provider.displayName ?? provider.providerId}
            </option>
          ))}
        </select>
      </label>
      <p className="muted">Saved settings notify the resident Swift menu bar immediately.</p>
    </>
  );
}
