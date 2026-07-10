import { localBucketKeys, pad2 } from '../../shared/calendar.js';

/// `date` 为空表示占位格——首列里早于起始日的星期行，或末列里晚于 lastDay
/// （还没发生）的星期行。只用来把每一列对齐成完整的 7 行，不对应任何真实
/// 日期——渲染时必须留白、不可 hover/click。
export interface CalendarCell { date: string | null; }

/// 把「以 lastDay 结尾的 days 天」摆成 GitHub 式的周列网格：每列是一周（周日起，
/// 周六止），首尾都补齐到 7 行，整张网格是一个规整的长方形。行=星期几，列=第几周。
///
/// 首列按星期几左侧留白：起始日如果落在周三，首列前 3 行（周日/周一/周二）
/// 没有数据，若不补占位格，这些真实日期会被挤到第 0~2 行，视觉上偏移整整
/// 一个星期，跟其余每一列的行对齐规则不一致。
///
/// 末列同理，右侧补到周六：lastDay 通常是「今天」，一周大概率没走完。不补的话
/// 末列会比其他列矮一截，整张热力图右下角缺一块，不是长方形。补的是还没发生
/// 的日子（比如明天），本来就没有数据，标成占位格不会丢真实信息。
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
  while (column.length < 7) column.push({ date: null });  // 补到周六，末列跟其余列一样满
  columns.push(column);
  return columns;
}
