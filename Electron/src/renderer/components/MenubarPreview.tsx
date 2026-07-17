import { Fragment } from 'react';

import type { MenubarStyleId, MenubarUsageTail, MenubarWindowChoice, MenubarWindowOrder } from '../api.js';

/// 菜单栏预览渲染器：演示口径数据（与 OpenDesign 稿同源），不接真实快照。
/// 规则权威 = spec §2-3；Swift MenuBarStyleViews 是真渲染，此处视觉近似一致：
/// 双数字各自染窗口警戒色、双窗数字仅 rings/vbars/digits、ticks 双组静音、
/// digits 的 CJK 超宽降级、聚合家级最险（grid/strip 取图形窗、monogram/sentinel 取数字窗）。
/// cell 内只用系统语义色（.mbar 的 g-* 类），品牌青禁入。

export interface MenubarPreviewState {
  style: MenubarStyleId;
  showName: boolean;
  showGlyph: boolean;
  showNumber: boolean;
  usage: MenubarUsageTail;
  windowOrder: MenubarWindowOrder;
  providers: Array<{
    id: string;
    visible: boolean;
    glyphWindow: MenubarWindowChoice;
    numberWindow: MenubarWindowChoice;
  }>;
}

interface DemoWindow {
  p: number;
  c: 'ok' | 'warn' | 'bad';
}

interface DemoProvider {
  id: string;
  short: string;
  mono: string;
  w5: DemoWindow;
  /// null = 单窗家（唯一窗放 w5 之外的语义由 pick 处理；演示数据全双窗，真实端才有单窗）。
  w7: DemoWindow | null;
  stale: boolean;
}

/// 演示数据（稿 data 口径）：CC 5h62/7d41 · CX 34/18 · 智谱 8/55 · OMP 过期 12m。
export const PREVIEW_PROVIDERS: DemoProvider[] = [
  { id: 'claude', short: 'CC', mono: 'C', w5: { p: 62, c: 'ok' }, w7: { p: 41, c: 'ok' }, stale: false },
  { id: 'codex', short: 'CX', mono: 'X', w5: { p: 34, c: 'warn' }, w7: { p: 18, c: 'warn' }, stale: false },
  { id: 'zhipu', short: '智谱', mono: '智', w5: { p: 8, c: 'bad' }, w7: { p: 55, c: 'ok' }, stale: false },
  { id: 'omp', short: 'OMP', mono: 'O', w5: { p: 71, c: 'ok' }, w7: { p: 30, c: 'ok' }, stale: true }
];

const COL = {
  dark: { ok: '#30d158', warn: '#ffd60a', bad: '#ff453a', off: 'rgba(255,255,255,.38)', tr: 'rgba(255,255,255,.16)' },
  light: { ok: '#1d9a46', warn: '#b48b00', bad: '#d70015', off: 'rgba(0,0,0,.32)', tr: 'rgba(0,0,0,.12)' }
} as const;

const COMPACT: Record<string, true> = { grid: true, sentinel: true, monogram: true, strip: true, tagnum: true, deck2: true };

function pick(d: DemoProvider, w: MenubarWindowChoice, order: MenubarWindowOrder): DemoWindow[] {
  if (d.w7 === null) return [d.w5];
  if (w === 'short') return [d.w5];
  if (w === 'long') return [d.w7];
  return order === 'shortFirst' ? [d.w5, d.w7] : [d.w7, d.w5];
}

function worstOf(ws: DemoWindow[]): DemoWindow {
  return ws.reduce((a, b) => (b.p < a.p ? b : a));
}

function hasCJK(text: string): boolean {
  return /[一-鿿]/.test(text);
}

interface CellContext {
  state: MenubarPreviewState;
  mode: 'dark' | 'light';
}

function providerConfig(state: MenubarPreviewState, id: string) {
  return state.providers.find((p) => p.id === id);
}

