import { useRef, useState, type MouseEvent } from 'react';
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
  const gridRef = useRef<HTMLDivElement>(null);

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

      {shownDate && shownDay && (
        <div
          role="tooltip"
          className={`year-heatmap__card${pinned === shownDate ? ' is-pinned' : ''}`}
          style={{
            position: 'absolute',
            top: pos.y - 8,
            left: pos.x,
            transform: 'translateY(-100%)',
            pointerEvents: pinned === shownDate ? 'auto' : 'none'
          }}
        >
          <div className="year-heatmap__card-head">
            <span className="year-heatmap__card-date">{shownDate}</span>
            {pinned === shownDate ? (
              <button
                type="button"
                className="year-heatmap__card-close"
                aria-label="关闭"
                onClick={() => setPinned(null)}
              >
                ×
              </button>
            ) : null}
          </div>
          <strong className="year-heatmap__card-total">
            {formatTokens(shownDay.tokens)} <span>tokens</span>
          </strong>
          <div className="year-heatmap__card-meta">
            <span>{formatUsdMicros(shownDay.costUsdMicros)}</span>
            <span>{formatCount(shownDay.sessions)} 会话</span>
            <span>{formatCount(shownDay.events)} 事件</span>
          </div>
        </div>
      )}
    </div>
  );
}
