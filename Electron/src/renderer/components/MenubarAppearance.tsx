import { useState } from 'react';

import type { MenubarAppearance as MenubarAppearanceModel, MenubarStyleId, MenubarWindowChoice, SettingsPatch, SettingsSnapshot } from '../api.js';
import { settingsStore, useSettings } from '../stores/settingsStore.js';
import type { SettingsApplyRequest } from '../stores/settingsStore.js';
import { MenubarPreviewBar, PREVIEW_PROVIDERS, type MenubarPreviewState } from './MenubarPreview.js';
import { showToast } from './toast.js';

/// 设置下钻页「菜单栏外观」：实时预览 / 样式画廊 / 元素 / 今日用量 / 按服务商配置。
/// 元素锁定与切换副作用 = spec §3 表（Swift MenuBarQuotaModel.effectiveElements 同表，
/// 两端注释互指）。所有改动即时保存，Swift 端经 settingsChanged 即时重投影。

const STYLE_GROUPS: Array<{ title: string; items: Array<{ id: MenubarStyleId; name: string }> }> = [
  {
    title: '基础 · 每家一个 cell',
    items: [
      { id: 'rings', name: '同心双环' },
      { id: 'vbars', name: '双竖条' },
      { id: 'hbar', name: '迷你横条' },
      { id: 'digits', name: '纯数字' },
      { id: 'dots', name: '状态点' },
      { id: 'caps', name: '胶囊电池' },
      { id: 'ticks', name: '分段刻度' },
      { id: 'ring1', name: '单环' }
    ]
  },
  {
    title: '紧凑 · 图形支（聚合 / 按需）',
    items: [
      { id: 'grid', name: '点阵网格' },
      { id: 'sentinel', name: '哨兵' },
      { id: 'monogram', name: '字母色徽' },
      { id: 'strip', name: '堆叠条' }
    ]
  },
  {
    title: '紧凑 · 数字支（数字一个不少）',
    items: [
      { id: 'tagnum', name: '字标数字' },
      { id: 'deck2', name: '双层堆叠' }
    ]
  },
  {
    title: '混合系 · 图形 + 数字',
    items: [
      { id: 'ringdeck', name: '环+堆叠' },
      { id: 'barsdeck', name: '竖条+堆叠' }
    ]
  }
];

const STYLE_NAMES: Record<string, string> = Object.fromEntries(
  STYLE_GROUPS.flatMap((group) => group.items.map((item) => [item.id, item.name]))
);

export function currentStyleName(snapshot: SettingsSnapshot): string {
  return STYLE_NAMES[snapshot.menubarAppearance.style] ?? snapshot.menubarAppearance.style;
}

/// 菜单栏行清单：真实 providerId ↔ 预览 demo id（PREVIEW_PROVIDERS）。
/// 与 Settings.tsx 的 QUOTA_PROVIDERS 同名单（那份服务于额度接入卡，不复用避免循环 import）。
const MENUBAR_PROVIDERS: Array<{ id: string; name: string; demoId: string; short: string }> = [
  { id: 'claude-code', name: 'Claude Code', demoId: 'claude', short: 'CC' },
  { id: 'codex', name: 'Codex', demoId: 'codex', short: 'CX' },
  { id: 'zhipu', name: '智谱 GLM', demoId: 'zhipu', short: '智谱' }
];

/// settings → 预览状态：真实 override 映射到 demo 家；OMP 无真实映射，恒显示（演示密度）。
export function previewStateFromSettings(snapshot: SettingsSnapshot): MenubarPreviewState {
  const byDemoId = new Map(MENUBAR_PROVIDERS.map((p) => [p.demoId, p.id]));
  return {
    style: snapshot.menubarAppearance.style,
    showName: snapshot.menubarAppearance.showName,
    showGlyph: snapshot.menubarAppearance.showGlyph,
    showNumber: snapshot.menubarAppearance.showNumber,
    usage: snapshot.menubarAppearance.usage,
    windowOrder: snapshot.menubarAppearance.windowOrder,
    providers: PREVIEW_PROVIDERS.map((demo) => {
      const realId = byDemoId.get(demo.id);
      const override = realId === undefined
        ? undefined
        : snapshot.providerOverrides.find((o) => o.providerId === realId);
      return {
        id: demo.id,
        visible: override?.showInMenuBar ?? true,
        glyphWindow: override?.menubarGlyphWindow ?? 'both',
        numberWindow: override?.menubarNumberWindow ?? 'both'
      };
    })
  };
}

