import { useRef, useState, type MouseEvent } from 'react';
import type { HeatmapDay } from '../../main/overviewRepository.js';
import { buildCalendarGrid } from './calendar.js';
import { logBucket } from './scale.js';

export type HeatmapMetric = 'tokens' | 'costUsdMicros' | 'sessions' | 'events';

/// 色阶走 CSS 变量 --heat-0..4（主题可切），带 GitHub 式绿色兜底，
/// 使本组件不依赖 styles.css 的先行定义。
const HEAT_FALLBACK = ['#ebedf0', '#9be9a8', '#40c463', '#30a14e', '#216e39'];

export interface YearHeatmapProps {
  days: HeatmapDay[];
  lastDay: string;
  count?: number;
  metric?: HeatmapMetric;
  onSelectDate: (date: string) => void;
}

/// 371 格年度活动热力图。一格一天，空日由日历网格补成 level 0（repository 不造零行）。
///
/// hover 与 click 都走【事件委托】：整张网格各挂一个监听，从 event.target.dataset.date
/// 取日期，而不是给 371 个格子各挂一对处理器。
export function YearHeatmap({ days, lastDay, count = 371, metric = 'tokens', onSelectDate }: YearHeatmapProps) {
  const [hovered, setHovered] = useState<string | null>(null);
  const [pos, setPos] = useState<{ x: number; y: number }>({ x: 0, y: 0 });
  const gridRef = useRef<HTMLDivElement>(null);

  const valueByDate = new Map(days.map(d => [d.date, d[metric]]));
  const max = Math.max(0, ...valueByDate.values());
  const columns = buildCalendarGrid(lastDay, count);

  const dateOf = (e: MouseEvent): string | undefined => (e.target as HTMLElement).dataset?.date;
  const handleOver = (e: MouseEvent) => {
    const d = dateOf(e);
    if (!d) { setHovered(null); return; }
    // 相对网格自身定位（而非写死 0,0），跟着悬停的格子走；再在容器内夹取，
    // 避免最右侧几列的 tooltip 溢出可滚动区域。
    const host = gridRef.current;
    if (host) {
      const hostBox = host.getBoundingClientRect();
      const cellBox = (e.target as HTMLElement).getBoundingClientRect();
      setPos({ x: cellBox.left - hostBox.left + host.scrollLeft, y: cellBox.top - hostBox.top });
    }
    setHovered(d);
  };
  const handleClick = (e: MouseEvent) => { const d = dateOf(e); if (d) onSelectDate(d); };

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
              const level = logBucket(valueByDate.get(cell.date) ?? 0, max);
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

      {hovered && (
        <div role="tooltip" className="year-heatmap__tooltip"
          style={{ position: 'absolute', top: pos.y - 34, left: pos.x, pointerEvents: 'none' }}>
          <span className="year-heatmap__tooltip-date">{hovered}</span>
          {': '}
          <span className="year-heatmap__tooltip-value">
            {(valueByDate.get(hovered) ?? 0).toLocaleString()}
          </span>
        </div>
      )}
    </div>
  );
}
