import { app } from 'electron';
import { execFile } from 'node:child_process';
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { promisify } from 'node:util';
import type { DeviceReport } from '../renderer/api.js';

const exec = promisify(execFile);
export function deviceCLI(): string {
  const bundled = resolve(app.getAppPath(), '../../MacOS/token-meter');
  if (app.getAppPath().includes('.app/Contents/Resources/') || existsSync(bundled)) return bundled;
  return join(homedir(), '.local', 'bin', 'token-meter');
}

export async function queryDeviceUsage(host: string, from: string): Promise<DeviceReport> {
  if (host !== '' && !/^[0-9a-f]{64}$/.test(host)) throw new Error('设备 ID 无效');
  if (from !== '' && !/^\d{4}-\d{2}-\d{2}$/.test(from)) throw new Error('日期无效');
  const cli = deviceCLI();
  const args = ['usage', '--json'];
  if (host) args.push('--host', host);
  if (from) args.push('--from', from);
  const result = await exec(cli, args, { timeout: 10_000, maxBuffer: 8 * 1024 * 1024 });
  return JSON.parse(result.stdout) as DeviceReport;
}