/// 样式切换副作用（稿 JS 画廊 click 规则；Swift 端由 effectiveElements 归一化兜底）。
export function stylePatch(style: MenubarStyleId, current: { showName: boolean; showNumber: boolean }): SettingsPatch {
  const patch: SettingsPatch = { menubarStyle: style };
  if (style === 'digits') {
    patch.menubarShowGlyph = false;
  } else if (style === 'monogram') {
    patch.menubarShowName = true;
    patch.menubarShowGlyph = false;
  } else if (style === 'tagnum' || style === 'deck2') {
    patch.menubarShowNumber = true;
    patch.menubarShowGlyph = false;
  } else if (style === 'ringdeck' || style === 'barsdeck') {
    patch.menubarShowNumber = true;
    patch.menubarShowGlyph = true;
  } else if (style === 'grid' || style === 'strip' || style === 'sentinel') {
    patch.menubarShowGlyph = true;
  } else if (!current.showName && !current.showNumber) {
    patch.menubarShowGlyph = true;
  }
  return patch;
}

/// 元素锁定表（spec §3）：锁定的开关禁用、显示值由样式钉死。
export function elementLocks(style: MenubarStyleId): { name?: boolean; glyph?: boolean; pct?: boolean } {
  if (style === 'digits') return { glyph: true };
  if (style === 'monogram') return { name: true, glyph: true };
  if (style === 'tagnum' || style === 'deck2') return { glyph: true, pct: true };
  if (style === 'ringdeck' || style === 'barsdeck') return { glyph: true, pct: true };
  if (style === 'grid' || style === 'strip' || style === 'sentinel') return { glyph: true };
  return {};
}

/// 元素开关的有效显示值（Swift MenuBarQuotaModel.effectiveElements 同表）。
function effectiveElements(appearance: MenubarAppearanceModel): { name: boolean; glyph: boolean; pct: boolean } {
  let name = appearance.showName;
  let glyph = appearance.showGlyph;
  let pct = appearance.showNumber;
  switch (appearance.style) {
    case 'digits':
      glyph = false;
      break;
    case 'monogram':
      name = true;
      glyph = false;
      break;
    case 'tagnum':
    case 'deck2':
      glyph = false;
      pct = true;
      break;
    case 'ringdeck':
    case 'barsdeck':
      glyph = true;
      pct = true;
      break;
    case 'grid':
    case 'strip':
    case 'sentinel':
      glyph = true;
      break;
    default:
      break;
  }
  if (!name && !glyph && !pct) {
    if (appearance.style === 'digits') pct = true;
    else glyph = true;
  }
  return { name, glyph, pct };
}

