import type { DayModelRow, DayProjectRow, OverviewPayload, SubagentRow } from '../main/overviewRepository.js';

export type { OverviewPayload, OverviewReady, OverviewEmpty } from '../main/overviewRepository.js';
export type {
  OverviewKpis,
  TrendBucket,
  AgentTrendRow,
  AgentTrendSeries,
  HeatmapDay,
  ModelRank,
  ActivityRow,
  SubagentRow,
  DayModelRow,
  DayProjectRow
} from '../main/overviewRepository.js';

/// Swift 全量重扫的流式进度（index:scanProgress）。字段与 ipc.test.ts 的 fixture 一致。
export interface ScanProgress {
  kind: string;
  filesTotal: number;
  filesDone: number;
  bytesTotal: number;
  bytesDone: number;
  currentRoot: string;
}

export interface ProviderConfigOverride {
  providerId: string;
  enabled?: boolean;
  displayName?: string;
  menuRank?: number;
  showInMenuBar?: boolean;
  showInCharts?: boolean;
  menubarGlyphWindow?: MenubarWindowChoice;
  menubarNumberWindow?: MenubarWindowChoice;
}

/// 菜单栏样式族（与主进程 settingsRepository / Swift MenuBarStyleId 同名单；
/// renderer 不 import main 模块，此处独立导出一份常量供画廊等使用）。
export const MENUBAR_STYLE_IDS = [
  'rings', 'vbars', 'hbar', 'digits', 'dots', 'caps', 'ticks', 'ring1',
  'grid', 'sentinel', 'monogram', 'strip', 'tagnum', 'deck2', 'ringdeck', 'barsdeck'
] as const;
export type MenubarStyleId = (typeof MENUBAR_STYLE_IDS)[number];
export type MenubarWindowChoice = 'short' | 'long' | 'both';
export type MenubarUsageTail = 'off' | 'tok' | 'cost';
export type MenubarWindowOrder = 'longFirst' | 'shortFirst';

export interface MenubarAppearance {
  style: MenubarStyleId;
  showName: boolean;
  showGlyph: boolean;
  showNumber: boolean;
  usage: MenubarUsageTail;
  windowOrder: MenubarWindowOrder;
}

export interface SettingsSnapshot {
  version: number;
  menuBarPrimaryProviderId?: string;
  autoRefreshSeconds: number;
  enabledAgentKinds: string[];
  providerOverrides: ProviderConfigOverride[];
  /// 额度用量告警阈值（usedPercent 达到即通知）。0 = 关闭，有效值 50~100。
  quotaUsedThresholdPercent: number;
  menubarAppearance: MenubarAppearance;
}

export interface SettingsPatch {
  menuBarPrimaryProviderId?: string;
  autoRefreshSeconds?: number;
  enabledAgentKinds?: string[];
  /// providerId → 显示名；空串表示清除自定义、回落到默认名。
  providerDisplayNames?: Record<string, string>;
  /// 0 = 关闭告警，50~100 = 用量达该百分比时通知。
  quotaUsedThresholdPercent?: number;
  /// providerId → 启停(设置页额度供应商行开关;主进程 settingsRepository 同名字段)。
  providerEnabled?: Record<string, boolean>;
  menubarStyle?: MenubarStyleId;
  menubarShowName?: boolean;
  menubarShowGlyph?: boolean;
  menubarShowNumber?: boolean;
  menubarUsage?: MenubarUsageTail;
  menubarWindowOrder?: MenubarWindowOrder;
  /// providerId → 菜单栏显示（show_in_menu_bar；独立于 enabled 的数据启停）。
  providerMenubarVisible?: Record<string, boolean>;
  providerGlyphWindow?: Record<string, MenubarWindowChoice>;
  providerNumberWindow?: Record<string, MenubarWindowChoice>;
}

export const MENUBAR_APPEARANCE_DEFAULT: MenubarAppearance = {
  style: 'rings',
  showName: true,
  showGlyph: true,
  showNumber: true,
  usage: 'tok',
  windowOrder: 'longFirst'
};

