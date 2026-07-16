import Database from 'better-sqlite3';
import { afterEach, describe, expect, it } from 'vitest';

import { SettingsRepository } from './settingsRepository.js';

function memoryDb() {
  const db = new Database(':memory:');
  db.exec(`
    CREATE TABLE settings (
      key TEXT PRIMARY KEY,
      value_json TEXT NOT NULL,
      value_type TEXT NOT NULL CHECK (value_type IN ('string', 'int', 'bool', 'json')),
      version INTEGER NOT NULL,
      updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_by TEXT NOT NULL CHECK (updated_by IN ('swift', 'electron', 'migrator', 'importer'))
    );

    CREATE TABLE provider_config_overrides (
      provider_id TEXT PRIMARY KEY,
      enabled INTEGER CHECK (enabled IN (0,1)),
      display_name TEXT,
      menu_rank INTEGER,
      show_in_menu_bar INTEGER CHECK (show_in_menu_bar IN (0,1)),
      show_in_charts INTEGER CHECK (show_in_charts IN (0,1)),
      updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    );

    INSERT INTO settings(key, value_json, value_type, version, updated_by) VALUES
      ('menuBar.primaryProviderId', '"codex"', 'string', 3, 'importer'),
      ('scan.autoRefreshSeconds', '300', 'int', 3, 'importer'),
      ('filters.enabledAgentKinds', '["claudeCode","codex"]', 'json', 3, 'importer');

    INSERT INTO provider_config_overrides(provider_id, enabled, display_name, menu_rank, show_in_menu_bar, show_in_charts) VALUES
      ('claude-code', 0, 'Claude Code', 2, 0, 1),
      ('codex', 1, 'Codex', 1, 1, 1);
  `);
  return db;
}

function settingRows(db: Database.Database) {
  return db
    .prepare('SELECT key, value_json, value_type, version, updated_by FROM settings ORDER BY key')
    .all() as Array<{
    key: string;
    value_json: string;
    value_type: string;
    version: number;
    updated_by: string;
  }>;
}

