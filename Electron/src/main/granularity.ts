export type Granularity = 'hour' | 'day' | 'week' | 'month';

const DAY_MS = 86_400_000;

/// 一屏能读的柱子上限。1180px 窗口下主区约 840px，120 根柱子已是每根 7px。
/// barCount 的测试把这个数与 allowedGranularities 绑在一起。
export const MAX_BARS = 120;

function parseDay(iso: string): number {
  const ms = Date.parse(`${iso}T00:00:00Z`);
  if (Number.isNaN(ms)) throw new Error(`invalid date: ${iso}`);
  return ms;
}

/// 含首尾的天数：7-08..7-10 是 3 天，不是 2 天。
export function inclusiveDays(from: string, to: string): number {
  const a = parseDay(from);
  const b = parseDay(to);
  if (a > b) throw new Error(`from (${from}) is after to (${to})`);
  return Math.round((b - a) / DAY_MS) + 1;
}

/// 每个粒度的开放条件，都由「柱子数 ≤ MAX_BARS」推导，而不是拍脑袋定的：
///   hour  : days ≤ 2    → ≤ 48 根
///   day   : days ≤ 120  → ≤ 120 根
///   week  : days ≤ 840  → ≤ 120 根；下限 7 天，否则只有 1 根柱子
///   month : days ≥ 91   → 首末相差 ≥ 90 天（含首尾即 91 天）；上限交给 MAX_BARS 兜底
///
/// 上限与下限必须让任意范围至少剩一个粒度，否则用户会看到一个空的粒度选择器。
/// `always offers at least one granularity` 与 `barCount ≤ MAX_BARS` 两条测试
/// 从两侧把这张表夹死：放宽任何一条，另一条就红。
export function allowedGranularities(from: string, to: string): Granularity[] {
  const days = inclusiveDays(from, to);
  const out: Granularity[] = [];
  if (days <= 2) out.push('hour');
  if (days <= MAX_BARS) out.push('day');
  if (days >= 7 && Math.ceil(days / 7) <= MAX_BARS) out.push('week');
  if (days >= 91) out.push('month');
  return out;
}

export function isAllowed(from: string, to: string, g: Granularity): boolean {
  return allowedGranularities(from, to).includes(g);
}

export function barCount(from: string, to: string, g: Granularity): number {
  const days = inclusiveDays(from, to);
  switch (g) {
    case 'hour': return days * 24;
    case 'day': return days;
    case 'week': return Math.ceil(days / 7);
    case 'month': return Math.ceil(days / 30);
  }
}