/// macOS 通知授权状态（Swift UNUserNotificationCenter 经 IPC 转发）。
export type NotificationAuthState = 'authorized' | 'denied' | 'notDetermined' | 'unknown';

/// agent CLI 检测结果（Swift AgentBinaryDetector 经 IPC 转发）。
export interface AgentBinaryStatus {
  kind: string;
  found: boolean;
  path?: string | null;
  version?: string | null;
}

/// hooks 会话事件的细节转发（session:stateChanged）：renderer 据此局部翻转卡片状态。
export interface SessionStateEvent {
  sourceKind: string;
  sessionKey: string;
  event: 'start' | 'heartbeat' | 'blocked' | 'stop';
}

export interface SettingsApplyRequest {
  requestedVersion: number;
  status: 'pending' | 'applied' | 'failed';
  error?: {
    requestedVersion: number;
    message: string;
  };
}

export interface DashboardModelBreakdownRow {
  modelName: string;
  sessionsCount: number;
  tokensTotal: number;
  costUsdMicros: number;
}

export interface DashboardProviderBreakdownRow {
  providerId: string;
  sessionsCount: number;
  tokensTotal: number;
}

export interface DashboardDailyTrendRow {
  usageDate: string;
  tokensTotal: number;
  sessionsCount: number;
}

export interface DashboardOverview {
  sessionCount: number;
  totalTokens: number;
  activeModelCount: number;
  totalCostUsdMicros: number;
  costUnknownEvents: number;
  modelBreakdown: DashboardModelBreakdownRow[];
  providerBreakdown: DashboardProviderBreakdownRow[];
  dailyTrend: DashboardDailyTrendRow[];
}


export interface SessionsFilter {
  limit?: number;
  offset?: number;
  providerId?: string;
  /// 多选项目筛选；空数组或缺省 = 不筛选。
  projectIds?: number[];
  /// 本地日范围（闭区间）：范围内有活动的会话。
  dateFrom?: string;
  dateTo?: string;
  /// 标题 / 主模型子串搜索。
  search?: string;
  sortBy?: 'tokens' | 'cost' | 'start';
  sortDir?: 'asc' | 'desc';
}

/// 模型维度筛选(与主进程 modelsRepository.ModelsFilter 同形)。
/// 时间点是毫秒精度的闭区间——「额度刷新时刻 → 周期结束」的统计场景。
export interface ModelsFilter {
  fromEpochMs?: number;
  toEpochMs?: number;
  search?: string;
  sortBy?: 'tokens' | 'cost' | 'events' | 'lastUsed';
  sortDir?: 'asc' | 'desc';
}

/// 模型维度一行(与主进程 modelsRepository.ModelItem 同形)。
export interface ModelUsageItem {
  model: string;
  tokensTotal: number;
  costUsdMicros: number;
  costUnknownEvents: number;
  eventsCount: number;
  sessionsCount: number;
  agents: string[];
  firstUsedEpochMs: number;
  lastUsedEpochMs: number;
}

export interface ModelsQueryResult {
  items: ModelUsageItem[];
}

/// 会话列表一行：只列主会话，token/成本含子代理合计（与总览口径一致）。
export interface SessionItem {
  id: number;
  sessionKey: string;
  sourceKind: string;
  providerId: string | null;
  projectId: number | null;
  projectDisplayName: string | null;
  modelName: string | null;
  title: string | null;
  firstEventEpochMs: number;
  lastEventEpochMs: number;
  tokensTotal: number;
  costUsdMicros: number;
  costUnknownEvents: number;
  /// 主会话自己的 usage 事件数（不含子代理会话的）。
  eventsCount: number;
  subagentCount: number;
}

export interface SessionQueryResult {
  items: SessionItem[];
  total: number;
}

export interface SessionProjectOption {
  id: number;
  displayName: string;
  sessionsCount: number;
}

/// 项目卡片（view-projects）。成本/token 从 daily_rollup 按项目聚合。
export interface ProjectCard {
  id: number;
  displayName: string;
  pathLabel: string;
  sessionsCount: number;
  costUsdMicros: number;
  costUnknownEvents: number;
  tokensTotal: number;
  /// 近 14 天每日花费（USD micros），日对齐补零。
  spark: number[];
  lastActiveDate: string | null;
}

