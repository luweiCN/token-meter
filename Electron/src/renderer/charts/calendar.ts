import { localBucketKeys, pad2 } from '../../shared/calendar.js';

/// `date` 为空表示占位格（首列里那些早于起始日的星期行），只用来把列对齐到
/// 正确的星期行，不对应任何真实日期——渲染时必须留白、不可 hover/click。
export interface CalendarCell { date: string | null; }

/// 把「以 lastDay 结尾的 days 天」摆成 GitHub 式的周列网格：每列是一周（周日起），
/// 首列可能不满（最早那几天），末列止于 lastDay。行=星期几，列=第几周。
///
/// 首列必须按星期几左侧留白，不能直接从数组下标 0 开始堆：起始日如果落在周三，
/// 首列前 3 行（周日/周一/周二）没有数据，若不补占位格，这 4 个真实日期会被
/// 挤到第 0~3 行，视觉上偏移整整一个星期——跟其余每一列的行对齐规则不一致，
/// 看起来就像「第一列位置摆错了」。
///
/// 逐日推进走共享的 localBucketKeys（本地日历，DST 安全），本文件不重算日期——
/// 那正是 calendar.dst.test.ts 守住的东西：epoch 步进会在 DST 切换日丢/重一天。
export function buildCalendarGrid(lastDay: string, days: number): CalendarCell[][] {
  const [ly, lm, ld] = lastDay.split('-').map(Number);
  const start = new Date(ly, lm - 1, ld - (days - 1));   // 本地日历回退，跨月/DST 都正确
  const startIso = `${start.getFullYear()}-${pad2(start.getMonth() + 1)}-${pad2(start.getDate())}`;
  const startWeekday = start.getDay();                    // 0=周日

  const columns: CalendarCell[][] = [];
  let column: CalendarCell[] = Array.from({ length: startWeekday }, () => ({ date: null }));
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
