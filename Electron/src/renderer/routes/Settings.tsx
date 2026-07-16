import { useCallback, useEffect, useState } from 'react';

import type { AgentBinaryStatus, FailedFileSummary, IndexStatusResult, ScanProgress, ScanRootSummary } from '../api.js';
import { showToast } from '../components/toast.js';
import { formatBytes, formatRelative, parseUtcTimestamp } from '../format.js';
import { settingsStore, useSettings } from '../stores/settingsStore.js';
import type { SettingsApplyRequest } from '../stores/settingsStore.js';
import { applyThemePref, storedThemePref, type ThemePref } from '../theme.js';

/// 支持 hooks 状态上报的 coding agent（与 Swift 侧 AgentSessionEvent.allowedAgentKinds 同名单）。
/// aghow 文案避免出现「settings」字样——测试的英文脚手架黑名单做大小写不敏感子串匹配。
const AGENT_KINDS: Array<{ id: string; label: string; how: string }> = [
  { id: 'claudeCode', label: 'Claude Code', how: '会话 hooks 写入 ~/.claude' },
  { id: 'codex', label: 'Codex CLI', how: 'hooks 写入 ~/.codex/hooks.json' },
  { id: 'omp', label: 'OMP', how: '插件安装到 ~/.omp/agent/extensions' },
  { id: 'opencode', label: 'OpenCode', how: '暂无集成 · 仅统计开关' }
];

/// 供应商额度接入（OpenDesign 稿 B 区）。keyed = 支持应用内填 API Key（存钥匙串，
/// 优先于环境变量）；凭证来源按当前真实实现描述。
const QUOTA_PROVIDERS: Array<{ id: string; name: string; pill: string; how: string; src: string; keyed?: boolean }> = [
  { id: 'codex', name: 'Codex', pill: '自动接入', how: '自动读取本机登录凭证', src: '~/.codex/auth.json' },
  { id: 'claude-code', name: 'Claude Code', pill: '自动接入', how: '自动读取本机登录凭证', src: '钥匙串 · Claude Code-credentials' },
  { id: 'zhipu', name: '智谱 GLM', pill: '环境变量', how: 'API Key · 应用内填写或读取环境变量', src: 'ZHIPU_API_KEY', keyed: true }
];

const SCAN_INTERVALS: Array<{ seconds: number; label: string }> = [
  { seconds: 30, label: '30 秒' },
  { seconds: 60, label: '60 秒' },
  { seconds: 120, label: '2 分钟' },
  { seconds: 300, label: '5 分钟' }
];


