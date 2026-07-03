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

export interface SettingsApplyRequest {
  requestedVersion: number;
  status: 'pending' | 'applied';
}

export interface DashboardOverview {
  providers: unknown[];
  totalTokens: number;
}

export interface DailyUsagePoint {
  usageDate: string;
  tokensTotal: number;
}

export interface SessionQueryResult {
  items: unknown[];
  total: number;
}

export interface IndexStatusResult {
  runs: unknown[];
  roots: unknown[];
}

declare global {
  interface Window {
    tokenMeter: {
      settings: {
        get(): Promise<SettingsSnapshot>;
        update(patch: unknown, expectedVersion: number): Promise<SettingsApplyRequest>;
      };
      dashboard: {
        queryOverview(filter: unknown): Promise<DashboardOverview>;
        queryDailyUsage(filter: unknown): Promise<DailyUsagePoint[]>;
      };
      sessions: {
        query(filter: unknown): Promise<SessionQueryResult>;
      };
      index: {
        status(): Promise<IndexStatusResult>;
        startFullReindex(rootId?: string): Promise<unknown>;
      };
    };
  }
}
