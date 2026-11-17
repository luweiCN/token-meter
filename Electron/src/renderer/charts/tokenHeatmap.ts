import definitions from '../../../../Sources/TokenMeterApp/Resources/token-heatmap-bands.json';

export type TokenHeatmapBand = Readonly<(typeof definitions)[number] & {
  level: number;
  rangeLabel: string;
  cssColor: string;
}>;

// 与菜单栏直接读取同一份定义；区间文案和主题色随定义派生。
export const TOKEN_HEATMAP_BANDS: readonly TokenHeatmapBand[] = definitions.map((definition, level) => {
  const next = definitions[level + 1];
  const lower = `${definition.minimumTokens / 100_000_000}亿`;
  const rangeLabel = level === 0 ? '0 Token'
    : !next ? `${lower}及以上 Token`
    : level === 1 ? `非零，不足${next.minimumTokens / 100_000_000}亿 Token`
    : `${lower}至不足${next.minimumTokens / 100_000_000}亿 Token`;
  return {
    ...definition,
    level,
    rangeLabel,
    cssColor: `light-dark(${definition.light}, ${definition.dark})`,
  };
});

const descendingBands = [...TOKEN_HEATMAP_BANDS].reverse();

export function tokenHeatmapBand(value: number): TokenHeatmapBand {
  const tokens = Number.isFinite(value) ? Math.max(0, value) : 0;
  const band = descendingBands.find(candidate => tokens >= candidate.minimumTokens);
  if (!band) throw new Error('Token heatmap configuration must include a zero band');
  return band;
}