function gwins(ctx: CellContext, d: DemoProvider): DemoWindow[] {
  return pick(d, providerConfig(ctx.state, d.id)?.glyphWindow ?? 'both', ctx.state.windowOrder);
}

function nwins(ctx: CellContext, d: DemoProvider): DemoWindow[] {
  return pick(d, providerConfig(ctx.state, d.id)?.numberWindow ?? 'both', ctx.state.windowOrder);
}

/// 数字组：stale → "—"；双数字各自染所属窗口色（与 Swift CellNumbersView 同裁定）。
function Numbers({ d, ws }: { d: DemoProvider; ws: DemoWindow[] }) {
  if (d.stale) return <span className="pct">—</span>;
  return (
    <span className="pct">
      {ws.map((w, index) => (
        <Fragment key={index}>
          {index > 0 ? <i>·</i> : null}
          <span className={`g-${w.c}`}>{w.p}</span>
        </Fragment>
      ))}
    </span>
  );
}

function ringArc(cx: number, cy: number, r: number, pct: number, color: string, track: string, width: number) {
  const length = 2 * Math.PI * r;
  return (
    <>
      <circle cx={cx} cy={cy} r={r} fill="none" stroke={track} strokeWidth={width} />
      {pct > 0 ? (
        <circle
          cx={cx}
          cy={cy}
          r={r}
          fill="none"
          stroke={color}
          strokeWidth={width}
          strokeDasharray={`${(length * pct) / 100} ${length}`}
          transform={`rotate(-90 ${cx} ${cy})`}
        />
      ) : null}
    </>
  );
}

function windowColor(ctx: CellContext, d: DemoProvider, w: DemoWindow): string {
  const pal = COL[ctx.mode];
  return d.stale ? pal.off : pal[w.c];
}

/// 单家图形（基础族 + 混合系借用）。
function Glyph({ ctx, d }: { ctx: CellContext; d: DemoProvider }) {
  const ws = gwins(ctx, d);
  const pal = COL[ctx.mode];
  let style: string = ctx.state.style;
  if (style === 'ringdeck') style = ws.length > 1 ? 'rings' : 'ring1';
  if (style === 'barsdeck') style = 'vbars';

  if (style === 'rings') {
    return (
      <span className="mbglyph">
        <svg width={17} height={17} viewBox="0 0 17 17">
          {ringArc(8.5, 8.5, 7, ws[0].p, windowColor(ctx, d, ws[0]), pal.tr, 1.8)}
          {ws.length > 1 ? ringArc(8.5, 8.5, 4, ws[1].p, windowColor(ctx, d, ws[1]), pal.tr, 1.8) : null}
        </svg>
      </span>
    );
  }
  if (style === 'ring1') {
    const w = ws[0];
    return (
      <span className="mbglyph">
        <svg width={15} height={15} viewBox="0 0 15 15">
          {ringArc(7.5, 7.5, 6, w.p, windowColor(ctx, d, w), pal.tr, 2)}
        </svg>
      </span>
    );
  }
  if (style === 'vbars') {
    return (
      <span className="mb-vbars">
        {ws.map((w, index) => (
          <span className="tr" key={index}>
            <i className={d.stale ? 'g-off' : `g-${w.c}`} style={{ height: `${w.p}%`, opacity: d.stale ? 0.5 : 1 }} />
          </span>
        ))}
      </span>
    );
  }
  if (style === 'hbar') {
    return (
      <span className="mb-hbar">
        {ws.map((w, index) => (
          <span className="tr" key={index} style={ws.length === 1 ? { height: 4 } : undefined}>
            <i className={d.stale ? 'g-off' : `g-${w.c}`} style={{ width: `${w.p}%`, opacity: d.stale ? 0.5 : 1 }} />
          </span>
        ))}
      </span>
    );
  }
  if (style === 'dots') {
    return (
      <span className="mb-dots">
        {ws.map((w, index) => (
          <i className={d.stale ? 'g-off' : `g-${w.c}`} key={index} />
        ))}
      </span>
    );
  }
  if (style === 'caps') {
    return (
      <span className="mb-caps">
        {ws.map((w, index) => (
          <span className="c" key={index}>
            <i className={d.stale ? 'g-off' : `g-${w.c}`} style={{ width: `${w.p}%`, opacity: d.stale ? 0.5 : 1 }} />
          </span>
        ))}
      </span>
    );
  }
  if (style === 'ticks') {
    return (
      <span style={{ display: 'inline-flex', gap: 4 }}>
        {ws.map((w, wi) => {
          const lit = Math.max(1, Math.round(w.p / 20));
          return (
            <span className="mb-ticks" key={wi}>
              {Array.from({ length: 5 }, (_, i) => (
                <i className={i < lit ? `f ${d.stale ? 'g-off' : `g-${w.c}`}` : ''} key={i} />
              ))}
            </span>
          );
        })}
      </span>
    );
  }
  return null;
}

