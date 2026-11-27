import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { mkdtempSync, mkdirSync, symlinkSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import type { IpcMain } from 'electron';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { isPairInvitation, isPairURL } from '../shared/pairing.js';

const mocks = vi.hoisted(() => ({
  handlers: new Map<string, Parameters<IpcMain['handle']>[1]>(),
  spawn: vi.fn(),
  clipboard: vi.fn()
}));
vi.mock('electron', () => ({
  app: { getAppPath: () => '/local/TokenMeter.app/Contents/Resources/Electron' },
  clipboard: { writeText: mocks.clipboard },
  ipcMain: { handle: (name: string, listener: Parameters<IpcMain['handle']>[1]) => mocks.handlers.set(name, listener) }
}));
vi.mock('./deviceUsage.js', () => ({ deviceCLI: () => '/local/TokenMeter.app/Contents/MacOS/token-meter' }));
vi.mock('node:child_process', async importOriginal => ({ ...(await importOriginal<typeof import('node:child_process')>()), spawn: mocks.spawn }));
import { registerPairing, isDashboardURL } from './devicePairing.js';

const page = 'file:///local/TokenMeter.app/Contents/Resources/Electron/dist-renderer/index.html';
const id = 'ef70feb7-7722-4ac1-aee0-203889050119';
const code = '7K3M-Q9TX-5V2R';
const url = 'tokenmeter://pair/7K3MQ9#v1.ABCDEFGHIJKLMNOPQRSTUVWXYZ123456';
const device = { name: 'OpenClaw', role: 'peer', id: 'b'.repeat(64) };
function fixture(address = page) {
  const frame = { url: address };
  const owner = Object.assign(new EventEmitter(), { id: 3, send: vi.fn(), isDestroyed: () => false, getURL: () => address, mainFrame: frame });
  const event = { sender: owner, senderFrame: frame };
  const command = (channel: string, ...args: unknown[]) => {
    const handler = mocks.handlers.get('pair:' + channel)!;
    return Reflect.apply(handler, undefined, [event, ...args]);
  };
  const child = Object.assign(new EventEmitter(), {
    stdin: new PassThrough(), stdout: new PassThrough(), exitCode: null, signalCode: null, kill: vi.fn()
  });
  mocks.spawn.mockReturnValue(child);
  return { owner, event, command, child };
}
beforeEach(() => { vi.clearAllMocks(); mocks.handlers.clear(); registerPairing(); });

describe('桌面配对代理', () => {
  it('recognizes the same installed index file through a macOS path alias', () => {
    const folder = mkdtempSync(join(tmpdir(), 'tokenmeter-pair-test-'));
    const root = join(folder, 'bundle');
    try {
      mkdirSync(join(root, 'dist-renderer'), { recursive: true });
      writeFileSync(join(root, 'dist-renderer/index.html'), '');
      symlinkSync(root, join(folder, 'alias'), 'junction');
      expect(isDashboardURL(pathToFileURL(join(root, 'dist-renderer/index.html')).href, join(folder, 'alias'))).toBe(true);
      expect(isDashboardURL('https://example.org/index.html', root)).toBe(false);
    } finally { rmSync(folder, { recursive: true, force: true }); }
  });

  it('rejects requests from external pages, nested frames and invalid invitations', () => {
    const foreign = fixture('https://example.org/');
    expect(() => foreign.command('start', id, { mode: 'create', role: 'peer' })).toThrow();
    const local = fixture();
    local.event.senderFrame = { url: page };
    expect(() => local.command('pending')).toThrow();
    const user = fixture();
    expect(() => user.command('start', id, { mode: 'join', invitation: '--relay=https://example.org' })).toThrow();
    expect(() => user.command('start', id, { mode: 'create', role: 'anything' })).toThrow();
    expect(mocks.spawn).not.toHaveBeenCalled();
    expect(isPairInvitation('7K3M-Q9TX-5V2O')).toBe(false);
    expect(isPairURL(url.replace('#', '?next=something#'))).toBe(false);
  });

  it('keeps a join token off argv and uses only validated remote events for authorization', () => {
    const { command, child, owner } = fixture();
    command('start', id, { mode: 'join', invitation: url, role: 'peer' });
    expect(mocks.spawn.mock.calls[0][1]).toEqual(['pair', '--json', '--role', 'peer', '--join-stdin']);
    expect(JSON.parse(child.stdin.read().toString())).toEqual({ invitation: url });
    expect(() => command('decide', id, true)).toThrow();
    const frame = JSON.stringify({ state: 'confirm', ...device, canApprove: true, verification: '123 456' });
    child.stdout.write(frame.slice(0, 32)); child.stdout.write(frame.slice(32) + '\n');
    expect(owner.send).toHaveBeenCalledWith('pair:update', id, JSON.parse(frame));
    command('decide', id, true);
    expect(JSON.parse(child.stdin.read().toString())).toEqual({ approve: true });
    expect(() => command('decide', id, true)).toThrow();
    child.stdout.write(JSON.stringify({ state: 'waiting', ...device }) + '\n');
    child.stdout.write(JSON.stringify({ state: 'paired', ...device }) + '\n');
    expect(owner.send.mock.lastCall?.[2].state).toBe('paired');
    expect(() => command('copy', id, 'code')).toThrow();
    child.emit('close');
  });

  it('copies the current invitation only on request and terminates the session on main-frame navigation', () => {
    const { command, child, owner } = fixture();
    command('start', id, { mode: 'create', role: 'viewer' });
    expect(() => command('copy', id, 'url')).toThrow();
    child.stdout.write(JSON.stringify({ state: 'invitation', code, url, role: 'viewer', expiresAt: new Date(Date.now() + 60_000).toISOString() }) + '\n');
    expect(mocks.clipboard).not.toHaveBeenCalled();
    command('copy', id, 'url');
    expect(mocks.clipboard).toHaveBeenCalledWith(url);
    owner.emit('did-start-navigation', { isMainFrame: false, isSameDocument: false });
    expect(child.kill).not.toHaveBeenCalled();
    owner.emit('did-start-navigation', { isMainFrame: true, isSameDocument: false });
    expect(child.kill).toHaveBeenCalledOnce();
    expect(owner.send.mock.lastCall?.[2].state).toBe('cancelled');
    child.emit('close');
    expect(() => command('copy', id, 'url')).toThrow();
  });
});
