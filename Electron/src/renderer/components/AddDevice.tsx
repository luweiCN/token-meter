import { Dialog } from 'radix-ui';
import { QRCodeSVG } from 'qrcode.react';
import { useEffect, useRef, useState } from 'react';
import { isPairInvitation, type PairEvent, type PairRequest, type PairRole, type TrustedDevice } from '../../shared/pairing.js';
import { showToast } from './toast.js';
import { Button, Select } from './ui.js';
import './devicePairing.css';

type Props = { invitation: string | null; onInvitationHandled?: () => void; onPaired: () => void };
type Screen = 'create' | 'join' | 'manage';
const roleLabels: Record<TrustedDevice['role'], string> = {
  peer: '双向同步', viewer: '对方只读查看', source: '本机只读查看'
};

function Invitation({ event, copy }: { event: Extract<PairEvent, { state: 'invitation' }>; copy: (field: 'code' | 'url') => void }) {
  const [now, setNow] = useState(Date.now);
  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(timer);
  }, []);
  const seconds = Math.max(0, Math.ceil((Date.parse(event.expiresAt) - now) / 1000));
  const remaining = Math.floor(seconds / 60) + ':' + String(seconds % 60).padStart(2, '0');
  return <div className="pair-invite">
    <QRCodeSVG value={event.url} size={156} marginSize={4} level="M" role="img" aria-label="此邀请的配对二维码" />
    <div className="pair-details">
      <p>在另一台设备的「添加设备」输入此码，或扫描二维码。</p>
      <code className="pair-code">{event.code}</code>
      <p className="pair-meta">{roleLabels[event.role]} · {seconds ? '有效时间 ' + remaining : '已过期'}</p>
      <div className="pair-actions">
        <button className="btn" disabled={!seconds} onClick={() => copy('code')}>复制配对码</button>
        <button className="btn" disabled={!seconds} onClick={() => copy('url')}>复制邀请链接</button>
      </div>
    </div>
  </div>;
}

function TrustedDevices({ onChange }: { onChange: () => void }) {
  const [peers, setPeers] = useState<TrustedDevice[] | null>(null);
  const [removing, setRemoving] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [reload, setReload] = useState(0);
  useEffect(() => {
    let active = true;
    window.tokenMeter.pairing.list().then(result => { if (active) setPeers(result); })
      .catch(() => { if (active) setError('暂时无法读取配对清单。'); });
    return () => { active = false; };
  }, [reload]);
  async function remove(id: string) {
    setBusy(true);
    try {
      await window.tokenMeter.pairing.remove(id);
      setPeers(previous => previous?.filter(p => p.id !== id) ?? []);
      setRemoving(null);
      setError('');
      onChange();
    } catch { setError('解除配对失败，请重试。'); }
    finally { setBusy(false); }
  }
  return <>
    {error && <p role="alert">{error} <button className="btn" onClick={() => { setError(''); setReload(n => n + 1); }}>重试</button></p>}
    {!peers && !error && <p role="status">正在读取配对清单…</p>}
    {peers?.length === 0 && <p>还没有已配对设备。</p>}
    {peers?.map(peer => <div className="pair-trust" key={peer.id}>
      <div><strong>{peer.name}</strong><span>{roleLabels[peer.role]}</span></div>
      {removing === peer.id ? <>
        <p>解除后将停止与此设备直接通信。已同步的用量仍可查看。</p>
        <div className="pair-actions">
          <button className="btn danger" disabled={busy} onClick={() => void remove(peer.id)}>确认解除配对</button>
          <button className="btn" disabled={busy} onClick={() => setRemoving(null)}>保留配对</button>
        </div>
      </> : <button className="btn" aria-label={'解除与 ' + peer.name + ' 的配对'} onClick={() => setRemoving(peer.id)}>解除配对</button>}
    </div>)}
  </>;
}

