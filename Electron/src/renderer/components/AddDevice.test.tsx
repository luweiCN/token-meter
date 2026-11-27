// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, expect, it, vi } from 'vitest';
import userEvent from '@testing-library/user-event';
import { AddDevice } from './AddDevice.js';
import type { PairEvent, PairingAPI, TrustedDevice } from '../../shared/pairing.js';

const link = 'tokenmeter://pair/7K3MQ9#v1.ABCDEFGHIJKLMNOPQRSTUVWXYZ123456';
const code = '7K3M-Q9TX-5V2R';
const peer = { id: 'b'.repeat(64), name: 'openclaw', role: 'peer' as const };
afterEach(() => { cleanup(); vi.unstubAllGlobals(); });

function fixture(invitation: string | null = null) {
  let notify: (id: string, state: PairEvent) => void = () => {};
  const api = {
    start: vi.fn<PairingAPI['start']>().mockResolvedValue(), decide: vi.fn().mockResolvedValue(undefined), cancel: vi.fn().mockResolvedValue(undefined),
    copy: vi.fn().mockResolvedValue(undefined), list: vi.fn<() => Promise<TrustedDevice[]>>().mockResolvedValue([]),
    remove: vi.fn().mockResolvedValue(undefined), takeInvitation: vi.fn().mockResolvedValue(null), onInvitation: vi.fn(() => () => {}),
    onUpdate(callback) { notify = callback; return () => {}; }
  } satisfies PairingAPI;
  vi.stubGlobal('tokenMeter', { pairing: api });
  const onPaired = vi.fn();
  const view = render(<AddDevice invitation={invitation} onPaired={onPaired} />);
  const update = (event: PairEvent) => act(() => notify(api.start.mock.calls[0][0], event));
  return { api, update, onPaired, view };
}

it('creates a read-only QR invitation, copies only on request and confirms the displayed code', async () => {
  const { api, update, onPaired } = fixture();
  fireEvent.click(screen.getByRole('button', { name: '添加设备' }));
  const user = userEvent.setup();
  const permission = screen.getByRole('button', { name: '另一台设备的权限' });
  await user.click(permission);
  await user.keyboard('{Escape}');
  expect(screen.getByRole('dialog')).toBeTruthy();
  expect(document.activeElement).toBe(permission);
  await user.keyboard('{ArrowDown}{End}{Enter}');
  fireEvent.click(screen.getByRole('button', { name: '创建邀请' }));
  expect(api.start).toHaveBeenCalledWith(expect.any(String), { mode: 'create', role: 'viewer' });
  update({ state: 'invitation', role: 'viewer', code, url: link, expiresAt: new Date(Date.now() + 600_000).toISOString() });
  expect(await screen.findByRole('img', { name: '此邀请的配对二维码' })).toBeTruthy();
  expect(screen.getByText(code)).toBeTruthy();
  fireEvent.click(screen.getByRole('button', { name: '复制邀请链接' }));
  expect(api.copy).toHaveBeenCalledWith(expect.any(String), 'url');
  update({ ...peer, role: 'viewer', state: 'confirm', canApprove: true, verification: '123 456' });
  expect(screen.getByText('对方将以只读方式查看用量。')).toBeTruthy();
  expect(screen.getByLabelText('校验码').textContent).toBe('123 456');
  expect(api.decide).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole('button', { name: '校验码一致，确认配对' }));
  expect(api.decide).toHaveBeenCalledWith(expect.any(String), true);
  update({ ...peer, role: 'viewer', state: 'waiting' });
  expect(screen.getByText('本机已确认，正在等待对方完成配对。')).toBeTruthy();
  expect(screen.getByLabelText('校验码').textContent).toBe('123 456');
  update({ ...peer, role: 'viewer', state: 'paired' });
  expect(await screen.findByRole('heading', { name: '配对成功' })).toBeTruthy();
  expect(onPaired).toHaveBeenCalledOnce();
});

it('prefills deep links, requires an explicit join, and cancels an in-flight join on unmount', async () => {
  const { api, update, view } = fixture(link);
  expect((await screen.findByLabelText('配对码或邀请链接') as HTMLInputElement).value).toBe(link);
  expect(api.start).not.toHaveBeenCalled();
  const user = userEvent.setup();
  await user.click(screen.getByRole('button', { name: '允许的连接方式' }));
  await user.click(screen.getByRole('option', { name: '仅查看对方用量' }));
  fireEvent.click(screen.getByRole('button', { name: '加入配对' }));
  expect(api.start).toHaveBeenCalledWith(expect.any(String), { mode: 'join', invitation: link, role: 'viewer' });
  update({ ...peer, state: 'confirm', role: 'viewer', canApprove: false, verification: '654 321' });
  expect(screen.getByText('请在发起邀请的设备上确认。')).toBeTruthy();
  expect(screen.queryByRole('button', { name: '校验码一致，确认配对' })).toBeNull();
  view.unmount();
  expect(api.cancel).toHaveBeenCalledOnce();
});

it('displays expiry and allows a fresh invitation', () => {
  const { api, update } = fixture();
  fireEvent.click(screen.getByRole('button', { name: '添加设备' }));
  fireEvent.click(screen.getByRole('button', { name: '创建邀请' }));
  update({ state: 'expired', message: '邀请已过期' });
  expect(screen.getByRole('alert').textContent).toBe('邀请已过期');
  fireEvent.click(screen.getByRole('button', { name: '重新配对' }));
  fireEvent.click(screen.getByRole('button', { name: '创建邀请' }));
  expect(api.start).toHaveBeenCalledTimes(2);
  expect(api.start.mock.calls[0][0]).not.toBe(api.start.mock.calls[1][0]);
});

it('requires confirmation before revoking access for a viewer without consumption', async () => {
  const { api } = fixture();
  api.list.mockResolvedValue([{ ...peer, role: 'viewer' }]);
  fireEvent.click(screen.getByRole('button', { name: '管理配对' }));
  await screen.findByText('对方只读查看');
  fireEvent.click(screen.getByRole('button', { name: '解除与 openclaw 的配对' }));
  expect(api.remove).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole('button', { name: '确认解除配对' }));
  await waitFor(() => expect(screen.getByText('还没有已配对设备。')).toBeTruthy());
  expect(api.remove).toHaveBeenCalledWith(peer.id);
});
