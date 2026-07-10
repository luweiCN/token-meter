export const HEATMAP_LEVELS = 5;

/// 把用量映射到 0..HEATMAP_LEVELS-1 的色阶档位。
///
/// 用 log1p 而不是线性：token 用量是长尾分布。本机某天的用量是中位数的几十倍，
/// 线性映射会把 364 天压进最浅的一档、只有 1 天是深色——那张图什么也没说。
/// log1p 保证 0 仍然映射到 0（log1p(0) = 0），不必对零值特判。
export function logBucket(value: number, max: number): number {
  if (max <= 0 || value <= 0) return 0;
  const clamped = Math.min(value, max);
  const ratio = Math.log1p(clamped) / Math.log1p(max);
  return Math.min(HEATMAP_LEVELS - 1, Math.max(0, Math.round(ratio * (HEATMAP_LEVELS - 1))));
}