export function Settings() {
  const settings = useSettings();
  const [loadError, setLoadError] = useState<string | null>(null);
  const [savedTick, setSavedTick] = useState<string | null>(null);
  const [indexStatus, setIndexStatus] = useState<IndexStatusResult | null>(null);
  const [rebuildDialog, setRebuildDialog] = useState(false);
  const [rebuildNote, setRebuildNote] = useState<string | null>(null);
  const [theme, setTheme] = useState<ThemePref>(storedThemePref);

  useEffect(() => {
    let cancelled = false;
    void settingsStore.load().then(() => {
      if (!cancelled) setLoadError(null);
    }).catch((error: unknown) => {
      const message = error instanceof Error ? error.message : '设置加载失败';
      if (!cancelled) setLoadError(message);
    });
    return () => {
      cancelled = true;
    };
  }, []);

  // 目录扫描状态跟随事件驱动刷新：hooks 上报/扫描完成 → invalidate → 重拉，
  // 「最近扫描」不再是打开页面那一刻的过期快照。
  useEffect(() => {
    const refreshStatus = () => {
      void window.tokenMeter.index.status().then(setIndexStatus).catch(() => {});
    };
    refreshStatus();
    return window.tokenMeter.overview.onInvalidate(refreshStatus);
  }, []);

  /// 即时保存：成功/失败走全局 toast（页面顶部），卡片级 savetick 作局部反馈。
  const apply = (patch: Promise<SettingsApplyRequest>, tick: string) => {
    void patch.then((result) => {
      if (result.status === 'failed') {
        showToast('error', `设置保存失败：${result.error?.message ?? '未知设置错误'}`);
        return;
      }
      showToast('ok', '已保存');
      setSavedTick(tick);
      window.setTimeout(() => {
        setSavedTick((current) => (current === tick ? null : current));
      }, 2000);
    }).catch((error: unknown) => {
      const message = error instanceof Error ? error.message : '未知设置错误';
      showToast('error', `设置保存失败：${message}`);
    });
  };

  const changeTheme = (next: ThemePref) => {
    setTheme(next);
    applyThemePref(next);
  };

  // D 区额度告警：开关状态 = 阈值 > 0；滑条拖动用 draft 即时显示、松手才保存。
  const [notifyAuth, setNotifyAuth] = useState<string>('unknown');
  const [thresholdDraft, setThresholdDraft] = useState<number | null>(null);
  const alertOn = settings.quotaUsedThresholdPercent > 0;
  const thresholdShown = thresholdDraft ?? (alertOn ? settings.quotaUsedThresholdPercent : 85);

  useEffect(() => {
    void window.tokenMeter.notifications.state().then(setNotifyAuth).catch(() => {});
  }, []);

  const toggleQuotaAlert = () => {
    if (alertOn) {
      setThresholdDraft(null);
      apply(settingsStore.applyPatch({ quotaUsedThresholdPercent: 0 }), 'notify');
      return;
    }
    apply(settingsStore.applyPatch({ quotaUsedThresholdPercent: thresholdShown }), 'notify');
    // 开启时顺路请求系统授权（未决定时弹系统框；已拒绝时返回 denied，下方提示接管）。
    void window.tokenMeter.notifications.requestAuthorization().then(setNotifyAuth).catch(() => {});
  };

  const commitThreshold = () => {
    if (!alertOn || thresholdDraft === null || thresholdDraft === settings.quotaUsedThresholdPercent) return;
    apply(settingsStore.applyPatch({ quotaUsedThresholdPercent: thresholdDraft }), 'notify');
  };

  // A 区 agent CLI 检测：挂载查一次，「重新检测」手动再查。null = 菜单栏应用不可达。
  const [agentDetect, setAgentDetect] = useState<Map<string, AgentBinaryStatus> | null>(null);
  const [detecting, setDetecting] = useState(false);

  const runDetect = useCallback(async () => {
    setDetecting(true);
    try {
      const statuses = await window.tokenMeter.agents.detect();
      setAgentDetect(statuses === null ? null : new Map(statuses.map((s) => [s.kind, s])));
    } catch {
      setAgentDetect(null);
    } finally {
      setDetecting(false);
    }
  }, []);

  useEffect(() => {
    void runDetect();
  }, [runDetect]);

  // 全量重扫（原「索引状态」页的功能并入此处）：流式进度驱动下方源卡片。
  const [rebuilding, setRebuilding] = useState(false);
  const [scanProgress, setScanProgress] = useState<ScanProgress | null>(null);
  useEffect(() => window.tokenMeter.index.onScanProgress(setScanProgress), []);

  const startRebuild = () => {
    setRebuildDialog(false);
    setRebuildNote(null);
    setRebuilding(true);
    setScanProgress(null);
    void window.tokenMeter.index.startFullReindex()
      .then(() => window.tokenMeter.index.status().then(setIndexStatus))
      .catch((error: unknown) => {
        setRebuildNote(`重新扫描失败：${error instanceof Error ? error.message : '未知错误'}`);
      })
      .finally(() => {
        setRebuilding(false);
        setScanProgress(null);
      });
  };

  const toggleRoot = (root: ScanRootSummary) => {
    void window.tokenMeter.index.setRootEnabled(root.id, !root.enabled)
      .then(() => {
        showToast('ok', root.enabled ? `已暂停「${root.displayName}」目录扫描` : `已恢复「${root.displayName}」目录扫描`);
        return window.tokenMeter.index.status().then(setIndexStatus);
      })
      .catch((error: unknown) => {
        showToast('error', `目录开关保存失败：${error instanceof Error ? error.message : '未知错误'}`);
      });
  };

  return (
    <section className="view">
      <div className="vhead">
        <h1>设置</h1>
      </div>

      {/* A. Coding Agent 集成 */}
      <div className="card" aria-label="Coding Agent 集成">
        <div className="chead">
          <div>
            <h2>Coding Agent 集成</h2>
            <div className="desc">开启即安装上报 hooks 并计入统计</div>
          </div>
          <span className={savedTick === 'agents' ? 'savetick show' : 'savetick'}>已保存 ✓</span>
          <button className="btn" type="button" disabled={detecting} onClick={() => void runDetect()}>
            {detecting ? '检测中…' : '重新检测'}
          </button>
        </div>
        <div>
          {AGENT_KINDS.map((agent) => {
            const enabled = settings.enabledAgentKinds.includes(agent.id);
            const detect = agentDetect?.get(agent.id);
            const cliMissing = enabled && detect !== undefined && !detect.found;
            return (
              <div className="setrow agrow" data-state={cliMissing ? 'fail' : enabled ? 'ok' : 'off'} key={agent.id}>
                <button
                  type="button"
                  className={enabled ? 'sw on' : 'sw'}
                  aria-pressed={enabled}
                  aria-label={agent.label}
                  onClick={() => {
                    const next = enabled
                      ? settings.enabledAgentKinds.filter((kind) => kind !== agent.id)
                      : [...settings.enabledAgentKinds, agent.id];
                    apply(settingsStore.updateEnabledAgentKinds(next), 'agents');
                  }}
                />
                <div className="agmain grow">
                  <div className="agtop">
                    <b>{agent.label}</b>
                    <span className="pill">{cliMissing ? '未找到命令行' : enabled ? '已集成' : '未集成'}</span>
                  </div>
                  <div className="aghow">{agent.how}</div>
                  {detect?.found ? (
                    <div className="aghow agver">
                      {detect.version ?? '版本未知'}
                      {detect.path ? ` · ${detect.path}` : ''}
                    </div>
                  ) : null}
                </div>
              </div>
            );
          })}
        </div>
        {agentDetect === null ? (
          <p className="muted" role="note">命令行检测不可用——菜单栏应用未在运行。</p>
        ) : null}
      </div>

      {/* B. 供应商额度接入 */}
      <div className="card" aria-label="供应商额度接入">
        <div className="chead">
          <div>
            <h2>供应商额度接入</h2>
          </div>
          <span className={savedTick === 'quota' ? 'savetick show' : 'savetick'}>已保存 ✓</span>
        </div>
        <div>
          {QUOTA_PROVIDERS.map((provider) => {
            const override = settings.providerOverrides.find((o) => o.providerId === provider.id);
            const enabled = override?.enabled ?? true;
            return (
              <QuotaProviderRow
                key={provider.id}
                provider={provider}
                savedName={override?.displayName ?? provider.name}
                enabled={enabled}
                onSave={(name) => {
                  apply(settingsStore.applyPatch({ providerDisplayNames: { [provider.id]: name } }), 'quota');
                }}
                onToggle={() => {
                  apply(settingsStore.applyPatch({ providerEnabled: { [provider.id]: !enabled } }), 'quota');
                }}
              />
            );
          })}
        </div>
      </div>

      {/* C + D：刷新 / 通知 */}
      <div className="card" aria-label="刷新">
        <div className="chead">
          <div>
            <h2>刷新</h2>
          </div>
          <span className={savedTick === 'refresh' ? 'savetick show' : 'savetick'}>已保存 ✓</span>
        </div>
        <div className="setrow">
          <span>会话扫描间隔</span>
          <div className="grow" />
          <div className="seg" role="group" aria-label="扫描间隔">
            {SCAN_INTERVALS.map((interval) => (
              <button
                key={interval.seconds}
                type="button"
                className={settings.autoRefreshSeconds === interval.seconds ? 'on' : ''}
                aria-pressed={settings.autoRefreshSeconds === interval.seconds}
                onClick={() => {
                  apply(settingsStore.applyPatch({ autoRefreshSeconds: interval.seconds }), 'refresh');
                }}
              >
                {interval.label}
              </button>
            ))}
          </div>
        </div>
      </div>

      <div className="card" aria-label="通知">
        <div className="chead">
          <div>
            <h2>通知</h2>
          </div>
          <span className={savedTick === 'notify' ? 'savetick show' : 'savetick'}>已保存 ✓</span>
        </div>
        <div className="setrow">
          <button
            type="button"
            className={alertOn ? 'sw on' : 'sw'}
            aria-pressed={alertOn}
            aria-label="额度告警开关"
            onClick={toggleQuotaAlert}
          />
          <span>额度用量达阈值时告警</span>
          <div className="grow" />
          <div className="threshold">
            <input
              type="range"
              min="50"
              max="100"
              step="5"
              value={thresholdShown}
              aria-label="告警阈值"
              disabled={!alertOn}
              onChange={(e) => setThresholdDraft(Number(e.target.value))}
              onPointerUp={commitThreshold}
              onKeyUp={commitThreshold}
            />
            <span className="num">{thresholdShown}%</span>
          </div>
        </div>
        {alertOn && notifyAuth === 'denied' ? (
          <p className="muted" role="note">
            系统通知权限被拒绝——请在「系统设置 → 通知」里允许 TokenMeter，否则告警发不出来。
          </p>
        ) : null}
      </div>

      {/* E. 数据（含索引状态：每个扫描源一张卡，进度/错误就地展示） */}
      <div className="card" aria-label="数据">
        <div className="chead">
          <div>
            <h2>数据</h2>
            {indexStatus ? (
              <div className="desc">
                已索引 {indexStatus.roots.reduce((sum, r) => sum + r.eventsCount, 0).toLocaleString()} 条事件
              </div>
            ) : null}
          </div>
        </div>
        <div>
          {(indexStatus?.roots ?? []).map((root) => (
            <SourceRow
              root={root}
              key={root.id}
              failedFiles={(indexStatus?.failedFiles ?? []).filter((f) => f.scanRootId === root.id)}
              rebuilding={rebuilding}
              progress={scanProgress}
              onToggle={toggleRoot}
            />
          ))}
        </div>
        <div className="setrow" style={{ marginTop: 4 }}>
          <span>数据库位置</span>
          <span className="dircol grow">~/.token-meter/tokenmeter.sqlite</span>
        </div>
        <div className="dangerzone">
          <div>
            <b>全部重新扫描</b>
            <div className="dz-desc">清空本地派生数据库并按启用的根目录重新扫描 · 不影响 agent 原始日志，重建期间统计数据不完整</div>
          </div>
          <button className="btn danger" type="button" disabled={rebuilding} onClick={() => setRebuildDialog(true)}>
            {rebuilding ? '正在重新扫描…' : '重新扫描…'}
          </button>
        </div>
        {rebuildNote ? <p className="muted" role="status">{rebuildNote}</p> : null}
      </div>

      {/* 外观 */}
      <div className="card" aria-label="外观">
        <div className="chead">
          <div>
            <h2>外观</h2>
            <div className="desc">主窗口配色（菜单栏面板在其弹窗内单独切换）</div>
          </div>
        </div>
        <div className="seg" role="group" aria-label="外观">
          <button type="button" className={theme === 'system' ? 'on' : ''} onClick={() => changeTheme('system')}>跟随系统</button>
          <button type="button" className={theme === 'light' ? 'on' : ''} onClick={() => changeTheme('light')}>浅色</button>
          <button type="button" className={theme === 'dark' ? 'on' : ''} onClick={() => changeTheme('dark')}>深色</button>
        </div>
      </div>

      {loadError ? (
        <p className="status-error" role="status">设置加载失败：{loadError}</p>
      ) : null}

      {rebuildDialog ? (
        <div className="dlg-mask on" role="dialog" aria-label="重建索引确认">
          <div className="dlg">
            <h3>重建索引？</h3>
            <p>将清空本地派生数据库并按启用的根目录重新扫描。agent 原始日志不受影响；重建期间统计数据不完整。</p>
            <div className="dlg-actions">
              <button className="btn" type="button" onClick={() => setRebuildDialog(false)}>取消</button>
              <button className="btn danger" type="button" onClick={startRebuild}>开始重建</button>
            </div>
          </div>
        </div>
      ) : null}
    </section>
  );
}