/// 画廊缩略：单家中性色示意（CSS .mbg-thumb 把填充统一成 currentColor）。
function StyleThumb({ style }: { style: MenubarStyleId }) {
  const arc = (r: number, pct: number, cx: number, cy: number, width: number) => {
    const length = 2 * Math.PI * r;
    return (
      <>
        <circle cx={cx} cy={cy} r={r} fill="none" stroke="color-mix(in srgb, currentColor 25%, transparent)" strokeWidth={width} />
        <circle
          cx={cx}
          cy={cy}
          r={r}
          fill="none"
          stroke="currentColor"
          strokeWidth={width}
          strokeDasharray={`${(length * pct) / 100} ${length}`}
          transform={`rotate(-90 ${cx} ${cy})`}
        />
      </>
    );
  };
  switch (style) {
    case 'rings':
    case 'ringdeck':
      return (
        <span style={{ display: 'inline-flex', alignItems: 'center', gap: 3 }}>
          <svg width={17} height={17} viewBox="0 0 17 17">
            {arc(7, 62, 8.5, 8.5, 1.8)}
            {arc(4, 41, 8.5, 8.5, 1.8)}
          </svg>
          {style === 'ringdeck' ? (
            <span className="mb-deck2">
              <span className="u"><b>CC</b><span className="pct">62</span></span>
            </span>
          ) : null}
        </span>
      );
    case 'ring1':
      return (
        <svg width={15} height={15} viewBox="0 0 15 15">{arc(6, 62, 7.5, 7.5, 2)}</svg>
      );
    case 'vbars':
    case 'barsdeck':
      return (
        <span style={{ display: 'inline-flex', alignItems: 'center', gap: 3 }}>
          <span className="mb-vbars">
            <span className="tr"><i style={{ height: '62%' }} /></span>
            <span className="tr"><i style={{ height: '41%' }} /></span>
          </span>
          {style === 'barsdeck' ? (
            <span className="mb-deck2">
              <span className="u"><b>CC</b><span className="pct">62</span></span>
            </span>
          ) : null}
        </span>
      );
    case 'hbar':
      return (
        <span className="mb-hbar">
          <span className="tr"><i style={{ width: '62%' }} /></span>
          <span className="tr"><i style={{ width: '41%' }} /></span>
        </span>
      );
    case 'digits':
      return <span className="pct">62<i style={{ fontStyle: 'normal', opacity: 0.45 }}>·</i>41</span>;
    case 'dots':
      return (
        <span className="mb-dots"><i /><i /></span>
      );
    case 'caps':
      return (
        <span className="mb-caps">
          <span className="c"><i style={{ width: '62%' }} /></span>
          <span className="c"><i style={{ width: '41%' }} /></span>
        </span>
      );
    case 'ticks':
      return (
        <span className="mb-ticks"><i className="f" /><i className="f" /><i className="f" /><i /><i /></span>
      );
    case 'grid':
      return (
        <span className="mb-grid4" style={{ gridTemplateColumns: 'repeat(2, 5.5px)' }}><i /><i /><i /><i /></span>
      );
    case 'strip':
      return (
        <span className="mb-strip"><i /><i /><i /><i /></span>
      );
    case 'monogram':
      return (
        <span className="mb-monogram"><b>C</b><b>X</b><b>智</b></span>
      );
    case 'sentinel':
      return (
        <span className="mb-logo">
          <svg width={13} height={13} viewBox="0 0 22 22" fill="none">
            <rect x={1} y={1} width={20} height={20} rx={5} stroke="currentColor" strokeWidth={2} />
            <path d="M6 13.5 9 8.5l2.6 3.6L14 6.5l2 7" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" />
          </svg>
        </span>
      );
    case 'tagnum':
      return (
        <span className="mb-tagnum">
          <span className="u"><b>C</b><span className="pct">62</span></span>
          <span className="u"><b>X</b><span className="pct">34</span></span>
        </span>
      );
    case 'deck2':
      return (
        <span className="mb-deck2">
          <span className="u"><b>CC</b><span className="pct">62</span></span>
          <span className="u"><b>CX</b><span className="pct">34</span></span>
        </span>
      );
    default:
      return null;
  }
}

