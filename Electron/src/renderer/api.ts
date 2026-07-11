import type { OverviewPayload, SubagentRow } from '../main/overviewRepository.js';

export type { OverviewPayload, OverviewReady, OverviewEmpty } from '../main/overviewRepository.js';
export type {
  OverviewKpis,
  TrendBucket,
  HeatmapDay,
  ModelRank,
  ActivityRow,
  SubagentRow
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
}

export interface SettingsSnapshot {
  version: number;
  menuBarPrimaryProviderId?: string;
  autoRefreshSeconds: number;
  enabledAgentKinds: string[];
  providerOverrides: ProviderConfigOverride[];
}

export interface SettingsPatch {
  menuBarPrimaryProviderId?: string;
  autoRefreshSeconds?: number;
  enabledAgentKinds?: string[];
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
}

export interface SessionQueryResult {
  items: unknown[];
  total: number;
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
        onInvalidate(callback: () => void): () => void;
      };
      sessions: {
        query(filter: SessionsFilter): Promise<SessionQueryResult>;
      };
      index: {
        status(): Promise<IndexStatusResult>;
        startFullReindex(rootId?: string): Promise<unknown>;
        onScanProgress(callback: (progress: ScanProgress) => void): () => void;
      };
    };
  }
}
