// 这个文件必须在一个【有夏令时】的时区里跑，否则它测不到任何东西。
// 本机是 UTC+8（无 DST），所有断言都会恒绿。
//
// TZ 必须在任何 Date 被构造之前设置，所以它在 import 之前。ESM 的 import 会被提升，
// 但 vitest 为每个测试文件建独立的模块图，而 Node 在首次读取时区时才缓存它——
// 于是这里的赋值仍然生效。若将来失效，第一条测试会立刻变红（它断言 TZ 真的生效了）。
process.env.TZ = 'America/New_York';

import { describe, it, expect } from 'vitest';
import { localBucketKeys } from './overviewRepository.js';

describe('localBucketKeys under daylight saving time', () => {
  it('actually runs in a DST timezone (otherwise the rest of this file proves nothing)', () => {
    const summer = new Date(2026, 6, 1).getTimezoneOffset();  // EDT = 240
    const winter = new Date(2026, 11, 1).getTimezoneOffset(); // EST = 300
    expect(summer).not.toBe(winter);
  });

  it('emits each day exactly once across the autumn DST boundary', () => {
    // 2026-11-01 是美东 DST 结束日：那天有 25 小时。
    // `t += 86_400_000` 会让 11-01 出现两次并多出一个桶。
    const keys = [...localBucketKeys('2026-10-30', '2026-11-03', 'day')];

    expect(keys).toEqual(['2026-10-30', '2026-10-31', '2026-11-01', '2026-11-02', '2026-11-03']);
    expect(new Set(keys).size).toBe(keys.length);
  });

  it('emits each day exactly once across the spring DST boundary', () => {
    // 2026-03-08 只有 23 小时。
    const keys = [...localBucketKeys('2026-03-06', '2026-03-10', 'day')];

    expect(keys).toEqual(['2026-03-06', '2026-03-07', '2026-03-08', '2026-03-09', '2026-03-10']);
    expect(new Set(keys).size).toBe(keys.length);
  });

  it('collapses the repeated local hour rather than emitting a duplicate key', () => {
    // DST 结束那天本地时间 01:00 出现两次。SQL 的 strftime(..., 'localtime') 会把
    // 它们聚成同一个桶，所以这里也必须只产出一个键——否则两侧的桶键对不上。
    const keys = [...localBucketKeys('2026-11-01', '2026-11-01', 'hour')];

    expect(new Set(keys).size).toBe(keys.length);
    expect(keys.filter(k => k.endsWith(' 01'))).toHaveLength(1);
  });

  it('covers a single day with no gaps and no extras', () => {
    expect([...localBucketKeys('2026-07-10', '2026-07-10', 'day')]).toEqual(['2026-07-10']);
    expect([...localBucketKeys('2026-07-10', '2026-07-10', 'hour')]).toHaveLength(24);
  });
});