const LOGO = (
  <span className="mb-logo">
    <svg width={13} height={13} viewBox="0 0 22 22" fill="none">
      <rect x={1} y={1} width={20} height={20} rx={5} stroke="currentColor" strokeWidth={2} />
      <path
        d="M6 13.5 9 8.5l2.6 3.6L14 6.5l2 7"
        stroke="currentColor"
        strokeWidth={2}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  </span>
);

/// 基础族 + 混合系的单家 cell。
function ProviderCell({ ctx, d }: { ctx: CellContext; d: DemoProvider }) {
  const { state } = ctx;
  const style = state.style;
  const hybrid = style === 'ringdeck' || style === 'barsdeck';

  if (hybrid) {
    const ws = nwins(ctx, d);
    return (
      <span className={`mbcell${d.stale ? ' g-off' : ''}`}>
        <Glyph ctx={ctx} d={d} />
        <span className="mb-deck2">
          <span className="u">
            {state.showName ? <b>{d.short}</b> : null}
            <Numbers d={d} ws={ws} />
          </span>
        </span>
      </span>
    );
  }

  const glyphVisible = state.showGlyph && style !== 'digits';
  const glyphWs = gwins(ctx, d);
  let numberVisible = state.showNumber;
  // ticks 双组刻度时数字自动隐藏（稿定）。
  if (style === 'ticks' && glyphVisible && glyphWs.length > 1) numberVisible = false;

  let numberWs = nwins(ctx, d);
  const dualAllowed = style === 'rings' || style === 'vbars' || style === 'digits';
  if (numberWs.length > 1 && !dualAllowed) numberWs = [worstOf(numberWs)];
  // digits 的 CJK 超宽降级：名称开 + 中文短名 + 双窗数字 → 最险单窗。
  if (style === 'digits' && numberWs.length > 1 && state.showName && hasCJK(d.short)) {
    numberWs = [worstOf(numberWs)];
  }

  return (
    <span className={`mbcell${d.stale ? ' g-off' : ''}`}>
      {state.showName ? <span className="nm">{d.short}</span> : null}
      {glyphVisible ? <Glyph ctx={ctx} d={d} /> : null}
      {numberVisible ? <Numbers d={d} ws={numberWs} /> : null}
    </span>
  );
}

