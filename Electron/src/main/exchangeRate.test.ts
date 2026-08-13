import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

import { FALLBACK_USD_TO_CNY, readUsdToCnyRate } from './exchangeRate.js';

function tempHome() {
  return mkdtempSync(join(tmpdir(), 'tokenmeter-fx-'));
}

describe('readUsdToCnyRate', () => {
  it('falls back to the bundled constant when cache is missing', () => {
    expect(readUsdToCnyRate(tempHome())).toBe(FALLBACK_USD_TO_CNY);
  });

  it('reads a valid Swift-written cache file', () => {
    const home = tempHome();
    mkdirSync(join(home, '.token-meter'), { recursive: true });
    writeFileSync(
      join(home, '.token-meter', 'exchange-rate.json'),
      JSON.stringify({ usdToCny: 6.75, fetchedAt: '2026-08-13T00:00:00Z' })
    );
    expect(readUsdToCnyRate(home)).toBe(6.75);
  });

  it('falls back when the cache file is corrupt or invalid', () => {
    const home = tempHome();
    mkdirSync(join(home, '.token-meter'), { recursive: true });
    writeFileSync(join(home, '.token-meter', 'exchange-rate.json'), '{broken');
    expect(readUsdToCnyRate(home)).toBe(FALLBACK_USD_TO_CNY);
  });
});
