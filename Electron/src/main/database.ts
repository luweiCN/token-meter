import Database from 'better-sqlite3';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

export function tokenMeterDatabasePath() {
  // 开发/验证时可用 TOKEN_METER_DB_PATH 指向一份副本，避免在未迁移的生产库上触发迁移。
  const override = process.env.TOKEN_METER_DB_PATH;
  if (override && override.trim() !== '') return override;
  return path.join(os.homedir(), '.token-meter', 'tokenmeter.sqlite');
}

export function openTokenMeterDatabase(file = tokenMeterDatabasePath()) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const db = new Database(file);
  db.pragma('journal_mode = WAL');
  db.pragma('foreign_keys = ON');
  db.pragma('busy_timeout = 5000');
  return db;
}