/// 聚合紧凑族（grid/strip/monogram/sentinel）与数字支（tagnum/deck2）：全家一个 cell。
function CompactCell({ ctx, providers }: { ctx: CellContext; providers: DemoProvider[] }) {
  const { state } = ctx;
  const style = state.style;
  const worstNumber = (d: DemoProvider) => worstOf(nwins(ctx, d));
  const fresh = providers.filter((d) => !d.stale);
  const worstEntry = fresh.length > 0
    ? fresh.map((d) => ({ d, w: worstNumber(d) })).reduce((a, b) => (b.w.p < a.w.p ? b : a))
    : null;
  const aggregateNumber =
    state.showNumber && worstEntry !== null ? <Numbers d={worstEntry.d} ws={[worstEntry.w]} /> : null;

  if (style === 'grid') {
    const cols = providers.length === 4 ? 2 : Math.max(1, Math.min(providers.length, 3));
    return (
      <span className="mbcell">
        {state.showName ? LOGO : null}
        <span className="mb-grid4" style={{ gridTemplateColumns: `repeat(${cols}, 5.5px)` }}>
          {providers.map((d) => (
            <i className={d.stale ? 'g-off' : `g-${worstOf(gwins(ctx, d)).c}`} key={d.id} />
          ))}
        </span>
        {aggregateNumber}
      </span>
    );
  }
  if (style === 'strip') {
    return (
      <span className="mbcell">
        {state.showName ? LOGO : null}
        <span className="mb-strip">
          {providers.map((d) => (
            <i
              className={d.stale ? 'g-off' : `g-${worstOf(gwins(ctx, d)).c}`}
              style={d.stale ? { opacity: 0.55 } : undefined}
              key={d.id}
            />
          ))}
        </span>
        {aggregateNumber}
      </span>
    );
  }
  if (style === 'monogram') {
    return (
      <span className="mbcell">
        <span className="mb-monogram">
          {providers.map((d) => (
            <b className={`${d.stale ? 'g-off mb-stale' : `g-${worstNumber(d).c}`}`} key={d.id}>
              {d.mono}
            </b>
          ))}
        </span>
        {aggregateNumber}
      </span>
    );
  }
  if (style === 'sentinel') {
    const alerting = worstEntry !== null && (worstEntry.w.c === 'bad' || worstEntry.w.c === 'warn');
    if (alerting && worstEntry !== null) {
      const cls = `g-${worstEntry.w.c}`;
      return (
        <span className="mbcell">
          {state.showGlyph ? <span className={cls}>{LOGO}</span> : null}
          {state.showName ? <span className={`nm ${cls}`}>{worstEntry.d.short}</span> : null}
          {state.showNumber ? <Numbers d={worstEntry.d} ws={[worstEntry.w]} /> : null}
        </span>
      );
    }
    if (providers.some((d) => d.stale)) {
      return (
        <span className="mbcell g-off">
          {LOGO}
          <span className="pct">12m</span>
        </span>
      );
    }
    return <span className="mbcell">{LOGO}</span>;
  }
  // 数字支：tagnum / deck2 —— 数字为本体，每家按自己的窗口配置出数字。
  const cls = style === 'tagnum' ? 'mb-tagnum' : 'mb-deck2';
  return (
    <span className="mbcell">
      <span className={cls}>
        {providers.map((d) => (
          <span className={`u${d.stale ? ' g-off' : ''}`} key={d.id}>
            {state.showName ? <b>{style === 'tagnum' ? d.mono : d.short}</b> : null}
            <Numbers d={d} ws={nwins(ctx, d)} />
          </span>
        ))}
      </span>
    </span>
  );
}

export function MenubarPreviewBar({ mode, state }: { mode: 'dark' | 'light'; state: MenubarPreviewState }) {
  const ctx: CellContext = { state, mode };
  const visible = PREVIEW_PROVIDERS.filter((d) => providerConfig(state, d.id)?.visible ?? true);

  const cells = COMPACT[state.style]
    ? visible.length > 0
      ? [<CompactCell ctx={ctx} providers={visible} key="compact" />]
      : []
    : visible.map((d) => <ProviderCell ctx={ctx} d={d} key={d.id} />);

  const tail =
    state.usage !== 'off' ? (
      <span className="mbcell" key="tail">
        <span className="pct nm">{state.usage === 'tok' ? '214.8M' : '$196.44'}</span>
      </span>
    ) : null;

  const empty = cells.length === 0 && tail === null;

  return (
    <div className={`mbar ${mode === 'dark' ? 'mbdark' : 'mblight'}`}>
      {cells}
      {tail}
      {empty ? (
        <span className="mbcell">
          <span className="pct" style={{ opacity: 0.5 }}>
            全部隐藏
          </span>
        </span>
      ) : null}
    </div>
  );
}
