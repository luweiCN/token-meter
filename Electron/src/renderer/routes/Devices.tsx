import { useCallback, useEffect, useState } from 'react';
import type { TrustedDevice } from '../../shared/pairing.js';
import { AddDevice } from '../components/AddDevice.js';
import { FilterBar, Select } from '../components/ui.js';
import type { DeviceQuotaWindow, DeviceReport } from '../api.js';
import { formatCredits, formatRelative, formatReportedTokens, formatTokens, formatUsdMicros } from '../format.js';
import { providerLabel, quotaProviderLabel } from '../providers.js';
import { useSettings } from '../stores/settingsStore.js';
import './devices.css';

const operatingSystems = new Map([['darwin', 'macOS'], ['linux', 'Linux'], ['windows', 'Windows']]);

const periods = [
  { value: 'all', label: '累计' },
  { value: 'month', label: '本月' },
  { value: 'today', label: '今天' }
] as const;
type Period = typeof periods[number]['value'];

function startDate(period: Period): string {
  if (period === 'all') return '';
  const d = new Date();
  if (period === 'month') d.setDate(1);
  return [d.getFullYear(), String(d.getMonth() + 1).padStart(2, '0'), String(d.getDate()).padStart(2, '0')].join('-');
}
function windowReading(w: DeviceQuotaWindow): string {
  if (w.remainingPercent !== undefined) return `${w.label} ${Math.round(w.remainingPercent)}%`;
  const unit = w.unit ? ' ' + w.unit : '';
  if (w.remainingAmount !== undefined) return `${w.label} 剩余 ${w.remainingAmount}${unit}`;
  if (w.usedAmount !== undefined) return `${w.label} 已用 ${w.usedAmount}${unit}`;
  return `${w.label} 总量 ${w.totalAmount ?? '未知'}${unit}`;
}
function deviceLabel(device: DeviceReport['devices'][number]): string {
  return device.name + (device.local ? '（本机）' : '');
}

function DeviceTime({ seconds }: { seconds: number }) {
  const date = new Date(seconds * 1000);
  if (seconds <= 0 || !Number.isFinite(date.getTime())) return <span className="muted">未知</span>;
  const exact = date.toLocaleString();
  const age = Date.now() - date.getTime();
  return <time dateTime={date.toISOString()} title={exact}>{age < 0 ? exact : formatRelative(age)}</time>;
}

function LastContact({ local, peers, id }: {
  local: boolean;
  peers: Map<string, TrustedDevice> | null | undefined;
  id: string;
}) {
  if (local) return <span className="muted">本机采集</span>;
  if (peers === undefined) return <span className="muted">读取中…</span>;
  if (peers === null) return <span className="muted" title="暂时无法读取本机的配对状态">暂不可用</span>;
  const peer = peers.get(id);
  if (!peer) return <span className="muted" title="本机当前未与此设备直接配对">未直接配对</span>;
  if (!peer.lastSync) return <span className="muted" title="本机还没有向此设备成功同步或查询的记录">暂无记录</span>;
  return <DeviceTime seconds={peer.lastSync} />;
}

