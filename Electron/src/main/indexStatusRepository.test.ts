import Database from 'better-sqlite3';
import { afterEach, describe, expect, it } from 'vitest';

import { IndexStatusRepository } from './indexStatusRepository.js';

function createIndexStatusDb() {
  const db = new Database(':memory:');
  db.exec(`
    CREATE TABLE scan_roots (
      id INTEGER PRIMARY KEY,
      kind TEXT NOT NULL,
      root_path TEXT NOT NULL,
      display_name TEXT NOT NULL,
      enabled INTEGER NOT NULL DEFAULT 1,
      scan_mode TEXT NOT NULL DEFAULT 'incremental',
      file_glob TEXT,
      source_db_path TEXT,
      stable_source_key TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
      last_scan_started_at TEXT,
      last_scan_finished_at TEXT,
      last_successful_cursor TEXT,
      last_error TEXT
    );

    CREATE TABLE scan_runs (
      id INTEGER PRIMARY KEY,
      scan_root_id INTEGER REFERENCES scan_roots(id) ON DELETE CASCADE,
      run_kind TEXT NOT NULL,
      started_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
      finished_at TEXT,
      status TEXT NOT NULL DEFAULT 'running',
      files_seen INTEGER NOT NULL DEFAULT 0,
      files_changed INTEGER NOT NULL DEFAULT 0,
      files_deleted INTEGER NOT NULL DEFAULT 0,
      sessions_added INTEGER NOT NULL DEFAULT 0,
      sessions_updated INTEGER NOT NULL DEFAULT 0,
      sessions_deleted INTEGER NOT NULL DEFAULT 0,
      usage_rows_added INTEGER NOT NULL DEFAULT 0,
      bytes_read INTEGER NOT NULL DEFAULT 0,
      cursor_before TEXT,
      cursor_after TEXT,
      error_summary TEXT
    );

    CREATE TABLE source_files (
      id INTEGER PRIMARY KEY,
      scan_root_id INTEGER NOT NULL REFERENCES scan_roots(id) ON DELETE CASCADE,
      relative_path TEXT NOT NULL,
      canonical_path TEXT NOT NULL,
      file_type TEXT NOT NULL,
      size_bytes INTEGER NOT NULL,
      mtime_ns INTEGER NOT NULL,
      inode INTEGER,
      dev INTEGER,
      content_fingerprint TEXT,
      parser_state TEXT,
      first_seen_run_id INTEGER REFERENCES scan_runs(id) ON DELETE SET NULL,
      last_seen_run_id INTEGER REFERENCES scan_runs(id) ON DELETE SET NULL,
      last_parsed_run_id INTEGER REFERENCES scan_runs(id) ON DELETE SET NULL,
      disappeared_at TEXT,
      parse_status TEXT NOT NULL DEFAULT 'pending',
      parse_error TEXT,
      created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    );

    INSERT INTO scan_roots(
      id, kind, root_path, display_name, enabled, scan_mode, stable_source_key,
      last_scan_started_at, last_scan_finished_at, last_successful_cursor, last_error
    ) VALUES
      (1, 'codex_jsonl', '/Users/test/.codex/sessions', 'Codex', 1, 'incremental', 'codex',
       '2026-07-03T10:00:00Z', '2026-07-03T10:00:05Z', 'cursor-123', NULL),
      (2, 'opencode_sqlite', '/Users/test/.local/share/opencode', 'OpenCode', 0, 'disabled', 'opencode',
       '2026-07-03T09:00:00Z', '2026-07-03T09:00:01Z', NULL, 'database operation failed');

    INSERT INTO scan_runs(
      id, scan_root_id, run_kind, started_at, finished_at, status, files_seen, files_changed,
      files_deleted, sessions_added, sessions_updated, sessions_deleted, usage_rows_added,
      bytes_read, cursor_before, cursor_after, error_summary
    ) VALUES
      (10, 1, 'incremental', '2026-07-03T10:00:00Z', '2026-07-03T10:00:05Z', 'ok', 4, 2, 0, 1, 1, 0, 2, 2048, 'cursor-122', 'cursor-123', NULL),
      (11, 2, 'full', '2026-07-03T11:00:00Z', '2026-07-03T11:00:10Z', 'partial', 3, 1, 0, 0, 0, 0, 0, 1024, NULL, NULL, '1 file failed');

    INSERT INTO source_files(
      id, scan_root_id, relative_path, canonical_path, file_type, size_bytes, mtime_ns,
      content_fingerprint, parser_state, last_seen_run_id, last_parsed_run_id,
      parse_status, parse_error, updated_at
    ) VALUES
      (100, 2, 'bad/session.jsonl', '/Users/test/.local/share/opencode/bad/session.jsonl', 'jsonl_session', 512, 123,
       'SECRET_SOURCE_CONTENT_FINGERPRINT', '{"raw":"SECRET_SOURCE_CONTENT_SHOULD_NOT_LEAK"}', 11, NULL,
       'failed', 'database operation failed', '2026-07-03T11:00:09Z'),
      (101, 1, 'ok/session.jsonl', '/Users/test/.codex/sessions/ok/session.jsonl', 'jsonl_session', 1024, 124,
       'ok-fingerprint', '{"offset":100}', 10, 10, 'ok', NULL, '2026-07-03T10:00:04Z');
  `);
  return db;
}

