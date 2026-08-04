import { BrowserWindow, session } from 'electron';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

/// OpenCode Go 登录态管理与登录窗口。
///
/// 用量数据只能从控制台（opencode.ai）读取，认证是 httpOnly 的 iron-session
/// cookie（一年有效）。浏览器安全模型下脚本无法读 httpOnly cookie，这里改用
/// Electron 自带的持久化 WebView：用户在主界面点「登录」→ 弹窗加载
/// opencode.ai（partition: persist:opencode-go，登录态持久化）→ 登录后跳转到
/// workspace 页 → 主进程通过 session.cookies API 捕获 auth cookie + workspaceId
/// → 写入 ~/.config/opencode/opencode-quota/opencode-go.json（Swift 侧读取）。
export interface OpenCodeGoCredentials {
  workspaceId: string;
  authCookie: string;
}

export const CREDENTIALS_FILE = () =>
  path.join(os.homedir(), '.config', 'opencode', 'opencode-quota', 'opencode-go.json');

export function readCredentials(file = CREDENTIALS_FILE()): OpenCodeGoCredentials | null {
  try {
    const raw = fs.readFileSync(file, 'utf8');
    const parsed: unknown = JSON.parse(raw);
    if (typeof parsed !== 'object' || parsed === null) return null;
    const object = parsed as Record<string, unknown>;
    if (
      typeof object.workspaceId === 'string' &&
      object.workspaceId.length > 0 &&
      typeof object.authCookie === 'string' &&
      object.authCookie.length > 0
    ) {
      return { workspaceId: object.workspaceId, authCookie: object.authCookie };
    }
    return null;
  } catch {
    return null;
  }
}

export function writeCredentials(credentials: OpenCodeGoCredentials, file = CREDENTIALS_FILE()): void {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(credentials, null, 2)}\n`, { mode: 0o600 });
}

export function clearCredentials(file = CREDENTIALS_FILE()): void {
  try {
    fs.rmSync(file, { force: true });
  } catch {
    // 文件不存在无需处理
  }
}

const PARTITION = 'persist:opencode-go';
const AUTH_COOKIE_PREFIX = 'Fe26.2';

const WORKSPACE_URL_PATTERN = /\/workspace\/([^/?#]+)/;

export function extractWorkspaceId(url: string): string | null {
  const match = url.match(WORKSPACE_URL_PATTERN);
  if (!match) return null;
  try {
    return decodeURIComponent(match[1]);
  } catch {
    return match[1];
  }
}

/// 从持久 session 里抓 auth cookie（httpOnly 也能读，这就是用 WebView 的原因）。
async function captureAuthCookie(): Promise<string | null> {
  const cookies = await session.fromPartition(PARTITION).cookies.get({ url: 'https://opencode.ai' });
  const auth = cookies.find((cookie) => cookie.name === 'auth' && cookie.value.startsWith(AUTH_COOKIE_PREFIX));
  return auth?.value ?? null;
}

export interface OpenCodeGoLoginResult {
  ok: boolean;
  reason: 'captured' | 'cancelled' | 'missing-cookie' | 'no-workspace';
}

/// 打开登录窗口。用户登录（或已有持久登录态）到达 workspace 页后自动捕获
/// 凭证并写盘；用户手动关闭窗口视为取消。已配置过登录态时窗口打开即命中。
export function openLoginWindow(): Promise<OpenCodeGoLoginResult> {
  return new Promise((resolve) => {
    const window = new BrowserWindow({
      width: 440,
      height: 680,
      title: '登录 OpenCode Go',
      autoHideMenuBar: true,
      webPreferences: {
        partition: PARTITION,
        nodeIntegration: false,
        contextIsolation: true,
        sandbox: true
      }
    });

    let settled = false;
    let lastURL = '';
    const finish = (result: OpenCodeGoLoginResult) => {
      if (settled) return;
      settled = true;
      window.destroy();
      resolve(result);
    };

    const handleNavigation = async (_event: Electron.Event, url: string) => {
      lastURL = url;
      const workspaceId = extractWorkspaceId(url);
      if (!workspaceId) return;
      const authCookie = await captureAuthCookie();
      if (!authCookie) {
        finish({ ok: false, reason: 'missing-cookie' });
        return;
      }
      writeCredentials({ workspaceId, authCookie });
      finish({ ok: true, reason: 'captured' });
    };

    // did-navigate 覆盖整页导航，did-navigate-in-page 覆盖 SPA 路由跳转。
    window.webContents.on('did-navigate', handleNavigation);
    window.webContents.on('did-navigate-in-page', handleNavigation);

    window.on('closed', () => {
      if (settled) return;
      // 用户关窗：若已在 workspace 页（说明已登录）但 cookie 没抓到，给个明确原因。
      const workspaceId = extractWorkspaceId(lastURL);
      resolve({ ok: false, reason: workspaceId ? 'missing-cookie' : 'cancelled' });
    });

    void window.loadURL('https://opencode.ai/');
  });
}
