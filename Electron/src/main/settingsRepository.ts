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
  /// 额度用量告警阈值（usedPercent 达到即通知）。0 = 关闭，有效值 50~100。
  quotaUsedThresholdPercent: number;
}

export interface SettingsPatch {
  menuBarPrimaryProviderId?: string;
  autoRefreshSeconds?: number;
  enabledAgentKinds?: string[];
  /// providerId → 显示名；空串表示清除自定义、回落到默认名。
  providerDisplayNames?: Record<string, string>;
  /// providerId → 启停。关 = 菜单栏弹窗隐藏该供应商且不再刷新其额度。
  providerEnabled?: Record<string, boolean>;
  /// 0 = 关闭告警，50~100 = 用量达该百分比时通知（Swift 侧刷新额度时检测）。
  quotaUsedThresholdPercent?: number;
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
      providerOverrides: this.providerOverrides(),
      quotaUsedThresholdPercent: this.settingInt('notifications.quotaUsedThresholdPercent') ?? 0
    };
  }

  update(patch: unknown, expectedVersion: number) {
    const validatedPatch = validateSettingsPatch(patch);
    if (!hasPatchChanges(validatedPatch)) {
      throw new Error('settings patch must change at least one setting');
    }

    // immediate：开局即取写锁、等待遵循 busy_timeout。默认的 deferred 事务
    // 先读后写，中途升级写锁撞上 Swift 的写事务（每 60s 的扫描落库）时
    // SQLite 直接报 BUSY 不等待——「database is locked」正是这么来的。
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
      if (validatedPatch.quotaUsedThresholdPercent !== undefined) {
        this.setSetting('notifications.quotaUsedThresholdPercent', String(validatedPatch.quotaUsedThresholdPercent), 'int', nextVersion);
      }
      if (validatedPatch.providerDisplayNames !== undefined) {
        const upsert = this.db.prepare(
          `INSERT INTO provider_config_overrides (provider_id, display_name, updated_at)
           VALUES (?, ?, datetime('now'))
           ON CONFLICT(provider_id) DO UPDATE SET display_name = excluded.display_name, updated_at = excluded.updated_at`
        );
        for (const [providerId, displayName] of Object.entries(validatedPatch.providerDisplayNames)) {
          const trimmed = displayName.trim();
          upsert.run(providerId, trimmed === '' ? null : trimmed);
        }
      }
      if (validatedPatch.providerEnabled !== undefined) {
        const upsert = this.db.prepare(
          `INSERT INTO provider_config_overrides (provider_id, enabled, updated_at)
           VALUES (?, ?, datetime('now'))
           ON CONFLICT(provider_id) DO UPDATE SET enabled = excluded.enabled, updated_at = excluded.updated_at`
        );
        for (const [providerId, enabled] of Object.entries(validatedPatch.providerEnabled)) {
          upsert.run(providerId, enabled ? 1 : 0);
        }
      }
      if (validatedPatch.providerDisplayNames !== undefined || validatedPatch.providerEnabled !== undefined) {
        // overrides 不在 settings 表里，写一个哨兵键推进 version——否则乐观锁
        // 版本不前进，Swift 端 settingsChanged(version) 的对账会判为落后而失败。
        this.setSetting('providers.overridesUpdatedAt', JSON.stringify(new Date().toISOString()), 'string', nextVersion);
      }

      return { requestedVersion: nextVersion, status: 'pending' };
    });

    return transaction.immediate();
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

  if ('providerDisplayNames' in candidate) {
    const names = candidate.providerDisplayNames;
    if (typeof names !== 'object' || names === null || Array.isArray(names)) {
      throw new Error('providerDisplayNames must be an object');
    }
    for (const [providerId, displayName] of Object.entries(names)) {
      if (typeof displayName !== 'string' || displayName.length > 60) {
        throw new Error(`invalid display name for provider: ${providerId}`);
      }
    }
    validated.providerDisplayNames = names as Record<string, string>;
  }

  if ('enabledAgentKinds' in candidate) {
    if (!Array.isArray(candidate.enabledAgentKinds) || !candidate.enabledAgentKinds.every((item) => typeof item === 'string')) {
      throw new Error('enabledAgentKinds must be an array of strings');
    }
    validateEnabledAgentKinds(candidate.enabledAgentKinds);
    validated.enabledAgentKinds = candidate.enabledAgentKinds;
  }

  if ('quotaUsedThresholdPercent' in candidate) {
    const value = candidate.quotaUsedThresholdPercent;
    if (!Number.isInteger(value) || (value !== 0 && ((value as number) < 50 || (value as number) > 100))) {
      throw new Error('quotaUsedThresholdPercent must be 0 (off) or an integer between 50 and 100');
    }
    validated.quotaUsedThresholdPercent = value as number;
  }

  if ('providerEnabled' in candidate) {
    const entries = candidate.providerEnabled;
    if (typeof entries !== 'object' || entries === null || Array.isArray(entries)) {
      throw new Error('providerEnabled must be an object');
    }
    for (const [providerId, enabled] of Object.entries(entries)) {
      if (typeof enabled !== 'boolean') {
        throw new Error(`invalid enabled flag for provider: ${providerId}`);
      }
    }
    validated.providerEnabled = entries as Record<string, boolean>;
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
    patch.enabledAgentKinds !== undefined ||
    patch.providerDisplayNames !== undefined ||
    patch.providerEnabled !== undefined ||
    patch.quotaUsedThresholdPercent !== undefined
  );
}
