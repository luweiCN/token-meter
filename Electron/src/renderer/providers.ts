export interface ProviderPresentation {
  id: string;
  label: string;
  color: string;
}

/// 本地 agent 的展示元数据单一真相源。设置里的别名只覆盖 label，不复制颜色/排序。
export const PROVIDERS: readonly ProviderPresentation[] = [
  { id: 'openclaw', label: 'OpenClaw', color: 'var(--s3)' },
  { id: 'hermes', label: 'Hermes Agent', color: 'var(--s4)' },
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

/// 供应商额度接入（OpenDesign 稿 B 区）。keyed = 支持应用内填 API Key（存钥匙串，
/// 优先于环境变量）；login = 在设置中登录 OpenCode 账户。
export const QUOTA_PROVIDERS: Array<{ id: string; name: string; shortName?: string; pill: string; how: string; src: string; keyed?: boolean; login?: boolean }> = [
  { id: 'codex', name: 'Codex', pill: '自动接入', how: '自动读取本机登录凭证', src: '~/.codex/auth.json' },
  { id: 'claude-code', name: 'Claude Code', pill: '自动接入', how: '自动读取本机登录凭证', src: '钥匙串 · Claude Code-credentials' },
  { id: 'antigravity', name: 'Antigravity', shortName: 'AGY', pill: 'CLI 接入', how: '自动查询已登录账号的 Gemini 和 Claude/GPT 额度', src: 'Antigravity CLI · /usage' },
  { id: 'zhipu', name: '智谱 GLM', pill: '环境变量', how: 'API Key · 应用内填写或读取环境变量', src: 'ZHIPU_API_KEY', keyed: true },
  { id: 'opencode-go', name: 'OpenCode Go', pill: '自动接入', how: '通过 OpenCode 账户登录或 Go API Key 读取额度', src: '~/.config/opencode/opencode-quota/opencode-go.json', login: true },
  { id: 'command-code', name: 'Command Code', pill: 'API Key', how: 'Studio API Key · 不依赖 Command Code CLI', src: 'COMMAND_CODE_API_KEY · ~/.commandcode/auth.json', keyed: true },
  { id: 'grok', name: 'Grok Build', pill: '自动接入', how: '自动读取本机登录凭证', src: '~/.grok/auth.json' },
  { id: 'qoder', name: 'Qoder', pill: '自动接入', how: '通过本机 Qoder CLI 读取 Credits 额度', src: '~/.qoder-cn/bin/qoderclicn' }
];

export function quotaProviderLabel(id: string, displayName?: string): string {
  const provider = QUOTA_PROVIDERS.find(p => p.id === id);
  if (!provider) return displayName || providerLabel(id);
  return displayName && displayName !== provider.name ? displayName : provider.shortName ?? provider.name;
}
