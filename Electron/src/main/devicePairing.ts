import { app, clipboard, ipcMain, type IpcMainInvokeEvent, type WebContents } from 'electron';
import { execFile, spawn } from 'node:child_process';
import { realpathSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { isDeviceID, isPairEvent, isPairInvitation, isPairRole, isRecord, isTrustedDevice, type PairEvent, type PairRequest } from '../shared/pairing.js';
import { deviceCLI } from './deviceUsage.js';
import { takeInvitation } from './pairInvitation.js';

const exec = promisify(execFile);

export function isDashboardURL(url: string, root: string, dev?: string): boolean {
  try {
    if (dev && new URL(url).origin === new URL(dev).origin && new URL(dev).hostname === '127.0.0.1') return true;
    const actual = fileURLToPath(url);
    const dashboard = resolve(root, 'dist-renderer/index.html');
    return actual === dashboard || realpathSync.native(actual) === realpathSync.native(dashboard);
  } catch {
    return false;
  }
}

function sender(event: IpcMainInvokeEvent): WebContents {
  const frame = event.senderFrame;
  if (!frame || frame !== event.sender.mainFrame || !isDashboardURL(frame.url, app.getAppPath(), process.env.VITE_DEV_SERVER_URL)) {
    throw new Error('请从 TokenMeter 的设备页面操作');
  }
  return event.sender;
}

function validRequest(raw: unknown): raw is PairRequest {
  if (!isRecord(raw)) return false;
  return (raw.mode === 'create' && isPairRole(raw.role)) || (raw.mode === 'join' && isPairRole(raw.role) && isPairInvitation(raw.invitation));
}

function launch(executable: string, args: string[]) {
  return spawn(executable, args, { stdio: ['pipe', 'pipe', 'ignore'], windowsHide: true });
}

class PairSession {
  private terminal = false;
  private latest?: PairEvent;
  private buffer = '';
  private readonly child: ReturnType<typeof launch>;
  private readonly timer: NodeJS.Timeout;

  constructor(readonly id: string, request: PairRequest, private readonly send: (event: PairEvent) => void,
    private readonly release: () => void, executable: string) {
    const args = ['--role', request.role];
    if (request.mode === 'join') args.push('--join-stdin');
    this.child = launch(executable, ['pair', '--json', ...args]);
    this.timer = setTimeout(() => this.finish({ state: 'expired', message: '配对已过期，请重新创建邀请。' }, true), 11 * 60_000).unref();
    const failed = () => this.finish({ state: 'error', message: '配对服务连接中断，请重试。' }, true);
    this.child.on('error', failed);
    this.child.stdin.on('error', failed);
    this.child.stdout.setEncoding('utf8');
    this.child.stdout.on('data', (chunk: string) => this.read(chunk));
    this.child.on('close', failed);
    if (request.mode === 'join') this.child.stdin.write(JSON.stringify({ invitation: request.invitation }) + '\n');
  }

  private read(chunk: string) {
    this.buffer += chunk;
    let end: number;
    while (!this.terminal && (end = this.buffer.indexOf('\n')) !== -1) {
      const line = this.buffer.slice(0, end);
      this.buffer = this.buffer.slice(end + 1);
      try {
        if (line.length > 8192) throw new Error();
        const event: unknown = JSON.parse(line);
        if (!isPairEvent(event)) throw new Error();
        this.latest = event;
        if (event.state === 'invitation' || event.state === 'connecting' || event.state === 'confirm' || event.state === 'waiting') this.send(event);
        else this.finish(event);
      } catch {
        this.finish({ state: 'error', message: '命令行返回了无法识别的配对状态。' }, true);
      }
    }
    if (this.buffer.length > 8192) this.finish({ state: 'error', message: '配对响应超出长度限制。' }, true);
  }

  decide(approve: boolean) {
    if (this.latest?.state !== 'confirm' || !this.latest.canApprove) throw new Error('请先核对两台设备的校验码');
    this.latest = { ...this.latest, canApprove: false };
    this.child.stdin.write(JSON.stringify({ approve }) + '\n');
  }

  copy(field: 'code' | 'url') {
    if (this.latest?.state !== 'invitation' || Date.parse(this.latest.expiresAt) <= Date.now()) throw new Error('邀请已失效');
    clipboard.writeText(this.latest[field]);
  }

  cancel() {
    this.finish({ state: 'cancelled', message: '配对已取消。' }, true);
  }

  private finish(event: PairEvent, terminate = false) {
    if (this.terminal) return;
    this.terminal = true;
    clearTimeout(this.timer);
    this.buffer = '';
    this.latest = undefined;
    this.release();
    if (terminate && this.child.exitCode === null) this.child.kill();
    this.child.stdin.end();
    if (this.child.exitCode === null && this.child.signalCode === null) {
      const fallback = setTimeout(() => this.child.kill('SIGKILL'), 2500).unref();
      this.child.once('close', () => clearTimeout(fallback));
    }
    this.send(event);
  }
}

export function registerPairing() {
  const active = new Map<number, PairSession>();
  function get(owner: WebContents, id: unknown): PairSession {
    const session = active.get(owner.id);
    if (!session || session.id !== id) throw new Error('配对会话已结束');
    return session;
  }

  ipcMain.handle('pair:start', (event, id: unknown, request: unknown) => {
    const owner = sender(event);
    if (typeof id !== 'string' || !/^[0-9a-f-]{36}$/i.test(id) || !validRequest(request)) throw new Error('配对信息无效');
    if (active.has(owner.id)) throw new Error('请先完成或取消当前配对');
    const send = (update: PairEvent) => {
      if (!owner.isDestroyed() && isDashboardURL(owner.getURL(), app.getAppPath(), process.env.VITE_DEV_SERVER_URL)) owner.send('pair:update', id, update);
    };
    const cancel = () => active.get(owner.id)?.cancel();
    const navigation = (details: { isMainFrame: boolean; isSameDocument: boolean }) => {
      if (details.isMainFrame && !details.isSameDocument) cancel();
    };
    const release = () => {
      active.delete(owner.id);
      owner.removeListener('destroyed', cancel);
      owner.removeListener('render-process-gone', cancel);
      owner.removeListener('did-start-navigation', navigation);
    };
    const session = new PairSession(id, request, send, release, deviceCLI());
    active.set(owner.id, session);
    owner.once('destroyed', cancel);
    owner.once('render-process-gone', cancel);
    owner.on('did-start-navigation', navigation);
  });
  ipcMain.handle('pair:decide', (event, id, approve: unknown) => {
    if (typeof approve !== 'boolean') throw new Error('配对决定无效');
    get(sender(event), id).decide(approve);
  });
  ipcMain.handle('pair:cancel', (event, id) => {
    const session = active.get(sender(event).id);
    if (session?.id === id) session?.cancel();
  });
  ipcMain.handle('pair:copy', (event, id, field: unknown) => {
    if (field !== 'url' && field !== 'code') throw new Error('邀请字段无效');
    get(sender(event), id).copy(field);
  });
  ipcMain.handle('pair:pending', event => {
    sender(event);
    return takeInvitation();
  });
  ipcMain.handle('pair:list', async event => {
    sender(event);
    const res = await exec(deviceCLI(), ['peer', 'list', '--json'], { timeout: 7000, maxBuffer: 512 * 1024 });
    const peers: unknown = JSON.parse(res.stdout);
    if (!Array.isArray(peers) || !peers.every(isTrustedDevice)) throw new Error('无法读取已配对设备');
    return peers;
  });
  ipcMain.handle('pair:remove', async (event, id: unknown) => {
    sender(event);
    if (!isDeviceID(id)) throw new Error('设备 ID 无效');
    await exec(deviceCLI(), ['peer', 'remove', id], { timeout: 7000, maxBuffer: 64 * 1024 });
  });
}