describe('SettingsRepository', () => {
  const openedDbs: Database.Database[] = [];

  afterEach(() => {
    for (const db of openedDbs.splice(0)) {
      db.close();
    }
  });

  function openRepo() {
    const db = memoryDb();
    openedDbs.push(db);
    return { db, repo: new SettingsRepository(db) };
  }

  it('saves provider display names into overrides and bumps the settings version', () => {
    const { repo } = openRepo();

    const result = repo.update({ providerDisplayNames: { zhipu: 'GLM' } }, 3);
    expect(result).toEqual({ requestedVersion: 4, status: 'pending' });

    const snapshot = repo.get();
    expect(snapshot.version).toBe(4);
    expect(snapshot.providerOverrides.find((o) => o.providerId === 'zhipu')?.displayName).toBe('GLM');

    // 空串 = 清除自定义显示名，回落默认。
    repo.update({ providerDisplayNames: { zhipu: '' } }, 4);
    expect(repo.get().providerOverrides.find((o) => o.providerId === 'zhipu')?.displayName).toBeUndefined();
  });

  it('reads the Swift-compatible settings snapshot and provider overrides from SQLite', () => {
    const { repo } = openRepo();

    expect(repo.get()).toEqual({
      version: 3,
      menuBarPrimaryProviderId: 'codex',
      autoRefreshSeconds: 300,
      quotaUsedThresholdPercent: 0,
      enabledAgentKinds: ['claudeCode', 'codex'],
      providerOverrides: [
        {
          providerId: 'codex',
          enabled: true,
          displayName: 'Codex',
          menuRank: 1,
          showInMenuBar: true,
          showInCharts: true
        },
        {
          providerId: 'claude-code',
          enabled: false,
          displayName: 'Claude Code',
          menuRank: 2,
          showInMenuBar: false,
          showInCharts: true
        }
      ]
    });
  });

  it('matches Swift ordering when provider menu ranks are null', () => {
    const { db, repo } = openRepo();
    db.prepare(
      `INSERT INTO provider_config_overrides(provider_id, enabled, display_name, menu_rank, show_in_menu_bar, show_in_charts)
       VALUES ('unranked', 1, 'Unranked', NULL, 1, 1)`
    ).run();

    expect(repo.get().providerOverrides.map((override) => override.providerId)).toEqual([
      'unranked',
      'codex',
      'claude-code'
    ]);
  });

  it('rejects stale settings writes without mutating stored settings', () => {
    const { db, repo } = openRepo();
    const before = settingRows(db);

    expect(() => repo.update({ menuBarPrimaryProviderId: 'claude-code' }, 2)).toThrow(/stale/i);

    expect(settingRows(db)).toEqual(before);
  });

  it('bumps the version and writes changed settings with Swift-compatible value types and electron attribution', () => {
    const { db, repo } = openRepo();

    const result = repo.update(
      {
        menuBarPrimaryProviderId: 'claude-code',
        autoRefreshSeconds: 60,
        enabledAgentKinds: ['claudeCode', 'opencode', 'omp']
      },
      3
    );

    expect(result).toEqual({ requestedVersion: 4, status: 'pending' });
    expect(repo.get()).toMatchObject({
      version: 4,
      menuBarPrimaryProviderId: 'claude-code',
      autoRefreshSeconds: 60,
      enabledAgentKinds: ['claudeCode', 'opencode', 'omp']
    });
    expect(settingRows(db)).toEqual([
      {
        key: 'filters.enabledAgentKinds',
        value_json: '["claudeCode","opencode","omp"]',
        value_type: 'json',
        version: 4,
        updated_by: 'electron'
      },
      {
        key: 'menuBar.primaryProviderId',
        value_json: '"claude-code"',
        value_type: 'string',
        version: 4,
        updated_by: 'electron'
      },
      {
        key: 'scan.autoRefreshSeconds',
        value_json: '60',
        value_type: 'int',
        version: 4,
        updated_by: 'electron'
      }
    ]);
  });

  it('rejects empty patches without bumping the settings version', () => {
    const { repo } = openRepo();

    expect(() => repo.update({}, 3)).toThrow(/patch|change|empty/i);

    expect(repo.get().version).toBe(3);
  });

  it('rejects invalid renderer patch values without mutating stored settings', () => {
    const { db, repo } = openRepo();
    const before = settingRows(db);

    expect(() => repo.update({ autoRefreshSeconds: 29 }, 3)).toThrow(/autoRefreshSeconds|30/);
    expect(() => repo.update({ enabledAgentKinds: 'codex' } as never, 3)).toThrow(/enabledAgentKinds/);
    expect(() => repo.update({ menuBarPrimaryProviderId: 42 } as never, 3)).toThrow(/menuBarPrimaryProviderId/);
    expect(() => repo.update({ enabledAgentKinds: ['claudeCode', 'cursor'] }, 3)).toThrow(/enabledAgentKinds|cursor|unsupported/i);

    expect(settingRows(db)).toEqual(before);
  });

  it('stores provider enable flags into overrides and bumps the settings version', () => {
    const { repo } = openRepo();

    const result = repo.update({ providerEnabled: { zhipu: false } }, 3);

    expect(result).toEqual({ requestedVersion: 4, status: 'pending' });
    const zhipu = repo.get().providerOverrides.find((o) => o.providerId === 'zhipu');
    expect(zhipu?.enabled).toBe(false);
    expect(repo.get().version).toBe(4);

    repo.update({ providerEnabled: { zhipu: true } }, 4);
    expect(repo.get().providerOverrides.find((o) => o.providerId === 'zhipu')?.enabled).toBe(true);

    expect(() => repo.update({ providerEnabled: { zhipu: 'yes' } } as never, 5)).toThrow(/enabled/i);
  });

  it('stores the quota alert threshold, defaults it to 0, and validates its range', () => {
    const { repo } = openRepo();
    expect(repo.get().quotaUsedThresholdPercent).toBe(0);   // 未设置 = 告警关闭

    const result = repo.update({ quotaUsedThresholdPercent: 85 }, 3);
    expect(result.status).toBe('pending');
    expect(repo.get().quotaUsedThresholdPercent).toBe(85);

    repo.update({ quotaUsedThresholdPercent: 0 }, 4);       // 0 = 关闭，合法
    expect(repo.get().quotaUsedThresholdPercent).toBe(0);

    expect(() => repo.update({ quotaUsedThresholdPercent: 30 }, 5)).toThrow(/quotaUsedThresholdPercent/);
    expect(() => repo.update({ quotaUsedThresholdPercent: 101 }, 5)).toThrow(/quotaUsedThresholdPercent/);
    expect(() => repo.update({ quotaUsedThresholdPercent: 85.5 }, 5)).toThrow(/quotaUsedThresholdPercent/);
  });
});
