import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import {
  clearCredentials,
  extractWorkspaceId,
  readCredentials,
  writeCredentials
} from './opencodeGoLogin.js';

describe('OpenCode Go 凭证文件', () => {
  let directory: string;
  let file: string;

  beforeEach(() => {
    directory = fs.mkdtempSync(path.join(os.tmpdir(), 'tokenmeter-opencodego-'));
    file = path.join(directory, 'opencode-go.json');
  });

  afterEach(() => {
    fs.rmSync(directory, { recursive: true, force: true });
  });

  it('未配置时返回 null', () => {
    expect(readCredentials(file)).toBeNull();
  });

  it('写入后可读回，权限 600', () => {
    writeCredentials({ workspaceId: 'ws-1', authCookie: 'Fe26.2**abc' }, file);
    expect(readCredentials(file)).toEqual({ workspaceId: 'ws-1', authCookie: 'Fe26.2**abc' });
    const mode = fs.statSync(file).mode & 0o777;
    expect(mode).toBe(0o600);
  });

  it('损坏 JSON 返回 null', () => {
    fs.writeFileSync(file, '{not-json', { mode: 0o600 });
    expect(readCredentials(file)).toBeNull();
  });

  it('缺字段返回 null', () => {
    fs.writeFileSync(file, JSON.stringify({ workspaceId: 'ws-1' }), { mode: 0o600 });
    expect(readCredentials(file)).toBeNull();
  });

  it('清除后返回 null', () => {
    writeCredentials({ workspaceId: 'ws-1', authCookie: 'Fe26.2**abc' }, file);
    clearCredentials(file);
    expect(readCredentials(file)).toBeNull();
  });

  it('自动创建父目录', () => {
    const nested = path.join(directory, 'a', 'b', 'opencode-go.json');
    writeCredentials({ workspaceId: 'ws-1', authCookie: 'Fe26.2**abc' }, nested);
    expect(readCredentials(nested)).toEqual({ workspaceId: 'ws-1', authCookie: 'Fe26.2**abc' });
  });
});

describe('workspaceId 提取', () => {
  it('从 workspace 路径提取', () => {
    expect(extractWorkspaceId('https://opencode.ai/workspace/ws-abc123/go')).toBe('ws-abc123');
  });

  it('带查询参数也能提取', () => {
    expect(extractWorkspaceId('https://opencode.ai/workspace/ws-1?tab=billing')).toBe('ws-1');
  });

  it('非 workspace 页面返回 null', () => {
    expect(extractWorkspaceId('https://opencode.ai/')).toBeNull();
    expect(extractWorkspaceId('https://opencode.ai/docs/go/')).toBeNull();
  });
});
