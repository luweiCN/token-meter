import { useEffect, useRef, useState, type MouseEvent } from 'react';
import type { DayModelRow, HeatmapDay } from '../../main/overviewRepository.js';
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

/// 371 格年度活动热力图。一格一天，空日由日历网格补成 level 0（repository 不造零行）。
///
/// hover 与 click 都走【事件委托】：整张网格各挂一个监听，从 event.target.dataset.date
/// 取日期，而不是给 371 个格子各挂一对处理器。
///
/// 点某天不再跳到（当时还是空壳的）用量页——那个跳转只会把人晾在一个没有真实数据的
/// 页面上。点击改成【钉住】同一张卡片：不随 mouseleave 消失，多一个关闭按钮，
/// 再点一次同一天或点关闭都能取消钉住。
export function YearHeatmap({ days, lastDay, count = 371, metric = 'tokens' }: YearHeatmapProps) {
  const [hovered, setHovered] = useState<string | null>(null);
  const [pinned, setPinned] = useState<string | null>(null);
  const [pos, setPos] = useState<{ x: number; y: number }>({ x: 0, y: 0 });
  const [modelRows, setModelRows] = useState<DayModelRow[]>([]);
  const gridRef = useRef<HTMLDivElement>(null);

  // 按模型明细只在钉住时拉取（悬停扫过不打请求）；失败静默为无明细。
  useEffect(() => {
    if (!pinned) {
      setModelRows([]);
      return;
    }
    let cancelled = false;
    // 可选链：无 preload 的环境（组件单测）没有 window.tokenMeter，静默无明细。
    window.tokenMeter?.overview
      .dayModelBreakdown(pinned)
      .then(rows => {
        if (!cancelled) setModelRows(rows);
      })
      .catch(() => {
        if (!cancelled) setModelRows([]);
      });
    return () => {
      cancelled = true;
    };
  }, [pinned]);

  const dayByDate = new Map(days.map(d => [d.date, d]));
  const max = Math.max(0, ...days.map(d => d[metric]));
  const columns = buildCalendarGrid(lastDay, count);

  const shownDate = pinned ?? hovered;
  const shownDay = shownDate ? dayByDate.get(shownDate) : undefined;

  const dateOf = (e: MouseEvent): string | undefined => (e.target as HTMLElement).dataset?.date;
  const handleOver = (e: MouseEvent) => {
    const d = dateOf(e);
    if (!d) { setHovered(null); return; }
    // 相对网格自身定位（而非写死 0,0），跟着悬停的格子走；再在容器内夹取，
    // 避免最右侧几列的卡片溢出可滚动区域。
    const host = gridRef.current;
    if (host) {
      const hostBox = host.getBoundingClientRect();
      const cellBox = (e.target as HTMLElement).getBoundingClientRect();
      setPos({ x: cellBox.left - hostBox.left + host.scrollLeft, y: cellBox.top - hostBox.top });
    }
    setHovered(d);
  };
  // 再点同一天 = 取消钉住；点别的天 = 换钉住的对象。
  const handleClick = (e: MouseEvent) => {
    const d = dateOf(e);
    if (!d) return;
    setPinned((current) => (current === d ? null : d));
  };

  return (
    <div className="year-heatmap" style={{ position: 'relative' }}>
      <div
        ref={gridRef}
        className="year-heatmap__grid"
        style={{ display: 'flex', gap: 3 }}
        onMouseOver={handleOver}
        onMouseLeave={() => setHovered(null)}
        onClick={handleClick}
      >
        {columns.map((column, colIndex) => (
          <div key={colIndex} className="year-heatmap__col"
            style={{ display: 'flex', flexDirection: 'column', gap: 3 }}>
            {column.map((cell, rowIndex) => {
              // 占位格：首列里早于起始日的星期行，只为对齐、没有真实日期，
              // 不可 hover/click，也不参与配色。
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

      {shownDate && shownDay && (() => {
        // 位置夹取：280px 宽的浮层不越出组件右缘（截断的来源），
        // 贴近顶部时翻到格子下方显示。
        const POP_WIDTH = 280;
        const hostWidth = gridRef.current?.clientWidth ?? POP_WIDTH;
        const left = Math.max(0, Math.min(pos.x, hostWidth - POP_WIDTH));
        const flipBelow = pos.y < 150;
        return (
          <div
            role="tooltip"
            className="day-pop on"
            style={{
              left,
              top: flipBelow ? pos.y + 16 : pos.y - 8,
              transform: flipBelow ? 'none' : 'translateY(-100%)',
              pointerEvents: pinned === shownDate ? 'auto' : 'none'
            }}
          >
            <h4>
              <span>{shownDate}</span>
              {pinned === shownDate ? (
                <span className="x" role="button" aria-label="关闭" onClick={() => setPinned(null)}>×</span>
              ) : null}
            </h4>
            <div className="dp-stats">
              <div>
                <b>{formatUsdMicros(shownDay.costUsdMicros)}</b>
                <span>花费</span>
              </div>
              <div>
                <b>{formatTokens(shownDay.tokens)}</b>
                <span>Token</span>
              </div>
              <div>
                <b>{formatCount(shownDay.sessions)}</b>
                <span>会话</span>
              </div>
            </div>
            {pinned === shownDate && modelRows.slice(0, 6).map(r => (
              <div className="dp-mrow" key={r.model}>
                <span className="mono">{r.model}</span>
                <span className="num">{formatTokens(r.tokens)}</span>
              </div>
            ))}
          </div>
        );
      })()}
    </div>
  );
}
