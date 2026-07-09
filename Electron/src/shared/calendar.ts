/// 主进程查询与 renderer 图表共用的本地日历算术。放在 src/shared 是刻意的：
/// 两套日历实现必然漂移，而漂移的那份一定是没人在 DST 时区跑过的那份。
/// 守卫见 src/main/localBucketKeys.dst.test.ts 与 src/renderer/charts/calendar.dst.test.ts。

export const pad2 = (n: number) => String(n).padStart(2, '0');

/// 按【本地日历】逐桶推进，不用 epoch 加固定毫秒。
///
/// `t += 86_400_000` 在 DST 结束那天会落到前一天的 23:00。实测
/// America/New_York 从 2026-10-30 起步：
///   epoch 步进 → 10-30  10-31  11-01  11-01  11-02  11-03   ← 11-01 两次，且多一个桶
///   日历步进   → 10-30  10-31  11-01  11-02  11-03
/// 趋势图会因此画出两根同名的柱子。`Date.prototype.setDate` 走本地日历，天然正确。
///
/// DST 结束那天有两个本地「01 时」。这里用 `seen` 把它们并成一桶，与
/// SQL 的 `strftime('%Y-%m-%d %H', ..., 'localtime')` 行为一致——那是
/// 本地时区分桶的固有歧义，两侧必须用同一种解释，否则桶键对不上。
export function* localBucketKeys(from: string, to: string, g: 'hour' | 'day'): Generator<string> {
  const [fy, fm, fd] = from.split('-').map(Number);
  const [ty, tm, td] = to.split('-').map(Number);
  const endExclusive = new Date(ty, tm - 1, td + 1);
  const cursor = new Date(fy, fm - 1, fd);
  const seen = new Set<string>();

  while (cursor < endExclusive) {
    const day = `${cursor.getFullYear()}-${pad2(cursor.getMonth() + 1)}-${pad2(cursor.getDate())}`;
    const key = g === 'hour' ? `${day} ${pad2(cursor.getHours())}` : day;
    if (!seen.has(key)) {
      seen.add(key);
      yield key;
    }
    if (g === 'hour') cursor.setHours(cursor.getHours() + 1);
    else cursor.setDate(cursor.getDate() + 1);
  }
}
