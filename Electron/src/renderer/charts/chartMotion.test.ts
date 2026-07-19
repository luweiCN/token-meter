import { describe, expect, it } from 'vitest';

import { chartAnimationDelay } from './chartMotion.js';

describe('chartAnimationDelay', () => {
  it('stagger starts quickly and caps long charts at 80ms', () => {
    expect(chartAnimationDelay(0)).toBe('0ms');
    expect(chartAnimationDelay(5)).toBe('40ms');
    expect(chartAnimationDelay(30)).toBe('80ms');
  });
});
