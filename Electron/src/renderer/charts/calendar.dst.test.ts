// 这个文件必须在一个【有夏令时】的时区里跑，否则它测不到任何东西。
// 本机是 UTC+8（无 DST），Set 尺寸断言会恒绿。
//
// TZ 必须在任何 Date 被构造之前设置，所以它在 import 之前（与
// localBucketKeys.dst.test.ts 同构）。第一条测试断言 TZ 真的生效了。
process.env.TZ = 'America/New_York';

import { describe, it, expect } from 'vitest';
import { buildCalendarGrid } from './calendar.js';

describe('buildCalendarGrid under daylight saving time', () => {
  it('actually runs in a DST timezone (otherwise the rest of this file proves nothing)', () => {
    const summer = new Date(2026, 6, 1).getTimezoneOffset();  // EDT = 240
    const winter = new Date(2026, 11, 1).getTimezoneOffset(); // EST = 300
    expect(summer).not.toBe(winter);
  });

  it('yields exactly N distinct days across two DST boundaries, none dropped or duplicated', () => {
    // 371 天窗口（2025-07-05..2026-07-10）跨越 2025 秋季与 2026 春季两个 DST 切换日。
    // 实测：日历步进得 371 天；`+= 86_400_000` 只得 370 天（丢了一天）。
    // 所以这两条断言在 DST 时区里对 epoch 步进有真牙齿。
    const dates = buildCalendarGrid('2026-07-10', 371).flat()
      .map(d => d.date).filter((d): d is string => d !== null);
    expect(dates).toHaveLength(371);
    expect(new Set(dates).size).toBe(371);
  });

  it('still ends on the requested last day in a DST timezone', () => {
    // 末列会补到周六，数组末尾可能是占位格——过滤掉再看最后一个真实日期。
    const real = buildCalendarGrid('2026-07-10', 371).flat().filter(c => c.date !== null);
    expect(real[real.length - 1].date).toBe('2026-07-10');
  });
});