export function MenubarAppearance({ onBack }: { onBack: () => void }) {
  const settings = useSettings();
  const appearance = settings.menubarAppearance;
  const [savedTick, setSavedTick] = useState(false);

  const apply = (patch: SettingsPatch) => {
    void settingsStore.applyPatch(patch).then((result: SettingsApplyRequest) => {
      if (result.status === 'failed') {
        showToast('error', `设置保存失败：${result.error?.message ?? '未知设置错误'}`);
        return;
      }
      setSavedTick(true);
      window.setTimeout(() => setSavedTick(false), 2000);
    }).catch((error: unknown) => {
      showToast('error', `设置保存失败：${error instanceof Error ? error.message : '未知设置错误'}`);
    });
  };

  const locks = elementLocks(appearance.style);
  const effective = effectiveElements(appearance);
  const onCount = Number(effective.name) + Number(effective.glyph) + Number(effective.pct);

  const keepMsg = (() => {
    if (onCount === 1) return '至少保留一个元素';
    if (appearance.style === 'tagnum' || appearance.style === 'deck2') return '数字支：数字为本体，名称可关为裸数字位序';
    if (appearance.style === 'ringdeck' || appearance.style === 'barsdeck') return '混合系：图形与数字均为本体，名称可关';
    if (appearance.style === 'grid' || appearance.style === 'strip' || appearance.style === 'sentinel') return '紧凑样式：名称开关 = logo 前缀';
    return '';
  })();

  /// 窗口 seg 禁用联动：图形列在（样式无图形 或 图形关且非混合系）时禁用；
  /// 数字列在（数字关 且非数字支/混合系）时禁用。
  const noGlyphStyle = ['digits', 'monogram', 'tagnum', 'deck2'].includes(appearance.style);
  const hybrid = appearance.style === 'ringdeck' || appearance.style === 'barsdeck';
  const digitBranch = appearance.style === 'tagnum' || appearance.style === 'deck2';
  const glyphSegDisabled = noGlyphStyle || (!effective.glyph && !hybrid);
  const numberSegDisabled = !effective.pct && !digitBranch && !hybrid;

  const elementRow = (key: 'name' | 'glyph' | 'pct', label: string, patchKey: keyof SettingsPatch) => {
    const on = effective[key];
    const locked = locks[key] === true;
    const disabled = locked || (on && onCount === 1);
    return (
      <div className="setrow">
        <button
          type="button"
          className={on ? 'sw on' : 'sw'}
          aria-pressed={on}
          aria-label={label}
          disabled={disabled}
          onClick={() => apply({ [patchKey]: !on } as SettingsPatch)}
        />
        <span>{label}</span>
      </div>
    );
  };

  const windowSeg = (
    provider: { id: string },
    column: 'glyph' | 'number',
    disabled: boolean
  ) => {
    const override = settings.providerOverrides.find((o) => o.providerId === provider.id);
    const value = (column === 'glyph' ? override?.menubarGlyphWindow : override?.menubarNumberWindow) ?? 'both';
    const patchKey = column === 'glyph' ? 'providerGlyphWindow' : 'providerNumberWindow';
    const options: Array<{ v: MenubarWindowChoice; label: string }> = [
      { v: 'short', label: '5h' },
      { v: 'long', label: '7d' },
      { v: 'both', label: '双' }
    ];
    return (
      <div className={disabled ? 'seg mini dis' : 'seg mini'} role="group">
        {options.map((option) => (
          <button
            key={option.v}
            type="button"
            className={value === option.v ? 'on' : ''}
            aria-pressed={value === option.v}
            onClick={() => apply({ [patchKey]: { [provider.id]: option.v } } as SettingsPatch)}
          >
            {option.label}
          </button>
        ))}
      </div>
    );
  };

  const previewState = previewStateFromSettings(settings);

  return (
    <section className="view">
      <div className="vhead">
        <button className="backbtn" type="button" onClick={onBack}>← 设置</button>
        <h1>菜单栏外观</h1>
        <span className={savedTick ? 'savetick show' : 'savetick'}>已保存 ✓</span>
      </div>

      <div className="card" aria-label="实时预览">
        <div className="chead">
          <div>
            <h2>实时预览</h2>
            <div className="desc">深色 / 浅色菜单栏双底 · 演示口径数据 · 随下方全部设置即时联动</div>
          </div>
        </div>
        <div className="mbprev">
          <MenubarPreviewBar mode="dark" state={previewState} />
          <MenubarPreviewBar mode="light" state={previewState} />
        </div>
      </div>

      <div className="card" aria-label="样式">
        <div className="chead">
          <div>
            <h2>样式</h2>
            <div className="desc">16 种可切换样式 · 按族分组，宽度与信息量取舍见样式族设计稿</div>
          </div>
        </div>
        <div className="mbgal">
          {STYLE_GROUPS.map((group) => (
            <StyleGroup
              key={group.title}
              group={group}
              activeStyle={appearance.style}
              onPick={(style) => apply(stylePatch(style, { showName: appearance.showName, showNumber: appearance.showNumber }))}
            />
          ))}
        </div>
      </div>

      <div className="detail-grid">
        <div className="card" aria-label="元素">
          <div className="chead">
            <div>
              <h2>元素</h2>
              <div className="desc">至少保留一个 · 部分样式会锁定本体元素</div>
            </div>
          </div>
          {elementRow('name', '品牌短名', 'menubarShowName')}
          {elementRow('glyph', '图形', 'menubarShowGlyph')}
          {elementRow('pct', '剩余百分比数字', 'menubarShowNumber')}
          {keepMsg !== '' ? <div className="mbkeep">{keepMsg}</div> : null}
          <div className="setrow" style={{ marginTop: 6 }}>
            <span>双窗口顺序</span>
            <div className="grow" />
            <div className="seg" role="group" aria-label="双窗口顺序">
              <button
                type="button"
                className={appearance.windowOrder === 'longFirst' ? 'on' : ''}
                aria-pressed={appearance.windowOrder === 'longFirst'}
                onClick={() => apply({ menubarWindowOrder: 'longFirst' })}
              >
                7d 在前
              </button>
              <button
                type="button"
                className={appearance.windowOrder === 'shortFirst' ? 'on' : ''}
                aria-pressed={appearance.windowOrder === 'shortFirst'}
                onClick={() => apply({ menubarWindowOrder: 'shortFirst' })}
              >
                5h 在前
              </button>
            </div>
          </div>
        </div>

        <div className="card" aria-label="今日用量">
          <div className="chead">
            <div>
              <h2>今日用量</h2>
              <div className="desc">组件级尾巴 cell · 排在本组最右</div>
            </div>
          </div>
          <div className="setrow">
            <span>显示内容</span>
            <div className="grow" />
            <div className="seg" role="group" aria-label="今日用量">
              <button
                type="button"
                className={appearance.usage === 'off' ? 'on' : ''}
                aria-pressed={appearance.usage === 'off'}
                onClick={() => apply({ menubarUsage: 'off' })}
              >
                关闭
              </button>
              <button
                type="button"
                className={appearance.usage === 'tok' ? 'on' : ''}
                aria-pressed={appearance.usage === 'tok'}
                onClick={() => apply({ menubarUsage: 'tok' })}
              >
                Token
              </button>
              <button
                type="button"
                className={appearance.usage === 'cost' ? 'on' : ''}
                aria-pressed={appearance.usage === 'cost'}
                onClick={() => apply({ menubarUsage: 'cost' })}
              >
                花费
              </button>
            </div>
          </div>
        </div>
      </div>

      <div className="card" aria-label="按服务商配置">
        <div className="chead">
          <div>
            <h2>按服务商配置</h2>
            <div className="desc">
              开关只控制菜单栏排布（数据接入启停在设置 · 供应商额度接入）；图形与数字的窗口各自独立，
              任意交叉都成立；单窗口服务商任选均显示其唯一窗口
            </div>
          </div>
        </div>
        <div style={{ overflowX: 'auto' }}>
          <table style={{ minWidth: 560 }}>
            <thead>
              <tr><th>服务商</th><th>菜单栏显示</th><th>图形窗口</th><th>数字窗口</th></tr>
            </thead>
            <tbody>
              {MENUBAR_PROVIDERS.map((provider) => {
                const override = settings.providerOverrides.find((o) => o.providerId === provider.id);
                const visible = override?.showInMenuBar ?? true;
                return (
                  <tr key={provider.id}>
                    <td><b>{provider.name}</b> <span className="mbkeep">{provider.short}</span></td>
                    <td>
                      <button
                        type="button"
                        className={visible ? 'sw on' : 'sw'}
                        aria-pressed={visible}
                        aria-label={`${provider.name} 菜单栏显示`}
                        onClick={() => apply({ providerMenubarVisible: { [provider.id]: !visible } })}
                      />
                    </td>
                    <td>{windowSeg(provider, 'glyph', glyphSegDisabled)}</td>
                    <td>{windowSeg(provider, 'number', numberSegDisabled)}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </div>
    </section>
  );
}

function StyleGroup({
  group,
  activeStyle,
  onPick
}: {
  group: { title: string; items: Array<{ id: MenubarStyleId; name: string }> };
  activeStyle: MenubarStyleId;
  onPick: (style: MenubarStyleId) => void;
}) {
  return (
    <>
      <div className="mbgal-h">{group.title}</div>
      {group.items.map((item) => (
        <button
          key={item.id}
          type="button"
          className={activeStyle === item.id ? 'mbg on' : 'mbg'}
          aria-pressed={activeStyle === item.id}
          onClick={() => onPick(item.id)}
        >
          <span className="mbg-thumb"><StyleThumb style={item.id} /></span>
          <span className="mbg-name">{item.name}</span>
        </button>
      ))}
    </>
  );
}
