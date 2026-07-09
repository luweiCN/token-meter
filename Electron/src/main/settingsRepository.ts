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

const LOCAL_AGENT_KIND_ALLOWED: Record<string, true> = {
  claudeCode: true,
  codex: true,
  opencode: true,
  omp: true
};


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

  update(patch: unknown, expectedVersion: number) {
    const validatedPatch = validateSettingsPatch(patch);
    if (!hasPatchChanges(validatedPatch)) {
      throw new Error('settings patch must change at least one setting');
    }

    const transaction = this.db.transaction(() => {
      const current = this.get();
      if (current.version !== expectedVersion) {
        throw new Error(`stale settings version: expected ${expectedVersion}, actual ${current.version}`);
      }

      const nextVersion = expectedVersion + 1;
      if (validatedPatch.menuBarPrimaryProviderId !== undefined) {
        this.setSetting('menuBar.primaryProviderId', JSON.stringify(validatedPatch.menuBarPrimaryProviderId), 'string', nextVersion);
      }
      if (validatedPatch.autoRefreshSeconds !== undefined) {
        this.setSetting('scan.autoRefreshSeconds', String(validatedPatch.autoRefreshSeconds), 'int', nextVersion);
      }
      if (validatedPatch.enabledAgentKinds !== undefined) {
        this.setSetting('filters.enabledAgentKinds', JSON.stringify(validatedPatch.enabledAgentKinds), 'json', nextVersion);
      }

      return { requestedVersion: nextVersion, status: 'pending' };
    });

    return transaction();
  }

  private settingString(key: string): string | undefined {
    const row = this.settingRow(key);
    if (row === undefined) return undefined;
    if (row.value_type !== 'string') throw new Error(`invalid stored setting type: ${key}`);
    const value = JSON.parse(row.value_json) as unknown;
    if (typeof value !== 'string') throw new Error(`invalid stored setting value: ${key}`);
    return value;
  }

  private settingInt(key: string): number | undefined {
    const row = this.settingRow(key);
    if (row === undefined) return undefined;
    if (row.value_type !== 'int') throw new Error(`invalid stored setting type: ${key}`);
    const value = JSON.parse(row.value_json) as unknown;
    if (!Number.isInteger(value)) throw new Error(`invalid stored setting value: ${key}`);
    return value as number;
  }

  private settingStringArray(key: string): string[] {
    const row = this.settingRow(key);
    if (row === undefined) return [];
    if (row.value_type !== 'json') throw new Error(`invalid stored setting type: ${key}`);
    const value = JSON.parse(row.value_json) as unknown;
    if (!Array.isArray(value) || !value.every((item) => typeof item === 'string')) {
      throw new Error(`invalid string array setting: ${key}`);
    }
    if (key === 'filters.enabledAgentKinds') validateEnabledAgentKinds(value);
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
         ORDER BY menu_rank ASC, provider_id ASC`
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

function validateSettingsPatch(patch: unknown): SettingsPatch {
  if (typeof patch !== 'object' || patch === null || Array.isArray(patch)) {
    throw new Error('settings patch must be an object');
  }

  const candidate = patch as Record<string, unknown>;
  const validated: SettingsPatch = {};
  if ('menuBarPrimaryProviderId' in candidate) {
    if (typeof candidate.menuBarPrimaryProviderId !== 'string') {
      throw new Error('menuBarPrimaryProviderId must be a string');
    }
    validated.menuBarPrimaryProviderId = candidate.menuBarPrimaryProviderId;
  }

  if ('autoRefreshSeconds' in candidate) {
    if (!Number.isInteger(candidate.autoRefreshSeconds) || (candidate.autoRefreshSeconds as number) < 30) {
      throw new Error('autoRefreshSeconds must be an integer >= 30');
    }
    validated.autoRefreshSeconds = candidate.autoRefreshSeconds as number;
  }

  if ('enabledAgentKinds' in candidate) {
    if (!Array.isArray(candidate.enabledAgentKinds) || !candidate.enabledAgentKinds.every((item) => typeof item === 'string')) {
      throw new Error('enabledAgentKinds must be an array of strings');
    }
    validateEnabledAgentKinds(candidate.enabledAgentKinds);
    validated.enabledAgentKinds = candidate.enabledAgentKinds;
  }

  return validated;
}

function validateEnabledAgentKinds(values: string[]) {
  const unsupported = values.find((value) => LOCAL_AGENT_KIND_ALLOWED[value] !== true);
  if (unsupported !== undefined) {
    throw new Error(`enabledAgentKinds contains unsupported agent kind: ${unsupported}`);
  }
}

function hasPatchChanges(patch: SettingsPatch) {
  return (
    patch.menuBarPrimaryProviderId !== undefined ||
    patch.autoRefreshSeconds !== undefined ||
    patch.enabledAgentKinds !== undefined
  );
}