export function AddDevice({ invitation, onInvitationHandled, onPaired }: Props) {
  const [open, setOpen] = useState(false);
  const [screen, setScreen] = useState<Screen>('create');
  const [role, setRole] = useState<PairRole>('peer');
  const [joinRole, setJoinRole] = useState<PairRole>('peer');
  const [value, setValue] = useState('');
  const [event, setEvent] = useState<PairEvent | null>(null);
  const [deciding, setDeciding] = useState(false);
  const session = useRef<string | null>(null);
  const api = window.tokenMeter.pairing;

  useEffect(() => {
    const unsubscribe = api.onUpdate((id, update) => {
      if (id !== session.current) return;
      setEvent(previous => update.state === 'waiting' && previous?.state === 'confirm'
        ? { ...update, verification: previous.verification } : update);
      setDeciding(false);
      if (!['confirm', 'connecting', 'invitation', 'waiting'].includes(update.state)) session.current = null;
      if (update.state === 'paired') onPaired();
    });
    return () => {
      unsubscribe();
      if (session.current) {
        void api.cancel(session.current).catch(() => {});
        session.current = null;
      }
    };
  }, [api, onPaired]);

  useEffect(() => {
    // A new link cannot cancel a verification the user is already reviewing.
    if (invitation && !session.current) {
      setValue(invitation);
      setScreen('join');
      setEvent(null);
      setOpen(true);
      onInvitationHandled?.();
    }
  }, [invitation, onInvitationHandled, event?.state]);

  function reset() {
    if (session.current) void api.cancel(session.current).catch(() => {});
    session.current = null;
    setEvent(null);
    setDeciding(false);
  }

  function changeOpen(next: boolean) {
    if (!next) { reset(); setValue(''); }
    setOpen(next);
  }

  async function start(request: PairRequest) {
    if (session.current) return;
    const id = crypto.randomUUID();
    session.current = id;
    setEvent({ state: 'connecting' });
    try { await api.start(id, request); }
    catch { if (session.current === id) { session.current = null; setEvent({ state: 'error', message: '无法启动配对。请检查命令行服务，然后重试。' }); } }
  }

  async function decide(approve: boolean) {
    const id = session.current;
    if (!id || deciding) return;
    setDeciding(true);
    try { await api.decide(id, approve); }
    catch {
      if (id === session.current) {
        reset();
        setEvent({ state: 'error', message: '这次确认未能送达，请重新配对。' });
      }
    }
  }

  function copy(field: 'url' | 'code') {
    if (session.current) void api.copy(session.current, field)
      .then(() => showToast('ok', field === 'url' ? '已复制邀请链接' : '已复制配对码'))
      .catch(() => showToast('error', '复制失败，请重新创建邀请。'));
  }

  const title = screen === 'manage' ? '已配对设备' : (event?.state === 'confirm' || event?.state === 'waiting') ? '核对设备' : event?.state === 'paired' ? '配对成功' : '添加设备';
  return <Dialog.Root open={open} onOpenChange={changeOpen}>
    <Button onClick={() => { setScreen('manage'); setOpen(true); }}>管理配对</Button>
    <Dialog.Trigger asChild><button className="btn primary" type="button" onClick={() => { setScreen('create'); setValue(''); }}>添加设备</button></Dialog.Trigger>
    <Dialog.Portal><Dialog.Overlay className="pair-overlay" /><Dialog.Content className="dlg pair-dialog" aria-describedby={undefined}
      onEscapeKeyDown={e => {
        if (document.activeElement?.closest('.sel.open')) e.preventDefault();
      }}
      onPointerDownOutside={e => { if (session.current) e.preventDefault(); }}>
      <div className="pair-head"><Dialog.Title>{title}</Dialog.Title><Dialog.Close className="btn" type="button" aria-label="关闭配对窗口">关闭</Dialog.Close></div>
      {screen === 'manage' ? <TrustedDevices onChange={onPaired} /> : <>
        {!event && <>
          <div className="pair-tabs seg" role="group" aria-label="配对方式">
            <button type="button" className={screen === 'create' ? 'on' : ''} aria-pressed={screen === 'create'} onClick={() => setScreen('create')}>邀请另一台设备</button>
            <button type="button" className={screen === 'join' ? 'on' : ''} aria-pressed={screen === 'join'} onClick={() => setScreen('join')}>输入配对码</button>
          </div>
          {screen === 'create' ? <div className="pair-form">
            <div className="pair-field">
              <label htmlFor="pair-role">另一台设备的权限</label>
              <Select<PairRole> id="pair-role" ariaLabel="另一台设备的权限" value={role} placeholder={null}
                options={[{ value: 'peer', label: '双向同步用量' }, { value: 'viewer', label: '只读查看用量' }]}
                onChange={next => { if (next) setRole(next); }} />
              <p>{role === 'peer' ? '两台设备都能查看和同步用量。' : '对方可以查看已同步的用量和额度。'}</p>
            </div>
            <div className="pair-actions"><Button variant="primary" onClick={() => void start({ mode: 'create', role })}>创建邀请</Button></div>
          </div> : <form className="pair-form" onSubmit={e => {
            e.preventDefault();
            if (isPairInvitation(value.trim())) void start({ mode: 'join', invitation: value.trim(), role: joinRole });
          }}>
            <div className="pair-field">
              <label htmlFor="pair-input">配对码或邀请链接</label>
              <div className="field"><input id="pair-input" placeholder="输入配对码，或粘贴邀请链接" type="text" value={value} maxLength={2048}
                spellCheck={false} autoCapitalize="off" autoComplete="off" onChange={e => setValue(e.target.value)} /></div>
              <p>在另一台设备选择「创建邀请」，或在终端运行 <code>token-meter pair</code>。</p>
            </div>
            <div className="pair-field">
              <label htmlFor="pair-join-role">允许的连接方式</label>
              <Select<PairRole> id="pair-join-role" ariaLabel="允许的连接方式" value={joinRole} placeholder={null}
                options={[{ value: 'peer', label: '双向同步，需双方确认' }, { value: 'viewer', label: '仅查看对方用量' }]}
                onChange={next => { if (next) setJoinRole(next); }} />
            </div>
            <div className="pair-actions"><Button variant="primary" type="submit" disabled={!isPairInvitation(value.trim())}>加入配对</Button></div>
          </form>}
        </>}
        {event?.state === 'connecting' && <p role="status">正在连接配对服务…</p>}
        {event?.state === 'invitation' && <Invitation event={event} copy={copy} />}
        {event?.state === 'confirm' && <div className="pair-verify">
          <strong>{event.name}</strong>
          <span>{event.role === 'viewer' ? (event.canApprove ? '对方将以只读方式查看用量。' : '本机将以只读方式查看用量。') : '两台设备将双向同步用量。'}</span>
          <p>核对两台设备显示的校验码是否相同。</p>
          <code className="pair-code" aria-label="校验码">{event.verification}</code>
          {event.canApprove ? <div className="pair-actions">
            <button className="btn primary" disabled={deciding} onClick={() => void decide(true)}>{deciding ? '正在提交…' : '校验码一致，确认配对'}</button>
            <button className="btn danger" disabled={deciding} onClick={() => void decide(false)}>拒绝</button>
          </div> : <p role="status">请在发起邀请的设备上确认。</p>}
        </div>}
        {event?.state === 'waiting' && <div className="pair-verify" role="status">
          <strong>{event.name}</strong>
          <p>本机已确认，正在等待对方完成配对。</p>
          {event.verification && <code className="pair-code" aria-label="校验码">{event.verification}</code>}
        </div>}
        {event?.state === 'paired' && <><p role="status">已与 <strong>{event.name}</strong> 配对。{event.role === 'peer' ? '两台设备会自动同步用量。' : '已建立只读连接。'}</p>
          <div className="pair-actions"><Dialog.Close asChild><button type="button" className="btn primary">完成</button></Dialog.Close></div></>}
        {event && ['error', 'expired', 'cancelled', 'rejected'].includes(event.state) && 'message' in event && <>
          <p role="alert">{event.message}</p><button className="btn" onClick={() => { reset(); setValue(''); }}>重新配对</button>
        </>}
        {(event?.state === 'connecting' || event?.state === 'invitation' || event?.state === 'waiting' || (event?.state === 'confirm' && !event.canApprove)) &&
          <button className="btn pair-cancel" onClick={() => { reset(); setEvent({ state: 'cancelled', message: '配对已取消。' }); }}>取消配对</button>}
      </>}
    </Dialog.Content></Dialog.Portal>
  </Dialog.Root>;
}
