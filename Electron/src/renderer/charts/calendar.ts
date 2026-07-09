import { localBucketKeys, pad2 } from '../../shared/calendar.js';

export interface CalendarCell { date: string; }

/// 把「以 lastDay 结尾的 days 天」摆成 GitHub 式的周列网格：每列是一周（周日起），
/// 首列可能不满（最早那几天），末列止于 lastDay。行=星期几，列=第几周。
///
/// 逐日推进走共享的 localBucketKeys（本地日历，DST 安全），本文件不重算日期——
/// 那正是 calendar.dst.test.ts 守住的东西：epoch 步进会在 DST 切换日丢/重一天。
export function buildCalendarGrid(lastDay: string, days: number): CalendarCell[][] {
  const [ly, lm, ld] = lastDay.split('-').map(Number);
  const start = new Date(ly, lm - 1, ld - (days - 1));   // 本地日历回退，跨月/DST 都正确
  const startIso = `${start.getFullYear()}-${pad2(start.getMonth() + 1)}-${pad2(start.getDate())}`;

  const columns: CalendarCell[][] = [];
  let column: CalendarCell[] = [];
  for (const date of localBucketKeys(startIso, lastDay, 'day')) {
    const [y, m, d] = date.split('-').map(Number);
    const weekday = new Date(y, m - 1, d).getDay();       // 0=周日；本地星期几，稳定
    if (weekday === 0 && column.length > 0) {
      columns.push(column);
      column = [];
    }
    column.push({ date });
  }
  if (column.length > 0) columns.push(column);
  return columns;
}
