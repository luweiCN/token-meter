/// 概览页各处共用的格式化。放一处，避免 KPI、排行、会话列表各写一份漂移。

export function formatCount(value: number): string {
  return new Intl.NumberFormat('en-US').format(value);
}

export function formatTokens(value: number): string {
  if (value >= 1_000_000_000) return `${(value / 1_000_000_000).toFixed(2)}B`;
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(2)}M`;
  if (value >= 1_000) return `${(value / 1_000).toFixed(2)}K`;
  return formatCount(value);
}

/// 成本以微美元存储。成本从 rollup 读出来永远是数字（NULL 已被折成 0），看不出是否完整——
/// 「部分未知」由 costUnknownEvents 单独表达，见 formatUnknownCostNote 与各处调用点。
export function formatUsdMicros(micros: number): string {
  return `$${(micros / 1_000_000).toLocaleString('en-US', {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2
  })}`;
}

/// 每一处展示成本的地方都要能表达「其中若干条事件价格未知」（前置事实）。
export function formatUnknownCostNote(unknownEvents: number): string | null {
  if (unknownEvents <= 0) return null;
  return `${formatCount(unknownEvents)} 条事件价格未知`;
}

export function formatDuration(ms: number): string {
  if (ms < 0) ms = 0;
  const minutes = Math.floor(ms / 60_000);
  if (minutes < 1) return '不到 1 分钟';
  if (minutes < 60) return `${minutes} 分钟`;
  const hours = Math.floor(minutes / 60);
  const rem = minutes % 60;
  return rem === 0 ? `${hours} 小时` : `${hours} 小时 ${rem} 分`;
}

export function formatRelative(msSince: number): string {
  if (msSince < 0) msSince = 0;
  const seconds = Math.floor(msSince / 1000);
  if (seconds < 60) return `${seconds} 秒前`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes} 分钟前`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours} 小时前`;
  const days = Math.floor(hours / 24);
  return `${days} 天前`;
}
