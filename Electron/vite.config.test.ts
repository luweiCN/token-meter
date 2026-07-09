import type { ConfigEnv, UserConfig, UserConfigFnObject } from 'vite';
import { describe, expect, it } from 'vitest';
import viteConfig from './vite.config';

function resolveConfig(mode: string): UserConfig {
  const env: ConfigEnv = {
    command: 'build',
    mode,
    isPreview: false,
    isSsrBuild: false
  };

  if (typeof viteConfig === 'function') {
    return (viteConfig as UserConfigFnObject)(env) as UserConfig;
  }

  return viteConfig as UserConfig;
}

describe('Vite renderer config', () => {
  it('uses relative asset URLs so Electron can load built renderer files via file://', () => {
    const config = resolveConfig('production');

    expect(config.base).toBe('./');
  });
});
