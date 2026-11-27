import { BrowserWindow, session } from 'electron';
import { randomUUID } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

type SessionCookies =
  | { consoleSession: string; authCookie?: string }
  | { authCookie: string; consoleSession?: string };

export type OpenCodeGoCredentials = { workspaceId: string } & SessionCookies;

export const CREDENTIALS_FILE = () =>
  path.join(os.homedir(), '.config', 'opencode', 'opencode-quota', 'opencode-go.json');

export function readCredentials(file = CREDENTIALS_FILE()): OpenCodeGoCredentials | null {
  try {
    const raw = fs.readFileSync(file, 'utf8');
    const parsed: unknown = JSON.parse(raw);
    if (typeof parsed !== 'object' || parsed === null) return null;
    const object = parsed as Record<string, unknown>;
    if (typeof object.workspaceId !== 'string' || !object.workspaceId.trim()) return null;
    const cookies = sessionCookies(object.authCookie, object.consoleSession);
    if (cookies) return { workspaceId: object.workspaceId, ...cookies };
    return null;
  } catch {
    return null;
  }
}

export function writeCredentials(credentials: OpenCodeGoCredentials, file = CREDENTIALS_FILE()): void {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const temp = file + '.' + randomUUID();
  try {
    fs.writeFileSync(temp, JSON.stringify(credentials) + '\n', { flag: 'wx', mode: 0o600 });
    fs.renameSync(temp, file);
  } finally {
    fs.rmSync(temp, { force: true });
  }
}

export function clearCredentials(file = CREDENTIALS_FILE()): void {
  try {
    fs.rmSync(file, { force: true });
  } catch {
    // 文件不存在无需处理
  }
}

const PARTITION = 'persist:opencode-go';
const ORIGIN = 'https://opencode.ai';

export function extractWorkspaceId(input: string): string | null {
  try {
    const url = new URL(input);
    if (url.origin !== ORIGIN) return null;
    const workspace = url.pathname.match(/^\/workspace\/([A-Za-z0-9_-]+)(?:\/|$)/);
    const org = url.pathname.match(/^\/console\/((?:org|wrk)_[A-Za-z0-9_-]+)(?:\/|$)/);
    return (workspace ?? org)?.[1] ?? null;
  } catch {
    return null;
  }
}

function sessionCookies(auth: unknown, console: unknown): SessionCookies | null {
  if (typeof console === 'string' && console) {
    return typeof auth === 'string' && auth
      ? { authCookie: auth, consoleSession: console }
      : { consoleSession: console };
  }
  if (typeof auth === 'string' && auth) return { authCookie: auth };
  return null;
}

async function captureSession(): Promise<SessionCookies | null> {
  const cookies = await session.fromPartition(PARTITION).cookies.get({ url: ORIGIN + '/console/api/go/status' });
  return sessionCookies(
    cookies.find(c => c.name === 'auth')?.value,
    cookies.find(c => c.name === '__Host-console_session')?.value
  );
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
      try {
        const cookies = await captureSession();
        if (!cookies || settled || window.isDestroyed() || lastURL !== url) return;
        writeCredentials({ workspaceId, ...cookies });
        finish({ ok: true, reason: 'captured' });
      } catch {
        // Keep the login dialog usable. On close the caller reports that no session was saved.
      }
    };

    // did-navigate 覆盖整页导航，did-navigate-in-page 覆盖 SPA 路由跳转。
    window.webContents.on('did-navigate', handleNavigation);
    window.webContents.on('did-navigate-in-page', handleNavigation);

    window.on('closed', () => {
      if (settled) return;
      // 用户关窗：若已在 workspace 页（说明已登录）但 cookie 没抓到，给个明确原因。
      settled = true;
      const workspaceId = extractWorkspaceId(lastURL);
      resolve({ ok: false, reason: workspaceId ? 'missing-cookie' : 'cancelled' });
    });

    void window.loadURL(ORIGIN + '/console');
  });
}
