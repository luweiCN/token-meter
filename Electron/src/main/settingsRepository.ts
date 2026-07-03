import type Database from 'better-sqlite3';

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

interface SettingRow {
  value_json: string;
  value_type: 'string' | 'int' | 'bool' | 'json';
}

interface VersionRow {
  version: number;
}

interface ProviderOverrideRow {
  provider_id: string;
  enabled: 0 | 1 | null;
  display_name: string | null;
  menu_rank: number | null;
  show_in_menu_bar: 0 | 1 | null;
  show_in_charts: 0 | 1 | null;
}

export class SettingsRepository {
  constructor(private readonly db: Database.Database) {}

  get(): SettingsSnapshot {
    const versionRow = this.db.prepare('SELECT coalesce(max(version), 0) AS version FROM settings').get() as VersionRow;
    return {
      version: versionRow.version,
      menuBarPrimaryProviderId: this.settingString('menuBar.primaryProviderId'),
      autoRefreshSeconds: this.settingInt('scan.autoRefreshSeconds') ?? 300,
      enabledAgentKinds: this.settingStringArray('filters.enabledAgentKinds'),
      providerOverrides: this.providerOverrides()
    };
  }

  update(patch: SettingsPatch, expectedVersion: number) {
    if (!hasPatchChanges(patch)) {
      throw new Error('settings patch must change at least one setting');
    }

    const transaction = this.db.transaction(() => {
      const current = this.get();
      if (current.version !== expectedVersion) {
        throw new Error(`stale settings version: expected ${expectedVersion}, actual ${current.version}`);
      }

      const nextVersion = expectedVersion + 1;
      if (patch.menuBarPrimaryProviderId !== undefined) {
        this.setSetting('menuBar.primaryProviderId', JSON.stringify(patch.menuBarPrimaryProviderId), 'string', nextVersion);
      }
      if (patch.autoRefreshSeconds !== undefined) {
        this.setSetting('scan.autoRefreshSeconds', String(patch.autoRefreshSeconds), 'int', nextVersion);
      }
      if (patch.enabledAgentKinds !== undefined) {
        this.setSetting('filters.enabledAgentKinds', JSON.stringify(patch.enabledAgentKinds), 'json', nextVersion);
      }

      return { requestedVersion: nextVersion, status: 'pending' };
    });

    return transaction();
  }

  private settingString(key: string): string | undefined {
    const row = this.settingRow(key);
    if (row === undefined) return undefined;
    return JSON.parse(row.value_json) as string;
  }

  private settingInt(key: string): number | undefined {
    const row = this.settingRow(key);
    if (row === undefined) return undefined;
    return Number(JSON.parse(row.value_json));
  }

  private settingStringArray(key: string): string[] {
    const row = this.settingRow(key);
    if (row === undefined) return [];
    const value = JSON.parse(row.value_json) as unknown;
    if (!Array.isArray(value) || !value.every((item) => typeof item === 'string')) {
      throw new Error(`invalid string array setting: ${key}`);
    }
    return value;
  }

  private settingRow(key: string): SettingRow | undefined {
    return this.db.prepare('SELECT value_json, value_type FROM settings WHERE key = ?').get(key) as SettingRow | undefined;
  }

  private providerOverrides(): ProviderConfigOverride[] {
    const rows = this.db
      .prepare(
        `SELECT provider_id, enabled, display_name, menu_rank, show_in_menu_bar, show_in_charts
         FROM provider_config_overrides
         ORDER BY coalesce(menu_rank, 2147483647), provider_id`
      )
      .all() as ProviderOverrideRow[];

    return rows.map((row) => ({
      providerId: row.provider_id,
      ...(row.enabled === null ? {} : { enabled: row.enabled === 1 }),
      ...(row.display_name === null ? {} : { displayName: row.display_name }),
      ...(row.menu_rank === null ? {} : { menuRank: row.menu_rank }),
      ...(row.show_in_menu_bar === null ? {} : { showInMenuBar: row.show_in_menu_bar === 1 }),
      ...(row.show_in_charts === null ? {} : { showInCharts: row.show_in_charts === 1 })
    }));
  }

  private setSetting(key: string, valueJson: string, valueType: SettingRow['value_type'], version: number) {
    this.db
      .prepare(
        `INSERT INTO settings(key, value_json, value_type, version, updated_by)
         VALUES (?, ?, ?, ?, 'electron')
         ON CONFLICT(key) DO UPDATE SET
           value_json = excluded.value_json,
           value_type = excluded.value_type,
           version = excluded.version,
           updated_at = CURRENT_TIMESTAMP,
           updated_by = excluded.updated_by`
      )
      .run(key, valueJson, valueType, version);
  }
}

function hasPatchChanges(patch: SettingsPatch) {
  return (
    patch.menuBarPrimaryProviderId !== undefined ||
    patch.autoRefreshSeconds !== undefined ||
    patch.enabledAgentKinds !== undefined
  );
}
