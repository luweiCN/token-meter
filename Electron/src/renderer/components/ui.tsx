import { useEffect, useRef, useState, type ButtonHTMLAttributes, type ReactNode } from 'react';

/// 项目统一基础组件(设计稿 components.html,类名与稿同名)。
/// 原生 <select>/<input type=time> 的系统控件跟不上设计语言,全部自绘;
/// 交互规范(loading 不变尺寸、日历两击自动交换、快捷项与手动互斥等)以稿为准。

export interface SelectOption<T extends string | number> {
  value: T;
  label: string;
}

/// 触发按钮内的清除小图标(×)。按钮里不能再嵌 button,用 span[role=button],
/// 点击只清值、不开合浮层。
function ClearIcon({ label, onClear }: { label: string; onClear: () => void }) {
  return (
    <span
      role="button"
      tabIndex={0}
      className="ui-clear"
      aria-label={label}
      onClick={(e) => { e.stopPropagation(); onClear(); }}
      onKeyDown={(e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.stopPropagation();
          e.preventDefault();
          onClear();
        }
      }}
    >
      <svg width="8" height="8" viewBox="0 0 8 8" fill="none" aria-hidden="true">
        <path d="m1.5 1.5 5 5m0-5-5 5" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
      </svg>
    </span>
  );
}

