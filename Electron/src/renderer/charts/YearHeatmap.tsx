import { useEffect, useRef, useState, type MouseEvent } from 'react';
import { createPortal } from 'react-dom';
import type { HeatmapDay } from '../../main/overviewRepository.js';
import { buildCalendarGrid } from './calendar.js';
import { logBucket } from './scale.js';
import { formatCount, formatTokens, formatUsdMicros } from '../format.js';

export type HeatmapMetric = 'tokens' | 'costUsdMicros' | 'sessions' | 'events';

/// 色阶走 CSS 变量 --heat-0..4（主题可切），带 GitHub 式绿色兜底，
/// 使本组件不依赖 styles.css 的先行定义。
const HEAT_FALLBACK = ['#ebedf0', '#9be9a8', '#40c463', '#30a14e', '#216e39'];

export interface YearHeatmapProps {
  days: HeatmapDay[];
  lastDay: string;
  count?: number;
  metric?: HeatmapMetric;
}

/// 弹层定位用的格子视口坐标（浮层是 fixed，直接吃 getBoundingClientRect）。
function cellViewportPos(cell: Element): { x: number; top: number; bottom: number } {
  const box = cell.getBoundingClientRect();
  return { x: box.left, top: box.top, bottom: box.bottom };
}

/// 明细行（模型或项目一行）：label + 四个指标，渲染端只关心当前指标那一列。
interface DetailRow {
  label: string;
  tokens: number;
  costUsdMicros: number;
  sessions: number;
  events: number;
}

/// 明细行的数值跟随当前切换的指标（Token/成本/会话/事件切什么显示什么）。
function formatMetricValue(row: DetailRow, metric: HeatmapMetric): string {
  if (metric === 'costUsdMicros') return formatUsdMicros(row.costUsdMicros);
  if (metric === 'tokens') return formatTokens(row.tokens, true);   // 单日 → 锁 M 单位
  return formatCount(row[metric]);
}

