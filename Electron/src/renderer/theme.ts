/// 主窗口配色偏好：明/暗写死，system 跟随 macOS 外观（prefers-color-scheme）。
/// 偏好存 localStorage('tm-theme')，实际配色落在 <html data-theme> 上由 CSS 变量接管。
export type ThemePref = 'dark' | 'light' | 'system';

const STORAGE_KEY = 'tm-theme';
const DARK_QUERY = '(prefers-color-scheme: dark)';

export function storedThemePref(): ThemePref {
  const raw = localStorage.getItem(STORAGE_KEY);
  return raw === 'light' || raw === 'system' ? raw : 'dark';
}

export function resolveTheme(pref: ThemePref): 'dark' | 'light' {
  if (pref !== 'system') return pref;
  return window.matchMedia(DARK_QUERY).matches ? 'dark' : 'light';
}

export function applyThemePref(pref: ThemePref): void {
  localStorage.setItem(STORAGE_KEY, pref);
  document.documentElement.dataset.theme = resolveTheme(pref);
}

/// 系统外观变化时，偏好为 system 的窗口即时跟随。返回取消订阅函数。
export function watchSystemTheme(): () => void {
  const query = window.matchMedia(DARK_QUERY);
  const onChange = () => {
    if (storedThemePref() === 'system') {
      document.documentElement.dataset.theme = resolveTheme('system');
    }
  };
  query.addEventListener('change', onChange);
  return () => query.removeEventListener('change', onChange);
}