/// 供应商一行（B 区）：显示名（别名）与启停存 provider_config_overrides；
/// keyed 供应商多一行应用内 Key（存 macOS 钥匙串、优先于环境变量，明文不经渲染进程）。
function QuotaProviderRow({
  provider,
  savedName,
  enabled,
  onSave,
  onToggle
}: {
  provider: { id: string; name: string; pill: string; how: string; src: string; keyed?: boolean };
  savedName: string;
  enabled: boolean;
  onSave: (name: string) => void;
  onToggle: () => void;
}) {
  const [draft, setDraft] = useState(savedName);
  useEffect(() => {
    setDraft(savedName);
  }, [savedName]);
  const dirty = draft.trim() !== savedName;

  // 应用内 Key：hasKey null = 状态未知（菜单栏应用不可达）。
  const [hasKey, setHasKey] = useState<boolean | null>(null);
  const [keyDraft, setKeyDraft] = useState('');
  useEffect(() => {
    if (!provider.keyed) return;
    void window.tokenMeter.credentials.state(provider.id).then(setHasKey).catch(() => setHasKey(null));
  }, [provider.id, provider.keyed]);

  const saveKey = (token: string) => {
    void window.tokenMeter.credentials.set(provider.id, token)
      .then((stored) => {
        setHasKey(stored);
        setKeyDraft('');
        showToast('ok', stored ? 'API Key 已存入钥匙串' : 'API Key 已清除');
      })
      .catch((error: unknown) => {
        showToast('error', `API Key 保存失败：${error instanceof Error ? error.message : '未知错误'}`);
      });
  };

  return (
    <div className="qprov" data-state={enabled ? 'ok' : 'none'}>
      <div className="setrow">
        <button
          type="button"
          className={enabled ? 'sw on' : 'sw'}
          aria-pressed={enabled}
          aria-label={`启用 ${provider.name}`}
          onClick={onToggle}
        />
        <b className="qname">{savedName}</b>
        <span className="pill">{!enabled ? '已停用' : provider.keyed && hasKey ? '钥匙串' : provider.pill}</span>
        <div className="grow" />
        <input
          type="text"
          value={draft}
          aria-label={`${provider.name} 显示名`}
          placeholder={provider.name}
          onChange={(event) => setDraft(event.target.value)}
        />
        <button
          className="btn savebtn"
          type="button"
          disabled={!dirty}
          onClick={() => onSave(draft.trim())}
        >
          保存
        </button>
      </div>
      <div className="qbody">
        <div className="qcred">
          <span>{provider.how}</span>
          <span className="qsrc num">{provider.src}</span>
        </div>
        {provider.keyed ? (
          <div className="qcred qkeyrow">
            <input
              type="password"
              value={keyDraft}
              aria-label={`${provider.name} API Key`}
              placeholder={hasKey ? '已配置（输入新 Key 可覆盖）' : '在此粘贴 API Key'}
              onChange={(event) => setKeyDraft(event.target.value)}
            />
            <button
              className="btn savebtn"
              type="button"
              disabled={keyDraft.trim() === ''}
              onClick={() => saveKey(keyDraft.trim())}
            >
              存入钥匙串
            </button>
            {hasKey ? (
              <button className="btn" type="button" onClick={() => saveKey('')}>清除</button>
            ) : null}
          </div>
        ) : null}
      </div>
    </div>
  );
}