function Chevron() {
  return (
    <svg width="10" height="10" viewBox="0 0 10 10" fill="none" aria-hidden="true">
      <path d="m2 3.5 3 3 3-3" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

function CheckMark({ width = 10 }: { width?: number }) {
  return (
    <svg width={width} height={width} viewBox="0 0 10 10" fill="none" aria-hidden="true">
      <path d="m1.5 5.5 2.5 2.5L8.5 2" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

/// 点外/Esc 关闭浮层的公共钩子。
function useDismiss(open: boolean, rootRef: { current: HTMLElement | null }, close: () => void) {
  useEffect(() => {
    if (!open) return;
    const onDocClick = (e: MouseEvent) => {
      if (rootRef.current && !rootRef.current.contains(e.target as Node)) close();
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') close();
    };
    document.addEventListener('mousedown', onDocClick);
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('mousedown', onDocClick);
      document.removeEventListener('keydown', onKey);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open]);
}

// ── A · Button ──────────────────────────────────────────────────────────

export type ButtonVariant = 'primary' | 'secondary' | 'ghost' | 'danger' | 'dangerSolid';

/// 设计稿铁律:loading 只把内容换成 spinner(文字透明保位+绝对居中),
/// 盒尺寸绝不改变;primary 每屏至多一处。
export function Button({
  variant = 'secondary',
  size = 'sm',
  loading = false,
  className,
  children,
  disabled,
  ...rest
}: {
  variant?: ButtonVariant;
  size?: 'sm' | 'md';
  loading?: boolean;
} & ButtonHTMLAttributes<HTMLButtonElement>) {
  const variantClass = {
    primary: ' primary',
    secondary: '',
    ghost: ' ghost',
    danger: ' danger',
    dangerSolid: ' danger solid'
  }[variant];
  return (
    <button
      type="button"
      className={`btn${variantClass}${size === 'md' ? ' md' : ''}${loading ? ' is-loading' : ''}${className ? ` ${className}` : ''}`}
      disabled={disabled || loading}
      {...rest}
    >
      {children}
    </button>
  );
}

// ── C · TimeField ───────────────────────────────────────────────────────

const pad2 = (n: number) => String(n).padStart(2, '0');

/// 分段式 HH:MM 输入(替代原生 --:--)。键入两位自动跳下段;↑↓ 步进;
/// 失焦补零规范化(8 → 08)后才上报 onChange。
export function TimeField({
  value,
  onChange,
  disabled = false,
  error = false,
  ariaLabel
}: {
  /// 'HH:mm'。
  value: string;
  onChange: (next: string) => void;
  disabled?: boolean;
  error?: boolean;
  ariaLabel?: string;
}) {
  const [h = '00', m = '00'] = value.split(':');
  const [draft, setDraft] = useState({ h, m });
  const minuteRef = useRef<HTMLInputElement | null>(null);

  useEffect(() => {
    setDraft({ h, m });
  }, [h, m]);

  const commit = (next: { h: string; m: string }) => {
    const hour = Math.min(23, Math.max(0, parseInt(next.h || '0', 10) || 0));
    const minute = Math.min(59, Math.max(0, parseInt(next.m || '0', 10) || 0));
    const normalized = `${pad2(hour)}:${pad2(minute)}`;
    setDraft({ h: pad2(hour), m: pad2(minute) });
    if (normalized !== value) onChange(normalized);
  };

  const step = (seg: 'h' | 'm', delta: number) => {
    const max = seg === 'h' ? 23 : 59;
    const current = parseInt(draft[seg] || '0', 10) || 0;
    const next = current + delta > max ? 0 : current + delta < 0 ? max : current + delta;
    commit({ ...draft, [seg]: String(next) });
  };

  const segInput = (seg: 'h' | 'm') => (
    <input
      ref={seg === 'm' ? minuteRef : undefined}
      type="text"
      inputMode="numeric"
      maxLength={2}
      value={draft[seg]}
      aria-label={`${ariaLabel ?? '时刻'}·${seg === 'h' ? '时' : '分'}`}
      disabled={disabled}
      onFocus={(e) => e.target.select()}
      onChange={(e) => {
        const digits = e.target.value.replace(/\D/g, '').slice(0, 2);
        setDraft((d) => ({ ...d, [seg]: digits }));
        if (digits.length === 2 && seg === 'h') minuteRef.current?.focus();
      }}
      onKeyDown={(e) => {
        if (e.key === 'ArrowUp') { e.preventDefault(); step(seg, 1); }
        else if (e.key === 'ArrowDown') { e.preventDefault(); step(seg, -1); }
      }}
      onBlur={() => commit(draft)}
    />
  );

  return (
    <div className={`tf${disabled ? ' dis' : ''}${error ? ' err' : ''}`}>
      {segInput('h')}
      <span className="colon">:</span>
      {segInput('m')}
    </div>
  );
}

// ── D · Select ──────────────────────────────────────────────────────────

/// 自定义下拉:点击开合、点外/Esc 关闭。选中项 accent 勾 + 加重。
export function Select<T extends string | number>({
  value,
  options,
  onChange,
  ariaLabel,
  placeholder = '请选择'
}: {
  value: T | null;
  options: Array<SelectOption<T>>;
  onChange: (value: T | null) => void;
  ariaLabel: string;
  /// 顶部固定一项「全部/清除」语义的空选项文案;传 null 则不渲染空选项。
  placeholder?: string | null;
}) {
  const [open, setOpen] = useState(false);
  const rootRef = useRef<HTMLDivElement | null>(null);
  useDismiss(open, rootRef, () => setOpen(false));

  const current = options.find((o) => o.value === value);

  const pick = (next: T | null) => {
    setOpen(false);
    if (next !== value) onChange(next);
  };

  const option = (label: string, selected: boolean, onPick: () => void, key: string) => (
    <button
      key={key}
      type="button"
      role="option"
      aria-selected={selected}
      className={`sel-opt${selected ? ' on' : ''}`}
      onClick={onPick}
    >
      <span className="ck"><CheckMark /></span>
      {label}
    </button>
  );

  return (
    <div className={`sel${open ? ' open' : ''}`} ref={rootRef}>
      <button
        type="button"
        className="sel-btn"
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-label={ariaLabel}
        onClick={() => setOpen((o) => !o)}
      >
        <span className={current ? 'val' : ''}>{current?.label ?? placeholder ?? ''}</span>
        <Chevron />
      </button>
      {open ? (
        <div className="sel-pop" role="listbox" aria-label={ariaLabel} style={{ display: 'block' }}>
          {placeholder !== null ? option(placeholder, value === null, () => pick(null), '__all') : null}
          {options.map((o) => option(o.label, o.value === value, () => pick(o.value), String(o.value)))}
        </div>
      ) : null}
    </div>
  );
}

// ── E · MultiSelect ─────────────────────────────────────────────────────

/// 多选筛选:触发器 = 标签 + 选中数徽记;浮层 = 搜索 + 复选列表 + 全选/清除。
/// 空选集 = 不筛选。
export function MultiSelect<T extends string | number>({
  values,
  options,
  onChange,
  ariaLabel,
  allLabel,
  searchPlaceholder = '搜索…'
}: {
  values: T[];
  options: Array<SelectOption<T>>;
  onChange: (values: T[]) => void;
  ariaLabel: string;
  allLabel: string;
  searchPlaceholder?: string;
}) {
  const [open, setOpen] = useState(false);
  const [search, setSearch] = useState('');
  const rootRef = useRef<HTMLDivElement | null>(null);
  useDismiss(open, rootRef, () => setOpen(false));

  useEffect(() => {
    if (open) setSearch('');
  }, [open]);

  const toggle = (v: T) => {
    onChange(values.includes(v) ? values.filter((x) => x !== v) : [...values, v]);
  };

  const needle = search.trim().toLowerCase();
  const shown = needle ? options.filter((o) => o.label.toLowerCase().includes(needle)) : options;

  return (
    <div className={`msel${open ? ' open' : ''}`} ref={rootRef}>
      <button
        type="button"
        className="sel-btn"
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-label={ariaLabel}
        onClick={() => setOpen((o) => !o)}
      >
        <span className={values.length === 0 ? '' : 'val'}>{allLabel}</span>
        <span className="cnt">{values.length > 0 ? String(values.length) : ''}</span>
        {values.length > 0 ? <ClearIcon label="清除项目筛选" onClear={() => onChange([])} /> : null}
        <Chevron />
      </button>
      {open ? (
        <div className="msel-pop" role="listbox" aria-multiselectable="true" aria-label={ariaLabel} style={{ display: 'block' }}>
          <div className="search">
            <svg width="11" height="11" viewBox="0 0 14 14" fill="none" aria-hidden="true">
              <circle cx="6" cy="6" r="4.4" stroke="currentColor" strokeWidth="1.4" />
              <path d="m9.4 9.4 3.1 3.1" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
            </svg>
            <input
              type="search"
              placeholder={searchPlaceholder}
              value={search}
              autoFocus
              onChange={(e) => setSearch(e.target.value)}
            />
          </div>
          <div className="msel-list">
            {shown.length === 0 ? <div className="msel-empty">没有匹配「{search.trim()}」的项</div> : null}
            {shown.map((o) => {
              const on = values.includes(o.value);
              return (
                <button
                  key={String(o.value)}
                  type="button"
                  role="option"
                  aria-selected={on}
                  className={`msel-opt${on ? ' on' : ''}`}
                  onClick={() => toggle(o.value)}
                >
                  <span className="box" aria-hidden="true"><CheckMark width={9} /></span>
                  <span className="nm">{o.label}</span>
                </button>
              );
            })}
          </div>
          <div className="msel-foot">
            <button type="button" onClick={() => onChange(options.map((o) => o.value))}>全选</button>
            <button type="button" onClick={() => onChange([])}>清除</button>
          </div>
        </div>
      ) : null}
    </div>
  );
}

// ── 日历(F/日期范围共用) ───────────────────────────────────────────────

export interface DateRange {
  /// 'YYYY-MM-DD',闭区间。
  from: string;
  to: string;
}

function fmtDate(d: Date): string {
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
}

function shiftDays(base: Date, days: number): Date {
  const d = new Date(base);
  d.setDate(d.getDate() + days);
  return d;
}

interface MonthCursor {
  year: number;
  month: number;
}

/// 单月日历(设计稿 .cal-*):范围端点 rs/re 实底圆角端、确定范围中段
/// inrange 14% tint、hover 预选中段 preview 8% tint 更浅一档。
function CalendarMonth({
  cursor,
  onCursor,
  range,
  pendingFrom,
  hoverDate,
  onPick,
  onHover
}: {
  cursor: MonthCursor;
  onCursor: (next: MonthCursor) => void;
  range: DateRange | null;
  pendingFrom: string | null;
  hoverDate: string | null;
  onPick: (date: string) => void;
  onHover: (date: string | null) => void;
}) {
  const firstOfMonth = new Date(cursor.year, cursor.month, 1);
  const leadingBlanks = (firstOfMonth.getDay() + 6) % 7;
  const daysInMonth = new Date(cursor.year, cursor.month + 1, 0).getDate();
  const todayText = fmtDate(new Date());

  // 预选段(起点已定、追随悬停)与确定范围分开着色:preview 比 inrange 浅一档。
  const previewRange = ((): DateRange | null => {
    if (pendingFrom === null) return null;
    if (hoverDate === null) return { from: pendingFrom, to: pendingFrom };
    return pendingFrom <= hoverDate
      ? { from: pendingFrom, to: hoverDate }
      : { from: hoverDate, to: pendingFrom };
  })();
  const activeRange = previewRange ?? range;
  const middleClass = previewRange !== null ? 'preview' : 'inrange';

  const dayClass = (date: string): string => {
    const classes = ['cal-d'];
    if (date === todayText) classes.push('today');
    if (activeRange !== null && date >= activeRange.from && date <= activeRange.to) {
      if (activeRange.from === activeRange.to) classes.push('rs', 're');
      else if (date === activeRange.from) classes.push('rs');
      else if (date === activeRange.to) classes.push('re');
      else classes.push(middleClass);
    }
    return classes.join(' ');
  };

  return (
    <div className="dtrp-cal">
      <div className="cal-head">
        <button
          type="button"
          aria-label="上月"
          onClick={() => onCursor(cursor.month === 0 ? { year: cursor.year - 1, month: 11 } : { ...cursor, month: cursor.month - 1 })}
        >
          <svg width="10" height="10" viewBox="0 0 10 10" fill="none" aria-hidden="true"><path d="M6.5 2 3.5 5l3 3" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" /></svg>
        </button>
        <span className="mon">{cursor.year}-{pad2(cursor.month + 1)}</span>
        <button
          type="button"
          aria-label="下月"
          onClick={() => onCursor(cursor.month === 11 ? { year: cursor.year + 1, month: 0 } : { ...cursor, month: cursor.month + 1 })}
        >
          <svg width="10" height="10" viewBox="0 0 10 10" fill="none" aria-hidden="true"><path d="m3.5 2 3 3-3 3" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" /></svg>
        </button>
      </div>
      <div className="cal-grid" role="grid" onMouseLeave={() => onHover(null)}>
        {['一', '二', '三', '四', '五', '六', '日'].map((w) => (
          <span key={w} className="wd">{w}</span>
        ))}
        {Array.from({ length: leadingBlanks }, (_, i) => <span key={`blank-${i}`} />)}
        {Array.from({ length: daysInMonth }, (_, i) => {
          const date = fmtDate(new Date(cursor.year, cursor.month, i + 1));
          return (
            <button
              key={date}
              type="button"
              className={dayClass(date)}
              onClick={() => onPick(date)}
              onMouseEnter={pendingFrom !== null ? () => onHover(date) : undefined}
            >
              {i + 1}
            </button>
          );
        })}
      </div>
    </div>
  );
}

/// 快捷范围(都以本地今天为锚)。
function quickRanges(): Array<{ label: string; range: DateRange | null }> {
  const today = new Date();
  const t = fmtDate(today);
  const monday = shiftDays(today, -((today.getDay() + 6) % 7));
  const monthStart = new Date(today.getFullYear(), today.getMonth(), 1);
  return [
    { label: '全部时间', range: null },
    { label: '今天', range: { from: t, to: t } },
    { label: '昨天', range: { from: fmtDate(shiftDays(today, -1)), to: fmtDate(shiftDays(today, -1)) } },
    { label: '本周', range: { from: fmtDate(monday), to: t } },
    { label: '本月', range: { from: fmtDate(monthStart), to: t } },
    { label: '近 7 天', range: { from: fmtDate(shiftDays(today, -6)), to: t } },
    { label: '近 30 天', range: { from: fmtDate(shiftDays(today, -29)), to: t } },
    { label: '近一年', range: { from: fmtDate(shiftDays(today, -364)), to: t } }
  ];
}

function sameDateRange(left: DateRange | null, right: DateRange | null): boolean {
  if (left === null || right === null) return left === right;
  return left.from === right.from && left.to === right.to;
}

/// 日期范围选择器(天粒度,会话页):快捷项即选即关;日历第一次点=起点,
/// 第二次点=终点(早于起点自动交换)后即关。
export function DateRangePicker({
  value,
  onChange,
  ariaLabel
}: {
  value: DateRange | null;
  onChange: (range: DateRange | null) => void;
  ariaLabel: string;
}) {
  const [open, setOpen] = useState(false);
  const [monthCursor, setMonthCursor] = useState<MonthCursor>(() => {
    const d = new Date();
    return { year: d.getFullYear(), month: d.getMonth() };
  });
  const [pendingFrom, setPendingFrom] = useState<string | null>(null);
  const [hoverDate, setHoverDate] = useState<string | null>(null);
  const [selectedQuickLabel, setSelectedQuickLabel] = useState<string | null>(null);
  const rootRef = useRef<HTMLDivElement | null>(null);
  useDismiss(open, rootRef, () => setOpen(false));

  useEffect(() => {
    if (!open) return;
    setPendingFrom(null);
    setHoverDate(null);
  }, [open]);

  const pickDay = (date: string) => {
    if (pendingFrom === null) {
      setPendingFrom(date);
      return;
    }
    const [from, to] = pendingFrom <= date ? [pendingFrom, date] : [date, pendingFrom];
    setPendingFrom(null);
    setSelectedQuickLabel(null);
    setOpen(false);
    onChange({ from, to });
  };

  const quickOptions = quickRanges();
  const selectedQuickMatchesValue = selectedQuickLabel !== null
    && quickOptions.some((option) => option.label === selectedQuickLabel && sameDateRange(option.range, value));
  const activeQuickLabel = selectedQuickMatchesValue
    ? selectedQuickLabel
    : quickOptions.find((option) => sameDateRange(option.range, value))?.label ?? null;

  const label = value === null
    ? '全部时间'
    : value.from === value.to
      ? value.from
      : `${value.from} ~ ${value.to}`;

  return (
    <div className={`sel dtrp-wrap${open ? ' open' : ''}`} ref={rootRef}>
      <button
        type="button"
        className="sel-btn"
        aria-haspopup="dialog"
        aria-expanded={open}
        aria-label={ariaLabel}
        onClick={() => setOpen((o) => !o)}
      >
        <svg width="11" height="11" viewBox="0 0 14 14" fill="none" aria-hidden="true">
          <rect x="1.5" y="2.5" width="11" height="10" rx="2" stroke="currentColor" strokeWidth="1.4" />
          <path d="M1.5 5.5h11M4.5 1v3M9.5 1v3" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
        </svg>
        <span className={value === null ? '' : 'val num'}>{label}</span>
        {value !== null ? (
          <ClearIcon
            label="清除日期筛选"
            onClear={() => {
              setSelectedQuickLabel(null);
              onChange(null);
            }}
          />
        ) : null}
      </button>
      {open ? (
        <div className="dtrp-pop" role="dialog" aria-label={ariaLabel}>
          <div className="dtrp">
            <div className="dtrp-main">
              <div className="dtrp-quick">
                {quickOptions.map((q) => (
                  <button
                    key={q.label}
                    type="button"
                    className={q.label === activeQuickLabel ? 'on' : ''}
                    onClick={() => {
                      setSelectedQuickLabel(q.label);
                      setOpen(false);
                      onChange(q.range);
                    }}
                  >
                    {q.label}
                  </button>
                ))}
              </div>
              <CalendarMonth
                cursor={monthCursor}
                onCursor={setMonthCursor}
                range={value}
                pendingFrom={pendingFrom}
                hoverDate={hoverDate}
                onPick={pickDay}
                onHover={setHoverDate}
              />
            </div>
          </div>
        </div>
      ) : null}
    </div>
  );
}

// ── F · DateTimeRangePicker ─────────────────────────────────────────────

/// 毫秒精度的时间范围(含时刻)。undefined 端 = 不设界。
export interface DateTimeRangeValue {
  from?: Date;
  to?: Date;
}

function combine(date: string, time: string): Date {
  const [y, mo, d] = date.split('-').map(Number);
  const [h, mi] = time.split(':').map(Number);
  return new Date(y, mo - 1, d, h, mi, 0, 0);
}

function formatPoint(d: Date): string {
  return `${d.getMonth() + 1}/${d.getDate()} ${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
}

/// 时间范围选择(设计稿 F,分钟精度):快捷项列 + 日历 + 起止时刻 + 应用/取消。
/// 「额度刷新时刻 → 周期结束」的统计场景。快捷项填充范围并高亮,手动点日历
/// 即清除快捷激活;起止同日且起 > 止时 TimeField 走 error 态,「应用」拒绝提交。
export function DateTimeRangePicker({
  value,
  onChange,
  ariaLabel
}: {
  value: DateTimeRangeValue;
  onChange: (next: DateTimeRangeValue) => void;
  ariaLabel: string;
}) {
  const [open, setOpen] = useState(false);
  const [monthCursor, setMonthCursor] = useState<MonthCursor>(() => {
    const d = new Date();
    return { year: d.getFullYear(), month: d.getMonth() };
  });
  const [start, setStart] = useState<string | null>(null);
  const [end, setEnd] = useState<string | null>(null);
  const [timeStart, setTimeStart] = useState('00:00');
  const [timeEnd, setTimeEnd] = useState('23:59');
  const [quick, setQuick] = useState<string | null>(null);
  const [hoverDate, setHoverDate] = useState<string | null>(null);
  const rootRef = useRef<HTMLDivElement | null>(null);
  useDismiss(open, rootRef, () => setOpen(false));

  // 打开时从受控值初始化草稿(应用前的改动都只动草稿)。
  useEffect(() => {
    if (!open) return;
    const from = value.from;
    const to = value.to;
    setStart(from ? fmtDate(from) : null);
    setEnd(to ? fmtDate(to) : null);
    setTimeStart(from ? `${pad2(from.getHours())}:${pad2(from.getMinutes())}` : '00:00');
    setTimeEnd(to ? `${pad2(to.getHours())}:${pad2(to.getMinutes())}` : '23:59');
    setQuick(null);
    setHoverDate(null);
    const anchor = from ?? new Date();
    setMonthCursor({ year: anchor.getFullYear(), month: anchor.getMonth() });
  }, [open, value.from, value.to]);

  const timesInvalid = start !== null && start === end && timeStart > timeEnd;

  const pickDay = (date: string) => {
    setQuick(null);
    if (start === null || (start !== null && end !== null)) {
      setStart(date);
      setEnd(null);
    } else if (date < start) {
      setEnd(start);
      setStart(date);
    } else {
      setEnd(date);
    }
    setHoverDate(null);
  };

  const applyQuick = (label: string, range: { from: Date; to: Date }) => {
    setQuick(label);
    setStart(fmtDate(range.from));
    setEnd(fmtDate(range.to));
    setTimeStart(`${pad2(range.from.getHours())}:${pad2(range.from.getMinutes())}`);
    setTimeEnd(`${pad2(range.to.getHours())}:${pad2(range.to.getMinutes())}`);
    setMonthCursor({ year: range.from.getFullYear(), month: range.from.getMonth() });
    setHoverDate(null);
  };

  const quickItems = (): Array<{ label: string; range: { from: Date; to: Date } }> => {
    const now = new Date();
    const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    const monday = shiftDays(today, -((today.getDay() + 6) % 7));
    return [
      { label: '今天', range: { from: today, to: now } },
      { label: '昨天', range: { from: shiftDays(today, -1), to: new Date(today.getTime() - 1) } },
      { label: '本周至今', range: { from: monday, to: now } },
      { label: '本月至今', range: { from: new Date(now.getFullYear(), now.getMonth(), 1), to: now } },
      { label: '近 7 天', range: { from: shiftDays(today, -6), to: now } },
      { label: '近 30 天', range: { from: shiftDays(today, -29), to: now } }
    ];
  };

  const apply = () => {
    if (start === null || timesInvalid) return;
    onChange({
      from: combine(start, timeStart),
      to: end !== null ? combine(end, timeEnd) : undefined
    });
    setOpen(false);
  };

  const hasValue = value.from !== undefined || value.to !== undefined;
  const label = hasValue
    ? `${value.from ? formatPoint(value.from) : '…'} – ${value.to ? formatPoint(value.to) : '现在'}`
    : '全部时间';

  const draftRange: DateRange | null = start !== null
    ? { from: start, to: end ?? start }
    : null;

  const summary = start !== null
    ? `${start} ${timeStart} → ${end !== null ? `${end} ${timeEnd}` : '现在'}`
    : '';

  return (
    <div className={`sel dtrp-wrap${open ? ' open' : ''}`} ref={rootRef}>
      <button
        type="button"
        className="sel-btn"
        aria-haspopup="dialog"
        aria-expanded={open}
        aria-label={ariaLabel}
        onClick={() => setOpen((o) => !o)}
      >
        <svg width="11" height="11" viewBox="0 0 14 14" fill="none" aria-hidden="true">
          <rect x="1.5" y="2.5" width="11" height="10" rx="2" stroke="currentColor" strokeWidth="1.4" />
          <path d="M1.5 5.5h11M4.5 1v3M9.5 1v3" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
        </svg>
        <span className={hasValue ? 'val num' : ''}>{label}</span>
        {hasValue ? <ClearIcon label="清除时间筛选" onClear={() => onChange({})} /> : null}
      </button>
      {open ? (
        <div className="dtrp-pop" role="dialog" aria-label={ariaLabel}>
          <div className="dtrp">
            <div className="dtrp-main">
              <div className="dtrp-quick">
                {quickItems().map((q) => (
                  <button
                    key={q.label}
                    type="button"
                    className={quick === q.label ? 'on' : ''}
                    onClick={() => applyQuick(q.label, q.range)}
                  >
                    {q.label}
                  </button>
                ))}
              </div>
              <CalendarMonth
                cursor={monthCursor}
                onCursor={setMonthCursor}
                range={draftRange}
                pendingFrom={end === null ? start : null}
                hoverDate={hoverDate}
                onPick={pickDay}
                onHover={setHoverDate}
              />
            </div>
            <div className="dtrp-times">
              <span className="lbl">起</span>
              <TimeField value={timeStart} onChange={(t) => { setQuick(null); setTimeStart(t); }} disabled={start === null} error={timesInvalid} ariaLabel="起" />
              <span className="arrow">→</span>
              <span className="lbl">止</span>
              <TimeField value={timeEnd} onChange={(t) => { setQuick(null); setTimeEnd(t); }} disabled={end === null} error={timesInvalid} ariaLabel="止" />
            </div>
            <div className="dtrp-foot">
              <span className="dtrp-sum">{summary}</span>
              <Button variant="ghost" onClick={() => setOpen(false)}>取消</Button>
              <Button variant="primary" disabled={start === null || timesInvalid} onClick={apply}>应用</Button>
            </div>
          </div>
        </div>
      ) : null}
    </div>
  );
}

// ── G · Switch ──────────────────────────────────────────────────────────

export function Switch({
  checked,
  onChange,
  disabled = false,
  ariaLabel
}: {
  checked: boolean;
  onChange: (next: boolean) => void;
  disabled?: boolean;
  ariaLabel: string;
}) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-label={ariaLabel}
      className={`sw${checked ? ' on' : ''}`}
      disabled={disabled}
      onClick={() => onChange(!checked)}
    />
  );
}

// ── H · Slider ──────────────────────────────────────────────────────────

/// 阈值滑条:拖拽 / 点击轨道 / ←→ 键均可调;值 ≥ warnAt 进入 warn 视觉。
export function Slider({
  value,
  min,
  max,
  step,
  onChange,
  warnAt,
  disabled = false,
  ariaLabel,
  format = (v) => `${v}%`
}: {
  value: number;
  min: number;
  max: number;
  step: number;
  onChange: (next: number) => void;
  warnAt?: number;
  disabled?: boolean;
  ariaLabel: string;
  format?: (v: number) => string;
}) {
  const trackRef = useRef<HTMLDivElement | null>(null);
  const [dragging, setDragging] = useState(false);

  const clamp = (v: number) => Math.round(Math.min(max, Math.max(min, v)) / step) * step;

  const fromClientX = (clientX: number) => {
    const rect = trackRef.current?.getBoundingClientRect();
    if (!rect || rect.width === 0) return;
    const next = clamp(min + ((clientX - rect.left) / rect.width) * (max - min));
    if (next !== value) onChange(next);
  };

  useEffect(() => {
    if (!dragging) return;
    const onMove = (e: MouseEvent) => fromClientX(e.clientX);
    const onUp = () => setDragging(false);
    document.addEventListener('mousemove', onMove);
    document.addEventListener('mouseup', onUp);
    return () => {
      document.removeEventListener('mousemove', onMove);
      document.removeEventListener('mouseup', onUp);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [dragging, value]);

  const pct = ((value - min) / (max - min)) * 100;
  const warn = warnAt !== undefined && value >= warnAt;

  return (
    <div
      className={`sld${warn ? ' warn' : ''}${dragging ? ' drag' : ''}${disabled ? ' dis' : ''}`}
      role="slider"
      tabIndex={disabled ? -1 : 0}
      aria-label={ariaLabel}
      aria-valuemin={min}
      aria-valuemax={max}
      aria-valuenow={value}
      onKeyDown={(e) => {
        if (e.key === 'ArrowLeft' || e.key === 'ArrowDown') { e.preventDefault(); onChange(clamp(value - step)); }
        else if (e.key === 'ArrowRight' || e.key === 'ArrowUp') { e.preventDefault(); onChange(clamp(value + step)); }
      }}
    >
      <div
        className="sld-track"
        ref={trackRef}
        onMouseDown={(e) => { setDragging(true); fromClientX(e.clientX); }}
      >
        <div className="sld-fill" style={{ width: `${pct}%` }} />
        <div className="sld-thumb" style={{ left: `${pct}%` }} />
      </div>
      <span className="sld-val">{format(value)}</span>
    </div>
  );
}

// ── I · Pager ───────────────────────────────────────────────────────────

/// 页码折叠算法(设计稿):≤7 页全列;当前页贴边时单侧省略,居中时双侧省略。
function pageList(page: number, pageCount: number): Array<number | '…'> {
  if (pageCount <= 7) return Array.from({ length: pageCount }, (_, i) => i + 1);
  if (page <= 3) return [1, 2, 3, 4, '…', pageCount];
  if (page >= pageCount - 2) return [1, '…', pageCount - 3, pageCount - 2, pageCount - 1, pageCount];
  return [1, '…', page - 1, page, page + 1, '…', pageCount];
}

/// 页码分页:mono 页码、当前页 accent 实底、首末页对应方向禁用。
/// 页数为 0 或 1 时不渲染。
export function Pager({
  page,
  pageCount,
  onPage,
  info
}: {
  page: number;
  pageCount: number;
  onPage: (page: number) => void;
  /// 左侧信息行(如「共 N 条 · 每页 50」),缺省不渲染。
  info?: ReactNode;
}) {
  if (pageCount <= 1) return null;
  return (
    <div className="pager" role="navigation" aria-label="分页">
      {info !== undefined ? <span className="info">{info}</span> : null}
      <div className="pgr">
        <button type="button" aria-label="上一页" disabled={page <= 1} onClick={() => onPage(page - 1)}>‹</button>
        {pageList(page, pageCount).map((n, i) =>
          n === '…'
            ? <span key={`gap-${i}`} className="gap">…</span>
            : (
              <button
                key={n}
                type="button"
                className={n === page ? 'on' : ''}
                aria-current={n === page ? 'page' : undefined}
                onClick={() => onPage(n)}
              >
                {n}
              </button>
            )
        )}
        <button type="button" aria-label="下一页" disabled={page >= pageCount} onClick={() => onPage(page + 1)}>›</button>
      </div>
    </div>
  );
}

/// 统一外观的筛选条容器(沿用 .sess-filter 的布局语义,命名去场景化)。
export function FilterBar({ children }: { children: ReactNode }) {
  return <div className="sess-filter">{children}</div>;
}
