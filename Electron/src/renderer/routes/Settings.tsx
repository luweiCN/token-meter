import { useEffect, useState } from 'react';

import { settingsStore, useSettings } from '../stores/settingsStore.js';
import type { SettingsApplyRequest } from '../stores/settingsStore.js';

export function Settings() {
  const settings = useSettings();
  const providerOptions = settings.providerOverrides.filter((provider) => provider.enabled !== false);
  const [applyResult, setApplyResult] = useState<SettingsApplyRequest | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    void settingsStore.load().then(() => {
      if (!cancelled) setLoadError(null);
    }).catch((error: unknown) => {
      const message = error instanceof Error ? error.message : '设置加载失败';
      if (!cancelled) setLoadError(message);
    });
    return () => {
      cancelled = true;
    };
  }, []);

  return (
    <>
      <p className="eyebrow">提供商设置</p>
      <h1>设置</h1>
      <p className="lede">选择菜单栏优先显示的提供商。保存后会通过安全预加载接口通知常驻 Swift 菜单栏。</p>
      <label className="field">
        <span>主要提供商</span>
        <select
          value={settings.menuBarPrimaryProviderId ?? ''}
          onChange={(event) => {
            void settingsStore.updatePrimaryProvider(event.target.value).then(setApplyResult).catch((error: unknown) => {
              const message = error instanceof Error ? error.message : '设置保存失败';
              setApplyResult({
                requestedVersion: settings.version,
                status: 'failed',
                error: { requestedVersion: settings.version, message }
              });
            });
          }}
        >
          <option value="">自动选择</option>
          {providerOptions.map((provider) => (
            <option key={provider.providerId} value={provider.providerId}>
              {provider.displayName ?? provider.providerId}
            </option>
          ))}
        </select>
      </label>
      <p className="muted">保存后会立即通知常驻菜单栏进程。</p>
      {loadError && applyResult === null ? (
        <p className="status-error" role="status">
          设置加载失败：{loadError}
        </p>
      ) : null}
      {applyResult?.status === 'failed' ? (
        <p className="status-error" role="status">
          设置保存失败：{applyResult.error?.message ?? '未知设置错误'}
        </p>
      ) : applyResult?.status === 'pending' ? (
        <p className="muted" role="status">设置已保存，正在等待 Swift 菜单栏应用版本 {applyResult.requestedVersion}。</p>
      ) : applyResult?.status === 'applied' ? (
        <p className="muted" role="status">设置已应用到 Swift 菜单栏。</p>
      ) : null}
    </>
  );
}
