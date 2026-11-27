// @vitest-environment jsdom

import { fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, expect, it, vi } from 'vitest';
import type { DeviceReport } from '../api.js';
import type { TrustedDevice } from '../../shared/pairing.js';
import { Devices } from './Devices.js';

afterEach(() => { vi.unstubAllGlobals(); });
it('queries all devices and keeps the device selector available after filtering', async () => {
  const devices = [
    { id: 'a'.repeat(64), name: 'Mac', local: true, os: 'darwin', tokens: 10, unknownTokens: 0, observed: 1780000000 },
    { id: 'b'.repeat(64), name: 'Claw', local: false, os: 'linux', tokens: 2, unknownTokens: 0, observed: 1780000000 }
  ];
  const query = vi.fn(async (host: string): Promise<DeviceReport> => {
    const visible = devices.filter(d => !host || host === d.id);
    return { devices: visible, agents: [], quotas: [], tokens: visible.reduce((n, d) => n + d.tokens, 0), costMicros: 0, unknownCost: 0, unknownTokens: 0 };
  });
  vi.stubGlobal('tokenMeter', { devices: { query }, pairing: { list: async () => [], onUpdate: () => () => {} } });
  render(<Devices />);
  const user = userEvent.setup();
  await screen.findByRole('table', { name: '设备明细' });
  const filter = screen.getByRole('button', { name: '按设备筛选' });
  await user.click(filter);
  await user.keyboard('{End}{Enter}');
  await waitFor(() => expect(query).toHaveBeenCalledWith(devices[1].id, ''));
  expect(await screen.findByText('Linux')).toBeTruthy();
  await user.click(filter);
  expect(screen.getByRole('option', { name: 'Mac（本机）' })).toBeTruthy();
  await user.click(screen.getByRole('option', { name: '全部设备' }));

  const period = within(screen.getByRole('group', { name: '时间范围' }));
  const date = new Date();
  const month = [date.getFullYear(), String(date.getMonth() + 1).padStart(2, '0')].join('-');
  await user.click(period.getByRole('button', { name: '本月' }));
  await waitFor(() => expect(query).toHaveBeenLastCalledWith('', month + '-01'));
  await user.click(period.getByRole('button', { name: '今天' }));
  await waitFor(() => expect(query).toHaveBeenLastCalledWith('', month + '-' + String(date.getDate()).padStart(2, '0')));
  expect(period.getByRole('button', { name: '今天' }).getAttribute('aria-pressed')).toBe('true');
  await user.click(period.getByRole('button', { name: '累计' }));
  await waitFor(() => expect(query).toHaveBeenLastCalledWith('', ''));
});


it('shows amount-only quotas at the supplied precision and preserves the wallet currency', async () => {
  const report: DeviceReport = {
    devices: [], agents: [], tokens: 0, costMicros: 0, unknownCost: 0, unknownTokens: 0,
    quotas: [{ provider: 'manual', account: 'home', observedAt: '2026-01-01T00:00:00Z',
      windows: [{ label: '本月', remainingAmount: '9007199254740993.125', unit: 'Token' }],
      balance: '0.12', balanceUnit: 'USD' }]
  };
  vi.stubGlobal('tokenMeter', { devices: { query: async () => report }, pairing: { list: async () => [], onUpdate: () => () => {} } });
  render(<Devices />);
  expect(await screen.findByText('本月 剩余 9007199254740993.125 Token · 0.12 USD')).toBeTruthy();
});


it('uses product platform and quota names and preserves unknown operating systems', async () => {
  const report: DeviceReport = {
    tokens: 0, unknownTokens: 0, costMicros: 0, unknownCost: 0, agents: [],
    devices: ['darwin', 'windows', 'freebsd'].map((os, index) => ({
      id: String(index).repeat(64), name: 'Device ' + index, local: index === 0, os, tokens: 0, unknownTokens: 0, observed: 1780000000
    })),
    quotas: [{ provider: 'antigravity', account: 'demo', observedAt: '2026-01-01T00:00:00Z', balance: '15' }]
  };
  vi.stubGlobal('tokenMeter', { devices: { query: async () => report }, pairing: { list: async () => [], onUpdate: () => () => {} } });
  render(<Devices />);
  const deviceTable = within(await screen.findByRole('table', { name: '设备明细' }));
  for (const label of ['macOS', 'Windows', 'freebsd']) expect(deviceTable.getByText(label)).toBeTruthy();
  expect(screen.getByText('AGY · demo')).toBeTruthy();
});

it('keeps direct contact independent of the source snapshot, including on refresh and lookup failure', async () => {
  const now = Math.floor(Date.now() / 1000);
  const report: DeviceReport = {
    devices: ['Mac', 'OpenClaw', '未联系的设备', '经其他主机转发'].map((name, i) => ({
      id: i.toString().repeat(64), name, local: i === 0, os: 'linux', tokens: 8, unknownTokens: 0, observed: now - 600
    })), agents: [], quotas: [], tokens: 32, unknownTokens: 0, costMicros: 0, unknownCost: 0
  };
  const direct = { id: report.devices[1].id, name: report.devices[1].name, role: 'peer' as const };
  const newPeer = { id: report.devices[2].id, name: report.devices[2].name, role: 'peer' as const };
  const list = vi.fn<() => Promise<TrustedDevice[]>>()
    .mockResolvedValueOnce([{ ...direct, lastSync: now - 70 }, newPeer])
    .mockResolvedValueOnce([{ ...direct, lastSync: now - 10 }, newPeer])
    .mockRejectedValueOnce(new Error('timeout'));
  vi.stubGlobal('tokenMeter', { devices: { query: async () => report }, pairing: { list, onUpdate: () => () => {} } });
  render(<Devices />);

  const table = within(await screen.findByRole('table', { name: '设备明细' }));
  expect(table.getByRole('columnheader', { name: '最近联系' })).toBeTruthy();
  expect(table.getByRole('columnheader', { name: '数据更新' })).toBeTruthy();
  const record = (name: string) => within(table.getByRole('row', { name: new RegExp(name) }));
  expect(await record('Mac').findByText('本机采集')).toBeTruthy();
  expect(await record('未联系的设备').findByText('暂无记录')).toBeTruthy();
  expect(record('经其他主机转发').getByText('未直接配对')).toBeTruthy();
  const timestamps = () => record('OpenClaw').getAllByRole('time').map(t => t.getAttribute('datetime'));
  const iso = (sec: number) => new Date(sec * 1000).toISOString();
  expect(timestamps()).toEqual([iso(now - 70), iso(now - 600)]);
  expect(record('OpenClaw').getByTitle(new Date((now - 70) * 1000).toLocaleString())).toBeTruthy();

  fireEvent.focus(window);
  await waitFor(() => expect(timestamps()).toEqual([iso(now - 10), iso(now - 600)]));
  fireEvent.focus(window);
  expect(await record('OpenClaw').findByText('暂不可用')).toBeTruthy();
  expect(timestamps()).toEqual([iso(now - 600)]);
  expect(record('OpenClaw').getByRole('cell', { name: '8' })).toBeTruthy();
});