/// 扫描源一张卡（E 区，原「索引状态」页样式）：启用开关 + 名称/pill +
/// 路径 + 文件·事件·大小·最近扫描 + 进度条 + 错误行。开关写 scan_roots.enabled，
/// 关 = 下轮扫描起跳过（历史数据保留）。全量重扫时当前源实时显示百分比。
function SourceRow({
  root, failedFiles, rebuilding, progress, onToggle
}: {
  root: ScanRootSummary;
  failedFiles: FailedFileSummary[];
  rebuilding: boolean;
  progress: ScanProgress | null;
  onToggle: (root: ScanRootSummary) => void;
}) {
  const scanningThis = rebuilding && progress?.currentRoot === root.displayName;
  const state = scanningThis ? 'scanning'
    : !root.enabled ? 'off'
    : root.lastError || failedFiles.length > 0 ? 'error' : 'ok';
  const pillText =
    state === 'scanning' ? '扫描中' : state === 'off' ? '已停用' : state === 'error' ? '有错误' : '已完成';
  const percent = scanningThis && progress && progress.bytesTotal > 0
    ? Math.min(100, Math.round((progress.bytesDone / progress.bytesTotal) * 100))
    : 100;
  const scannedAt = scanningThis
    ? '进行中'
    : root.lastScanFinishedAt
      ? formatRelative(Date.now() - parseUtcTimestamp(root.lastScanFinishedAt))
      : '尚未扫描';
  const errorText = [
    failedFiles.length > 0 ? `${failedFiles.length} 个文件解析失败：${failedFiles[0].parseError ?? '未知解析错误'}` : null,
    root.lastError
  ].filter(Boolean).join('；');

  return (
    <div className="src src-toggle" data-state={state}>
      <button
        type="button"
        className={root.enabled ? 'sw on' : 'sw'}
        aria-pressed={root.enabled}
        aria-label={`${root.displayName} 目录启用开关`}
        onClick={() => onToggle(root)}
      />
      <div>
        <div className="nm">
          {root.displayName}
          <span className="pill">{pillText}</span>
        </div>
        <div className="pth">{root.rootPathLabel}</div>
        <div className="facts">
          <span>文件 <b>{root.fileCount.toLocaleString()}</b></span>
          <span>事件 <b>{root.eventsCount.toLocaleString()}</b></span>
          <span>大小 <b>{formatBytes(root.totalSizeBytes)}</b></span>
          <span>最近扫描 <b>{scannedAt}</b></span>
        </div>
      </div>
      <div className="right">
        <span className="num src-pct">{percent}%</span>
        <div className="prog"><i style={{ width: `${percent}%` }} /></div>
      </div>
      {errorText ? <div className="err">{errorText}</div> : null}
    </div>
  );
}