export interface ProjectDetail {
  id: number;
  displayName: string;
  pathLabel: string;
  sessionsCount: number;
  activeDays: number;
  lastActiveDate: string | null;
  costUsdMicros: number;
  costUnknownEvents: number;
  tokensTotal: number;
  dailyCost: Array<{ date: string; costUsdMicros: number }>;
  models: Array<{ model: string; tokens: number; costUsdMicros: number }>;
  agents: Array<{ providerId: string; tokens: number; costUsdMicros: number }>;
}

export interface ScanRootSummary {
  id: number;
  kind: string;
  rootPathLabel: string;
  displayName: string;
  enabled: boolean;
  scanMode: string;
  lastScanStartedAt: string | null;
  lastScanFinishedAt: string | null;
  lastSuccessfulCursor: string | null;
  lastError: string | null;
  /// 与主进程 indexStatusRepository.ScanRoot 同形:三个计数都是非空(coalesce 0)。
  fileCount: number;
  totalSizeBytes: number;
  eventsCount: number;
}

export interface ScanRunSummary {
  id: number;
  scanRootId: number | null;
  runKind: string;
  startedAt: string;
  finishedAt: string | null;
  status: string;
  filesSeen: number;
  filesChanged: number;
  filesDeleted: number;
  sessionsAdded: number;
  sessionsUpdated: number;
  sessionsDeleted: number;
  usageRowsAdded: number;
  bytesRead: number;
  cursorBefore: string | null;
  cursorAfter: string | null;
  errorSummary: string | null;
}

export interface FailedFileSummary {
  id: number;
  scanRootId: number;
  relativePath: string;
  fileType: string;
  parseError: string | null;
  updatedAt: string;
}

export interface IndexStatusResult {
  runs: ScanRunSummary[];
  roots: ScanRootSummary[];
  failedFiles: FailedFileSummary[];
}

declare global {
  interface Window {
    tokenMeter: {
      settings: {
        get(): Promise<SettingsSnapshot>;
        update(patch: SettingsPatch, expectedVersion: number): Promise<SettingsApplyRequest>;
      };
      dashboard: {
        queryOverview(): Promise<DashboardOverview>;
      };
      overview: {
        query(): Promise<OverviewPayload>;
        subagentBreakdown(sessionId: number): Promise<SubagentRow[]>;
        dayModelBreakdown(date: string): Promise<DayModelRow[]>;
        dayProjectBreakdown(date: string): Promise<DayProjectRow[]>;
        onInvalidate(callback: () => void): () => void;
        onSessionEvent(callback: (event: SessionStateEvent) => void): () => void;
      };
      sessions: {
        query(filter: SessionsFilter): Promise<SessionQueryResult>;
        projects(): Promise<SessionProjectOption[]>;
      };
      models: {
        query(filter: ModelsFilter): Promise<ModelsQueryResult>;
      };
      projects: {
        list(): Promise<ProjectCard[]>;
        detail(projectId: number): Promise<ProjectDetail | null>;
      };
      index: {
        status(): Promise<IndexStatusResult>;
        setRootEnabled(id: number, enabled: boolean): Promise<void>;
        startFullReindex(rootId?: string): Promise<unknown>;
        onScanProgress(callback: (progress: ScanProgress) => void): () => void;
      };
      agents: {
        /// null = 检测不可用（菜单栏应用未运行）。
        detect(): Promise<AgentBinaryStatus[] | null>;
      };
      credentials: {
        /// 存/清应用内 API Key（token 空串 = 清除）。返回操作后是否已配置。
        set(providerId: string, token: string): Promise<boolean>;
        /// null = 状态不可查（菜单栏应用未运行）。
        state(providerId: string): Promise<boolean | null>;
      };
      notifications: {
        state(): Promise<NotificationAuthState>;
        requestAuthorization(): Promise<NotificationAuthState>;
      };
      windowControls: {
        setButtonsVisible(visible: boolean): Promise<void>;
      };
    };
  }
}
