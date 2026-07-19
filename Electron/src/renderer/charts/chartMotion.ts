const STAGGER_STEP_MS = 8;
const MAX_STAGGER_STEPS = 10;

/// 图表元素的错峰延迟：最多延后 80ms，避免长趋势图把整段进场拖得过久。
export function chartAnimationDelay(index: number): string {
  return `${Math.min(index, MAX_STAGGER_STEPS) * STAGGER_STEP_MS}ms`;
}