export function Devices({ invitation = null, onInvitationHandled }: { invitation?: string | null; onInvitationHandled?: () => void } = {}) {
  const { providerOverrides } = useSettings();
  const [host, setHost] = useState<string | null>(null);
  const [period, setPeriod] = useState<Period>('all');
  const [report, setReport] = useState<DeviceReport | null>(null);
  const [devices, setDevices] = useState<DeviceReport['devices']>([]);
  const [peers, setPeers] = useState<Map<string, TrustedDevice> | null>();
  const [error, setError] = useState('');
  const [revision, setRevision] = useState(0);
  const refresh = useCallback(() => setRevision(n => n + 1), []);
  useEffect(() => {
    let active = true;
    let busy = false;
    let loadingPeers = false;
    setReport(null);
    async function loadPeers() {
      if (loadingPeers) return;
      loadingPeers = true;
      try {
        const list = await window.tokenMeter.pairing.list();
        if (active) setPeers(new Map(list.map(p => [p.id, p])));
      } catch {
        if (active) setPeers(null);
      } finally { loadingPeers = false; }
    }
    async function load() {
      if (busy) return;
      busy = true;
      try {
        const next = await window.tokenMeter.devices.query(host ?? '', startDate(period));
        if (active) {
          setReport(next);
          if (!host) setDevices(next.devices);
          setError('');
          if (next.devices.some(d => !d.local)) void loadPeers();
        }
      } catch {
        if (active) setError('未能读取设备用量。请检查 TokenMeter 命令行服务。');
      } finally { busy = false; }
    }
    void load();
    const timer = window.setInterval(() => { if (!document.hidden) void load(); }, 30_000);
    window.addEventListener('focus', load);
    return () => { active = false; window.clearInterval(timer); window.removeEventListener('focus', load); };
  }, [host, period, revision]);
  const showCredits = report?.agents.some(a => a.creditsPicos !== undefined) ?? false;

  return <section className="view device-view">
    <header className="vhead">
      <h1>设备用量</h1>
      {devices.length > 0 && <span className="sub">{devices.length} 台设备</span>}
      <div className="spacer" />
      <div className="device-actions"><AddDevice invitation={invitation} onInvitationHandled={onInvitationHandled} onPaired={refresh} /></div>
    </header>

    <div className="device-sections">
      <div className="card sess-filter-card device-filters">
        <FilterBar>
          <Select ariaLabel="按设备筛选" placeholder="全部设备" value={host} onChange={setHost}
            options={devices.map(d => ({ value: d.id, label: deviceLabel(d) }))} />
          <div className="seg" role="group" aria-label="时间范围">
            {periods.map(p => <button type="button" key={p.value} className={period === p.value ? 'on' : ''}
              aria-pressed={period === p.value} onClick={() => setPeriod(p.value)}>{p.label}</button>)}
          </div>
        </FilterBar>
      </div>

      {error && <p className="status-error" role="status">{error}</p>}
      {!report && !error && <p className="muted" role="status">正在读取设备用量…</p>}
      {report && <>
        <div className="stats device-stats" aria-label="用量汇总">
          <div className="stat"><div className="lb">Token 用量</div><div className="v">{formatReportedTokens(report.tokens, report.unknownTokens)}</div></div>
          <div className="stat" data-kind={report.unknownCost > 0 ? 'unknown' : undefined}>
            <div className="lb">已知费用</div><div className="v">{formatUsdMicros(report.costMicros)}</div>
            {report.unknownCost > 0 && <div className="sb">{report.unknownCost.toLocaleString()} 条用量缺少价格</div>}
          </div>
        </div>

        <section className="card" aria-labelledby="device-detail-title">
          <div className="chead"><h2 id="device-detail-title">设备明细</h2></div>
          {report.devices.length === 0 ? <p className="muted device-empty">暂无设备用量。</p> :
            <div className="hscroll"><table className="device-detail" aria-labelledby="device-detail-title">
              <thead><tr><th>设备</th><th>系统</th><th className="r">Token</th>
                <th className="r" title="本机最近一次向此设备成功同步或查询的时间">最近联系</th>
                <th className="r" title="来源设备生成当前用量快照的时间">数据更新</th></tr></thead>
              <tbody>{report.devices.map(d => <tr key={d.id}>
                <td className="device-name">{deviceLabel(d)}</td><td>{operatingSystems.get(d.os) ?? d.os}</td>
                <td className="r num">{formatReportedTokens(d.tokens, d.unknownTokens)}</td>
                <td className="r"><LastContact local={d.local} peers={peers} id={d.id} /></td>
                <td className="r"><DeviceTime seconds={d.observed} />
                  {!!d.partialSources && <span className="device-missing">{d.partialSources} 个来源未更新</span>}</td>
              </tr>)}</tbody>
            </table></div>}
        </section>

        {report.quotas.length > 0 && <section className="card" aria-labelledby="device-quota-title">
          <div className="chead"><h2 id="device-quota-title">账户额度</h2></div>
          <div className="hscroll"><table aria-labelledby="device-quota-title">
            <thead><tr><th>账户</th><th>剩余</th><th className="r">最后读取</th></tr></thead>
            <tbody>{report.quotas.map(q => <tr key={q.provider + q.account}>
              <td className="device-name">{quotaProviderLabel(q.provider, providerOverrides.find(o => o.providerId === q.provider)?.displayName)} · {devices.find(d => d.id === q.account)?.name ?? q.account}</td>
              <td className="device-quota-reading">{[...(q.windows ?? []).map(windowReading), ...(q.balance ? [q.balance === 'unlimited' ? '不限额' : q.balance + ' ' + (q.balanceUnit ?? '积分')] : [])].join(' · ')}</td>
              <td className="r"><time>{new Date(q.observedAt).toLocaleString()}</time></td>
            </tr>)}</tbody>
          </table></div>
        </section>}

        {report.agents.length > 0 && <section className="card" aria-labelledby="device-agent-title">
          <div className="chead"><h2 id="device-agent-title">Agent 与模型</h2></div>
          <div className="hscroll"><table aria-labelledby="device-agent-title">
            <thead><tr><th>Agent</th><th>模型</th><th className="r">Token</th><th className="r">缓存读取</th>
              {showCredits && <th className="r">积分用量</th>}<th className="r">已知费用</th></tr></thead>
            <tbody>{report.agents.map(a => <tr key={a.agent + '/' + a.model}>
              <td>{providerLabel(a.agent)}</td><td className="device-model">{a.model}</td>
              <td className="r num">{formatReportedTokens(a.input + a.output + a.cacheRead + a.cacheWrite, a.unknownTokens)}</td>
              <td className="r num">{formatTokens(a.cacheRead)}</td>
              {showCredits && <td className="r num">{a.creditsPicos ? formatCredits(a.creditsPicos) : '—'}</td>}
              <td className="r num">{formatUsdMicros(a.costMicros)}{a.unknownCost > 0 ? '†' : ''}</td>
            </tr>)}</tbody>
          </table></div>
        </section>}
      </>}
    </div>
  </section>;
}
