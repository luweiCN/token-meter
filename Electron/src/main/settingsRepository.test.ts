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

  it('reads the Swift-compatible settings snapshot and provider overrides from SQLite', () => {
    const { repo } = openRepo();

    expect(repo.get()).toEqual({
      version: 3,
      menuBarPrimaryProviderId: 'codex',
      autoRefreshSeconds: 300,
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
});