describe('IndexStatusRepository', () => {
  const openedDbs: Database.Database[] = [];

  afterEach(() => {
    for (const db of openedDbs.splice(0)) {
      db.close();
    }
  });

  function openRepo() {
    const db = createIndexStatusDb();
    openedDbs.push(db);
    return new IndexStatusRepository(db);
  }

  it('status returns scan roots without exposing absolute local root paths', () => {
    const status = openRepo().status();

    expect(status.roots).toEqual([
      {
        id: 1,
        kind: 'codex_jsonl',
        rootPathLabel: '~/.codex/sessions',
        displayName: 'Codex',
        enabled: true,
        scanMode: 'incremental',
        lastScanStartedAt: '2026-07-03T10:00:00Z',
        lastScanFinishedAt: '2026-07-03T10:00:05Z',
        lastSuccessfulCursor: 'cursor-123',
        lastError: null
      },
      {
        id: 2,
        kind: 'opencode_sqlite',
        rootPathLabel: '~/.local/share/opencode',
        displayName: 'OpenCode',
        enabled: false,
        scanMode: 'disabled',
        lastScanStartedAt: '2026-07-03T09:00:00Z',
        lastScanFinishedAt: '2026-07-03T09:00:01Z',
        lastSuccessfulCursor: null,
        lastError: 'database operation failed'
      }
    ]);
    for (const root of status.roots) {
      expect(root).not.toHaveProperty('rootPath');
    }
    expect(JSON.stringify(status.roots)).not.toContain('/Users/test/');
    expect(status.runs).toEqual([
      expect.objectContaining({
        id: 11,
        scanRootId: 2,
        runKind: 'full',
        status: 'partial',
        filesSeen: 3,
        filesChanged: 1,
        usageRowsAdded: 0,
        bytesRead: 1024,
        errorSummary: '1 file failed'
      }),
      expect.objectContaining({
        id: 10,
        scanRootId: 1,
        runKind: 'incremental',
        status: 'ok',
        filesSeen: 4,
        filesChanged: 2,
        usageRowsAdded: 2,
        bytesRead: 2048,
        errorSummary: null
      })
    ]);
  });

  it('status includes failed file summaries without exposing source content or parser state', () => {
    const status = openRepo().status();

    expect(status.failedFiles).toEqual([
      {
        id: 100,
        scanRootId: 2,
        relativePath: 'bad/session.jsonl',
        fileType: 'jsonl_session',
        parseError: 'database operation failed',
        updatedAt: '2026-07-03T11:00:09Z'
      }
    ]);
    expect(status.failedFiles[0]).not.toHaveProperty('canonicalPath');
    expect(status.failedFiles[0]).not.toHaveProperty('parser_state');
    expect(status.failedFiles[0]).not.toHaveProperty('parserState');
    expect(status.failedFiles[0]).not.toHaveProperty('contentFingerprint');
    expect(JSON.stringify(status)).not.toMatch(/SECRET_SOURCE_CONTENT|raw/);
  });
});
