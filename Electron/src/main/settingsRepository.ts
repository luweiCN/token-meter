import type Database from 'better-sqlite3';

export const MENUBAR_STYLE_IDS = [
  'rings', 'vbars', 'hbar', 'digits', 'dots', 'caps', 'ticks', 'ring1',
  'grid', 'sentinel', 'monogram', 'strip', 'tagnum', 'deck2', 'ringdeck', 'barsdeck'
] as const;
export type MenubarStyleId = (typeof MENUBAR_STYLE_IDS)[number];
export type MenubarWindowChoice = 'short' | 'long' | 'both';
export type MenubarUsageTail = 'off' | 'tok' | 'cost';
export type MenubarWindowOrder = 'longFirst' | 'shortFirst';

/// 菜单栏外观（样式/元素/今日尾巴/窗口顺序）。Swift 端 MenuBarAppearanceSettings 同构。
export interface MenubarAppearance {
  style: MenubarStyleId;
  showName: boolean;
  showGlyph: boolean;
  showNumber: boolean;
  usage: MenubarUsageTail;
  windowOrder: MenubarWindowOrder;
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
  /// providerId → 启停。关 = 菜单栏弹窗隐藏该供应商且不再刷新其额度。
  providerEnabled?: Record<string, boolean>;
  /// 0 = 关闭告警，50~100 = 用量达该百分比时通知（Swift 侧刷新额度时检测）。
  quotaUsedThresholdPercent?: number;
  menubarStyle?: MenubarStyleId;
  menubarShowName?: boolean;
  menubarShowGlyph?: boolean;
  menubarShowNumber?: boolean;
  menubarUsage?: MenubarUsageTail;
  menubarWindowOrder?: MenubarWindowOrder;
  /// providerId → 菜单栏显示（写 show_in_menu_bar；独立于 enabled 的数据启停）。
  providerMenubarVisible?: Record<string, boolean>;
  providerGlyphWindow?: Record<string, MenubarWindowChoice>;
  providerNumberWindow?: Record<string, MenubarWindowChoice>;
}

const MENUBAR_WINDOW_CHOICES = ['short', 'long', 'both'] as const;
const MENUBAR_USAGE_TAILS = ['off', 'tok', 'cost'] as const;
const MENUBAR_WINDOW_ORDERS = ['longFirst', 'shortFirst'] as const;

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
  menubar_glyph_window: string | null;
  menubar_number_window: string | null;
}

export class SettingsRepository {
  constructor(private readonly db: Database.Database) {
    this.ensureMenubarColumns();
  }

  /// 配置表新增列的幂等迁移（与 Swift TokenMeterDatabaseMigrator.ensureConfigColumns 同款）：
  /// Swift 未升级/未运行时 Electron 也能安全查询。
  private ensureMenubarColumns() {
    const cols = (this.db.prepare('PRAGMA table_info(provider_config_overrides)').all() as Array<{ name: string }>)
      .map((c) => c.name);
    if (!cols.includes('menubar_glyph_window')) {
      this.db.exec(
        "ALTER TABLE provider_config_overrides ADD COLUMN menubar_glyph_window TEXT CHECK (menubar_glyph_window IN ('short','long','both'))"
      );
    }
    if (!cols.includes('menubar_number_window')) {
      this.db.exec(
        "ALTER TABLE provider_config_overrides ADD COLUMN menubar_number_window TEXT CHECK (menubar_number_window IN ('short','long','both'))"
      );
    }
  }

  get(): SettingsSnapshot {
    const versionRow = this.db.prepare('SELECT coalesce(max(version), 0) AS version FROM settings').get() as VersionRow;
    return {
      version: versionRow.version,
      menuBarPrimaryProviderId: this.settingString('menuBar.primaryProviderId'),
      autoRefreshSeconds: this.settingInt('scan.autoRefreshSeconds') ?? 300,
      enabledAgentKinds: this.settingStringArray('filters.enabledAgentKinds'),
      providerOverrides: this.providerOverrides(),
      quotaUsedThresholdPercent: this.settingInt('notifications.quotaUsedThresholdPercent') ?? 0,
      menubarAppearance: {
        style: this.enumSetting('menubar.style', MENUBAR_STYLE_IDS, 'rings'),
        showName: (this.settingInt('menubar.showName') ?? 1) !== 0,
        showGlyph: (this.settingInt('menubar.showGlyph') ?? 1) !== 0,
        showNumber: (this.settingInt('menubar.showNumber') ?? 1) !== 0,
        usage: this.enumSetting('menubar.usage', MENUBAR_USAGE_TAILS, 'tok'),
        windowOrder: this.enumSetting('menubar.windowOrder', MENUBAR_WINDOW_ORDERS, 'longFirst')
      }
    };
  }

