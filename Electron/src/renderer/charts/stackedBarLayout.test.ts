import { describe, it, expect } from 'vitest';
import { layoutStackedBars, SEGMENTS } from './stackedBarLayout.js';

const bars = [
  { bucket: 'a', input: 10, cacheWrite: 0, cacheRead: 20, output: 10 },   // 40
  { bucket: 'b', input: 0, cacheWrite: 0, cacheRead: 0, output: 0 }       // 0
];

describe('layoutStackedBars', () => {
  it('stacks segments bottom-up and never exceeds the plot height', () => {
    const { rects, maxTotal } = layoutStackedBars(bars, { width: 200, height: 100, padding: 0 });
    expect(maxTotal).toBe(40);
    const first = rects.filter(r => r.bucket === 'a');
    // 顺序固定，图例才对得上。bar 'a' 的 cacheWrite=0 不产出 rect，所以出现的段是
    // SEGMENTS 去掉零段后的子序列——断言「出现的段保持 SEGMENTS 的相对顺序」，
    // 而不是 toEqual(SEGMENTS)（那与「零段不产 rect」自相矛盾）。
    const order = first.map(r => r.segment);
    expect(order).toEqual(SEGMENTS.filter(s => order.includes(s)));
    expect(order).toEqual(['input', 'cacheRead', 'output']);
    expect(Math.min(...first.map(r => r.y))).toBeGreaterThanOrEqual(0);
    expect(Math.max(...first.map(r => r.y + r.height))).toBeLessThanOrEqual(100);
  });

  it('emits no rect for a zero segment rather than a zero-height one', () => {
    // 高度为 0 的 <rect> 在某些渲染器上仍会画出 1px 的线
    const { rects } = layoutStackedBars(bars, { width: 200, height: 100, padding: 0 });
    expect(rects.filter(r => r.bucket === 'b')).toEqual([]);
    expect(rects.every(r => r.height > 0)).toBe(true);
  });

  it('survives an all-zero dataset without dividing by zero', () => {
    const { rects, maxTotal } = layoutStackedBars([bars[1]], { width: 200, height: 100, padding: 0 });
    expect(maxTotal).toBe(0);
    expect(rects).toEqual([]);
  });

  it('keeps bars inside the width regardless of count', () => {
    const many = Array.from({ length: 120 }, (_, i) => ({ ...bars[0], bucket: `b${i}` }));
    const { rects } = layoutStackedBars(many, { width: 840, height: 100, padding: 0 });
    expect(Math.max(...rects.map(r => r.x + r.width))).toBeLessThanOrEqual(840);
    expect(rects.every(r => r.width > 0)).toBe(true);
  });

  it('emits one full hover slot per bar, even for an all-zero bar, all inside the width', () => {
    // hover 由一个覆盖整根柱子的透明 <rect> 承接（逐段接会在段间缝隙丢事件）。
    // 这个覆盖层的坐标属于「算坐标」，所以由纯函数产出，组件只负责画。
    const { slots } = layoutStackedBars(bars, { width: 200, height: 100, padding: 0 });
    expect(slots.map(s => s.bucket)).toEqual(['a', 'b']);   // 全零的 'b' 也要能 hover
    expect(slots.every(s => s.width > 0)).toBe(true);
    expect(Math.max(...slots.map(s => s.x + s.width))).toBeLessThanOrEqual(200);
  });
});
