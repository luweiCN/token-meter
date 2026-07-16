/// 概览页各处共用的格式化。放一处，避免 KPI、排行、会话列表各写一份漂移。

export function formatCount(value: number): string {
  return new Intl.NumberFormat('en-US').format(value);
}

/// dailyScale：单日范围的数字永远不升到 B——十亿级写成「2398.5M」，每涨一百万
/// 都看得见（1 位小数的 B 会把百万级变化吞掉）。多天聚合（周/月/总计）才用 B。
export function formatTokens(value: number, dailyScale = false): string {
  if (value >= 1_000_000_000) {
    if (!dailyScale) return `${(value / 1_000_000_000).toFixed(2)}B`;
    return `${(value / 1_000_000).toFixed(1)}M`;
  }
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

/// 卡片里的紧凑时长（设计稿风格）：32m / 2h 21m / 3d 2h。
/// 完整中文版（formatDuration）在弹窗等宽裕处继续用。
export function formatDurationShort(ms: number): string {
  const minutes = Math.floor(ms / 60_000);
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ${minutes % 60}m`;
  const days = Math.floor(hours / 24);
  return `${days}d ${hours % 24}h`;
}

/// 目录/文件大小的人类可读形式（设置页 E 区与索引状态页共用）。
export function formatBytes(bytes: number): string {
  if (bytes >= 1024 ** 3) return `${(bytes / 1024 ** 3).toFixed(1)} GB`;
  if (bytes >= 1024 ** 2) return `${(bytes / 1024 ** 2).toFixed(1)} MB`;
  return `${Math.max(1, Math.round(bytes / 1024))} KB`;
}

/// SQLite 的 datetime('now') 存 UTC 但无时区后缀，直接 Date.parse 会按本地时区
/// 解析——UTC+8 下「最近扫描」凭空多出 8 小时（用户实测）。补上 Z 再解析。
export function parseUtcTimestamp(value: string): number {
  const normalized = value.includes('T') ? value : `${value.replace(' ', 'T')}Z`;
  return Date.parse(normalized);
}
