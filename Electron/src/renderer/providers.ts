export interface ProviderPresentation {
  id: string;
  label: string;
  color: string;
}

/// 本地 agent 的展示元数据单一真相源。设置里的别名只覆盖 label，不复制颜色/排序。
export const PROVIDERS: readonly ProviderPresentation[] = [
  { id: 'claude-code', label: 'Claude Code', color: 'var(--s1)' },
  { id: 'codex', label: 'Codex CLI', color: 'var(--s2)' },
  { id: 'omp', label: 'OMP', color: 'var(--s3)' },
  { id: 'opencode', label: 'OpenCode', color: 'var(--s4)' },
  { id: 'reasonix', label: 'Reasonix', color: 'var(--s5)' },
  { id: 'grok', label: 'Grok Build', color: 'var(--s6)' },
  { id: 'dsh', label: 'DeepSeek Harness', color: 'var(--s11)' },
  { id: 'qwen-code', label: '千问 Code', color: 'var(--s7)' },
  { id: 'qoder-cli', label: 'Qoder CLI', color: 'var(--s8)' },
  { id: 'qoder-desktop', label: 'Qoder Desktop', color: 'var(--s9)' },
  { id: 'workbuddy', label: 'WorkBuddy', color: 'var(--s10)' },
  { id: 'antigravity-cli', label: 'Antigravity CLI', color: 'var(--s12)' },
  { id: 'gemini-cli', label: 'Gemini CLI', color: 'var(--s13)' }
] as const;

export const OTHER_PROVIDER = { id: '__other', label: '其他', color: 'var(--muted)' } as const;

const byId = new Map(PROVIDERS.map((provider) => [provider.id, provider]));

export function providerLabel(id: string | null, aliases: Record<string, string> = {}): string {
  if (id === null) return '混合';
  return aliases[id] ?? byId.get(id)?.label ?? id;
}

export function providerColor(id: string): string {
  return byId.get(id)?.color ?? OTHER_PROVIDER.color;
}
