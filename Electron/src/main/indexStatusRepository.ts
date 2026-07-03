import type Database from 'better-sqlite3';

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

interface ScanRootRow extends Omit<ScanRootSummary, 'enabled' | 'rootPathLabel'> {
  rootPath: string;
  enabled: 0 | 1;
}

export class IndexStatusRepository {
  constructor(private readonly db: Database.Database) {}

  status() {
    const roots = this.db
      .prepare(
        `SELECT id,
                kind,
                root_path AS rootPath,
                display_name AS displayName,
                enabled,
                scan_mode AS scanMode,
                last_scan_started_at AS lastScanStartedAt,
                last_scan_finished_at AS lastScanFinishedAt,
                last_successful_cursor AS lastSuccessfulCursor,
                last_error AS lastError
         FROM scan_roots
         ORDER BY id ASC`
      )
      .all() as ScanRootRow[];

    const runs = this.db
      .prepare(
        `SELECT id,
                scan_root_id AS scanRootId,
                run_kind AS runKind,
                started_at AS startedAt,
                finished_at AS finishedAt,
                status,
                files_seen AS filesSeen,
                files_changed AS filesChanged,
                files_deleted AS filesDeleted,
                sessions_added AS sessionsAdded,
                sessions_updated AS sessionsUpdated,
                sessions_deleted AS sessionsDeleted,
                usage_rows_added AS usageRowsAdded,
                bytes_read AS bytesRead,
                cursor_before AS cursorBefore,
                cursor_after AS cursorAfter,
                error_summary AS errorSummary
         FROM scan_runs
         ORDER BY id DESC
         LIMIT 20`
      )
      .all() as ScanRunSummary[];

    const failedFiles = this.db
      .prepare(
        `SELECT id,
                scan_root_id AS scanRootId,
                relative_path AS relativePath,
                file_type AS fileType,
                parse_error AS parseError,
                updated_at AS updatedAt
         FROM source_files
         WHERE parse_status = 'failed'
         ORDER BY updated_at DESC, id DESC
         LIMIT 50`
      )
      .all() as FailedFileSummary[];

    return {
      roots: roots.map(({ rootPath, ...root }) => ({ ...root, rootPathLabel: redactedRootPath(rootPath), enabled: root.enabled === 1 })),
      runs,
      failedFiles
    };
  }
}

function redactedRootPath(rootPath: string) {
  const homeMatch = rootPath.match(/^\/(Users|home)\/[^/]+(?<rest>\/.*)?$/);
  if (homeMatch?.groups?.rest !== undefined) {
    return `~${homeMatch.groups.rest}`;
  }
  if (homeMatch) return '~';
  return rootPath.startsWith('/') ? rootPath.split('/').filter(Boolean).at(-1) ?? '/' : rootPath;
}
