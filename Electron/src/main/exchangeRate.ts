import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

/// 与 Swift ExchangeRateProvider.fallbackRate 同值：外网与缓存都不可用时的一致兜底。
export const FALLBACK_USD_TO_CNY = 6.76;

interface CachedExchangeRate {
  usdToCny: number;
  fetchedAt: string;
}

/// Swift 菜单栏进程每天刷新并把汇率写进 ~/.token-meter/exchange-rate.json；
/// Electron 主进程只读这份缓存。缺文件/损坏/非法值一律回兜底常数。
export function readUsdToCnyRate(home: string = homedir()): number {
  try {
    const raw = readFileSync(join(home, '.token-meter', 'exchange-rate.json'), 'utf8');
    const parsed = JSON.parse(raw) as Partial<CachedExchangeRate>;
    if (typeof parsed.usdToCny === 'number' && Number.isFinite(parsed.usdToCny) && parsed.usdToCny > 0) {
      return parsed.usdToCny;
    }
  } catch {
    // 无缓存/损坏 → 兜底。
  }
  return FALLBACK_USD_TO_CNY;
}