/// 371 格年度活动热力图。一格一天，空日由日历网格补成 level 0（repository 不造零行）。
///
/// hover 走【事件委托】：整张网格挂一个监听，从 event.target.dataset.date
/// 取日期，而不是给 371 个格子各挂处理器。
///
/// 交互只有悬浮一种：悬浮弹出日详情（汇总 + 按模型明细）。曾经的「点击钉住」
/// 已移除——悬浮小卡与钉住大卡并存看起来像两个弹窗（用户裁定只留一个）。
/// 明细改为悬浮即取、按日缓存，扫过整年也不会对同一天重复打 IPC。
export function YearHeatmap({ days, lastDay, count = 371, metric = 'tokens' }: YearHeatmapProps) {
  const [hovered, setHovered] = useState<string | null>(null);
  const [pos, setPos] = useState<{ x: number; top: number; bottom: number }>({ x: 0, top: 0, bottom: 0 });
  const [detailRows, setDetailRows] = useState<DetailRow[]>([]);
  const breakdownCache = useRef(new Map<string, DetailRow[]>());

  // 明细维度跟随指标：Token/成本按模型（计价的自然维度）；会话/事件按项目——
  // 「按模型数会话」没有意义（一个会话可以用多个模型，加总会重复计）。
  const byProject = metric === 'sessions' || metric === 'events';

  // 悬浮即取当日明细：结果按「维度+日期」缓存；异步返回只应用仍悬浮的那一天，
  // 晚到的旧结果丢弃。
  useEffect(() => {
    if (!hovered) {
      setDetailRows([]);
      return;
    }
    const cacheKey = `${byProject ? 'project' : 'model'}:${hovered}`;
    const cached = breakdownCache.current.get(cacheKey);
    if (cached) {
      setDetailRows(cached);
      return;
    }
    setDetailRows([]);
    let cancelled = false;
    // 可选链：无 preload 的环境（组件单测）没有 window.tokenMeter，静默无明细。
    const fetched: Promise<DetailRow[]> | undefined = byProject
      ? window.tokenMeter?.overview.dayProjectBreakdown(hovered)
          .then(rows => rows.map(r => ({ ...r, label: r.project })))
      : window.tokenMeter?.overview.dayModelBreakdown(hovered)
          .then(rows => rows.map(r => ({ ...r, label: r.model })));
    fetched
      ?.then(rows => {
        breakdownCache.current.set(cacheKey, rows);
        if (!cancelled) setDetailRows(rows);
      })
      .catch((error: unknown) => {
        // UI 上静默为无明细，但要留下日志——主进程与 renderer 版本不同步
        // （旧主进程没有新 IPC handler）时，这里是唯一的线索。
        console.error('day breakdown 拉取失败', error);
        if (!cancelled) setDetailRows([]);
      });
    return () => {
      cancelled = true;
    };
  }, [hovered, byProject]);

  // 浮层是 fixed（挂在 body 下），页面/热力图一滚动，格子的视口坐标就过期，
  // 而滚动中鼠标不动、mouseover 不会再触发——干脆滚动即收起，等鼠标再动。
  // capture 监听一切滚动（主区 .main 与热力图自身的横向滚动都不冒泡到 window）。
  useEffect(() => {
    if (!hovered) return;
    const clear = () => setHovered(null);
    window.addEventListener('scroll', clear, true);
    return () => window.removeEventListener('scroll', clear, true);
  }, [hovered]);

  const dayByDate = new Map(days.map(d => [d.date, d]));
  const max = Math.max(0, ...days.map(d => d[metric]));
  const columns = buildCalendarGrid(lastDay, count);
  const shownDay = hovered ? dayByDate.get(hovered) : undefined;

  const handleOver = (e: MouseEvent) => {
    const d = (e.target as HTMLElement).dataset?.date;
    if (!d) { setHovered(null); return; }
    setPos(cellViewportPos(e.target as HTMLElement));
    setHovered(d);
  };

  return (
    <div className="year-heatmap">
      <div
        className="year-heatmap__grid"
        style={{ display: 'flex', gap: 3 }}
        onMouseOver={handleOver}
        onMouseLeave={() => setHovered(null)}
      >
        {columns.map((column, colIndex) => (
          <div key={colIndex} className="year-heatmap__col"
            style={{ display: 'flex', flexDirection: 'column', gap: 3 }}>
            {column.map((cell, rowIndex) => {
              // 占位格：首列里早于起始日的星期行，只为对齐、没有真实日期，
              // 不可 hover，也不参与配色。
              if (cell.date === null) {
                return <div key={rowIndex} style={{ width: 11, height: 11 }} aria-hidden="true" />;
              }
              const level = logBucket(dayByDate.get(cell.date)?.[metric] ?? 0, max);
              return (
                <div key={cell.date} className="year-heatmap__cell"
                  data-date={cell.date} data-level={level}
                  style={{
                    width: 11, height: 11, borderRadius: 2,
                    backgroundColor: `var(--heat-${level}, ${HEAT_FALLBACK[level]})`
                  }} />
              );
            })}
          </div>
        ))}
      </div>

      {/* 色阶图例：不标注方向时读者无法知道深浅代表多还是少（用户实测困惑）。 */}
      <div className="heat-foot">
        <span>少</span>
        <div className="hscale" aria-hidden="true">
          {[0, 1, 2, 3, 4].map((level) => (
            <i key={level} data-l={level} />
          ))}
        </div>
        <span>多</span>
      </div>

      {hovered && shownDay && createPortal((() => {
        // portal 到 body + fixed：卡片和热力图滚动区的 overflow 都管不到它，
        // 不再被裁切、也不再把滚动条撑出来。左右夹在视口内；上方空间不足
        // （容不下带 6 行明细约 300px 高的卡片）时翻到格子下方显示。
        const POP_WIDTH = 300; // 与 styles.css 的 .day-pop width 同步
        const left = Math.max(8, Math.min(pos.x, window.innerWidth - POP_WIDTH - 8));
        const flipBelow = pos.top < 320;
        return (
          <div
            role="tooltip"
            className="day-pop on"
            style={{
              left,
              top: flipBelow ? pos.bottom + 8 : pos.top - 8,
              transform: flipBelow ? 'none' : 'translateY(-100%)'
            }}
          >
            <h4>{hovered}</h4>
            <div className="dp-stats">
              <div>
                <b>{formatTokens(shownDay.tokens, true)}</b>
                <span>Token</span>
              </div>
              <div>
                <b>{formatUsdMicros(shownDay.costUsdMicros)}</b>
                <span>花费</span>
              </div>
              <div>
                <b>{formatCount(shownDay.sessions)}</b>
                <span>会话</span>
              </div>
              <div>
                <b>{formatCount(shownDay.events)}</b>
                <span>事件</span>
              </div>
            </div>
            {[...detailRows]
              .sort((a, b) => b[metric] - a[metric])
              .slice(0, 6)
              .map(r => (
                <div className="dp-mrow" key={r.label}>
                  <span className="mono">{r.label}</span>
                  <span className="num">{formatMetricValue(r, metric)}</span>
                </div>
              ))}
          </div>
        );
      })(), document.body)}
    </div>
  );
}