  /// 枚举 kv：缺失/坏类型/非法值一律回默认（与 Swift 端同策略，向后兼容）。
  private enumSetting<T extends string>(key: string, allowed: readonly T[], fallback: T): T {
    let raw: string | undefined;
    try {
      raw = this.settingString(key);
    } catch {
      return fallback;
    }
    return raw !== undefined && (allowed as readonly string[]).includes(raw) ? (raw as T) : fallback;
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
      if (validatedPatch.menubarStyle !== undefined) {
        this.setSetting('menubar.style', JSON.stringify(validatedPatch.menubarStyle), 'string', nextVersion);
      }
      if (validatedPatch.menubarShowName !== undefined) {
        this.setSetting('menubar.showName', String(validatedPatch.menubarShowName ? 1 : 0), 'int', nextVersion);
      }
      if (validatedPatch.menubarShowGlyph !== undefined) {
        this.setSetting('menubar.showGlyph', String(validatedPatch.menubarShowGlyph ? 1 : 0), 'int', nextVersion);
      }
      if (validatedPatch.menubarShowNumber !== undefined) {
        this.setSetting('menubar.showNumber', String(validatedPatch.menubarShowNumber ? 1 : 0), 'int', nextVersion);
      }
      if (validatedPatch.menubarUsage !== undefined) {
        this.setSetting('menubar.usage', JSON.stringify(validatedPatch.menubarUsage), 'string', nextVersion);
      }
      if (validatedPatch.menubarWindowOrder !== undefined) {
        this.setSetting('menubar.windowOrder', JSON.stringify(validatedPatch.menubarWindowOrder), 'string', nextVersion);
      }
      if (validatedPatch.providerMenubarVisible !== undefined) {
        const upsert = this.db.prepare(
          `INSERT INTO provider_config_overrides (provider_id, show_in_menu_bar, updated_at)
           VALUES (?, ?, datetime('now'))
           ON CONFLICT(provider_id) DO UPDATE SET show_in_menu_bar = excluded.show_in_menu_bar, updated_at = excluded.updated_at`
        );
        for (const [providerId, visible] of Object.entries(validatedPatch.providerMenubarVisible)) {
          upsert.run(providerId, visible ? 1 : 0);
        }
      }
      if (validatedPatch.providerGlyphWindow !== undefined) {
        const upsert = this.db.prepare(
          `INSERT INTO provider_config_overrides (provider_id, menubar_glyph_window, updated_at)
           VALUES (?, ?, datetime('now'))
           ON CONFLICT(provider_id) DO UPDATE SET menubar_glyph_window = excluded.menubar_glyph_window, updated_at = excluded.updated_at`
        );
        for (const [providerId, choice] of Object.entries(validatedPatch.providerGlyphWindow)) {
          upsert.run(providerId, choice);
        }
      }
      if (validatedPatch.providerNumberWindow !== undefined) {
        const upsert = this.db.prepare(
          `INSERT INTO provider_config_overrides (provider_id, menubar_number_window, updated_at)
           VALUES (?, ?, datetime('now'))
           ON CONFLICT(provider_id) DO UPDATE SET menubar_number_window = excluded.menubar_number_window, updated_at = excluded.updated_at`
        );
        for (const [providerId, choice] of Object.entries(validatedPatch.providerNumberWindow)) {
          upsert.run(providerId, choice);
        }
      }
      if (
        validatedPatch.providerDisplayNames !== undefined ||
        validatedPatch.providerEnabled !== undefined ||
        validatedPatch.providerMenubarVisible !== undefined ||
        validatedPatch.providerGlyphWindow !== undefined ||
        validatedPatch.providerNumberWindow !== undefined
      ) {
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
        `SELECT provider_id, enabled, display_name, menu_rank, show_in_menu_bar, show_in_charts,
                menubar_glyph_window, menubar_number_window
         FROM provider_config_overrides
         ORDER BY menu_rank ASC, provider_id ASC`
      )
      .all() as ProviderOverrideRow[];

    const windowChoice = (value: string | null): MenubarWindowChoice | undefined =>
      value !== null && (MENUBAR_WINDOW_CHOICES as readonly string[]).includes(value)
        ? (value as MenubarWindowChoice)
        : undefined;

    return rows.map((row) => ({
      providerId: row.provider_id,
      ...(row.enabled === null ? {} : { enabled: row.enabled === 1 }),
      ...(row.display_name === null ? {} : { displayName: row.display_name }),
      ...(row.menu_rank === null ? {} : { menuRank: row.menu_rank }),
      ...(row.show_in_menu_bar === null ? {} : { showInMenuBar: row.show_in_menu_bar === 1 }),
      ...(row.show_in_charts === null ? {} : { showInCharts: row.show_in_charts === 1 }),
      ...(windowChoice(row.menubar_glyph_window) === undefined
        ? {}
        : { menubarGlyphWindow: windowChoice(row.menubar_glyph_window) }),
      ...(windowChoice(row.menubar_number_window) === undefined
        ? {}
        : { menubarNumberWindow: windowChoice(row.menubar_number_window) })
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

  if ('menubarStyle' in candidate) {
    if (typeof candidate.menubarStyle !== 'string' || !(MENUBAR_STYLE_IDS as readonly string[]).includes(candidate.menubarStyle)) {
      throw new Error(`menubarStyle must be one of: ${MENUBAR_STYLE_IDS.join(', ')}`);
    }
    validated.menubarStyle = candidate.menubarStyle as MenubarStyleId;
  }
  for (const key of ['menubarShowName', 'menubarShowGlyph', 'menubarShowNumber'] as const) {
    if (key in candidate) {
      if (typeof candidate[key] !== 'boolean') {
        throw new Error(`${key} must be a boolean`);
      }
      validated[key] = candidate[key] as boolean;
    }
  }
  if ('menubarUsage' in candidate) {
    if (typeof candidate.menubarUsage !== 'string' || !(MENUBAR_USAGE_TAILS as readonly string[]).includes(candidate.menubarUsage)) {
      throw new Error('menubarUsage must be one of: off, tok, cost');
    }
    validated.menubarUsage = candidate.menubarUsage as MenubarUsageTail;
  }
  if ('menubarWindowOrder' in candidate) {
    if (
      typeof candidate.menubarWindowOrder !== 'string' ||
      !(MENUBAR_WINDOW_ORDERS as readonly string[]).includes(candidate.menubarWindowOrder)
    ) {
      throw new Error('menubarWindowOrder must be one of: longFirst, shortFirst');
    }
    validated.menubarWindowOrder = candidate.menubarWindowOrder as MenubarWindowOrder;
  }
  if ('providerMenubarVisible' in candidate) {
    const entries = candidate.providerMenubarVisible;
    if (typeof entries !== 'object' || entries === null || Array.isArray(entries)) {
      throw new Error('providerMenubarVisible must be an object');
    }
    for (const [providerId, visible] of Object.entries(entries)) {
      if (typeof visible !== 'boolean') {
        throw new Error(`providerMenubarVisible has invalid flag for provider: ${providerId}`);
      }
    }
    validated.providerMenubarVisible = entries as Record<string, boolean>;
  }
  for (const key of ['providerGlyphWindow', 'providerNumberWindow'] as const) {
    if (key in candidate) {
      const entries = candidate[key];
      if (typeof entries !== 'object' || entries === null || Array.isArray(entries)) {
        throw new Error(`${key} must be an object`);
      }
      for (const [providerId, choice] of Object.entries(entries)) {
        if (typeof choice !== 'string' || !(MENUBAR_WINDOW_CHOICES as readonly string[]).includes(choice)) {
          throw new Error(`${key} has invalid window choice for provider: ${providerId}`);
        }
      }
      validated[key] = entries as Record<string, MenubarWindowChoice>;
    }
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
    patch.quotaUsedThresholdPercent !== undefined ||
    patch.menubarStyle !== undefined ||
    patch.menubarShowName !== undefined ||
    patch.menubarShowGlyph !== undefined ||
    patch.menubarShowNumber !== undefined ||
    patch.menubarUsage !== undefined ||
    patch.menubarWindowOrder !== undefined ||
    patch.providerMenubarVisible !== undefined ||
    patch.providerGlyphWindow !== undefined ||
    patch.providerNumberWindow !== undefined
  );
}
