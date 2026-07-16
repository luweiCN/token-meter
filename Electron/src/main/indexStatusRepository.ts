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
  /// 物理文件口径（排除 OpenCode 的 #ses_ 逻辑分片），已消失的文件不计。
  fileCount: number;
  totalSizeBytes: number;
  /// 该根目录名下已索引的 usage 事件数（经 source_files 归属）。
  eventsCount: number;
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
        `SELECT sr.id,
                sr.kind,
                sr.root_path AS rootPath,
                sr.display_name AS displayName,
                sr.enabled,
                sr.scan_mode AS scanMode,
                sr.last_scan_started_at AS lastScanStartedAt,
                sr.last_scan_finished_at AS lastScanFinishedAt,
                sr.last_successful_cursor AS lastSuccessfulCursor,
                sr.last_error AS lastError,
                coalesce(agg.file_count, 0) AS fileCount,
                coalesce(agg.total_bytes, 0) AS totalSizeBytes,
                coalesce(ev.events_count, 0) AS eventsCount
         FROM scan_roots sr
    LEFT JOIN (
           -- 物理文件口径：OpenCode 的 #ses_ 分片行共享同一个 db 文件、每行都记
           -- 整库大小（实测 213 行 × 1.9GB 虚增成 417GB），必须排除分片只数实体。
           SELECT scan_root_id,
                  count(*) AS file_count,
                  sum(size_bytes) AS total_bytes
             FROM source_files
            WHERE disappeared_at IS NULL
              AND instr(relative_path, '#') = 0
         GROUP BY scan_root_id
         ) agg ON agg.scan_root_id = sr.id
    LEFT JOIN (
           -- 每根目录已索引事件数（24 万行实测 ~15ms，仅索引页/设置页拉取时执行）。
           SELECT sf.scan_root_id, count(*) AS events_count
             FROM usage_events e
             JOIN source_files sf ON sf.id = e.source_file_id
         GROUP BY sf.scan_root_id
         ) ev ON ev.scan_root_id = sr.id
        ORDER BY sr.id ASC`
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

  /// E 区目录启停。关 = 下轮扫描起跳过（Swift 每轮重查 scan_roots，无需通知）；
  /// 已索引的历史数据保留。开时若 scan_mode 还是 'disabled'（种子期禁用的根），
  /// 一并恢复 incremental——扫描查询的过滤条件是两者联合。
  setRootEnabled(id: number, enabled: boolean): void {
    const result = this.db
      .prepare(
        `UPDATE scan_roots
            SET enabled = ?,
                scan_mode = CASE WHEN ? = 1 AND scan_mode = 'disabled' THEN 'incremental' ELSE scan_mode END,
                updated_at = datetime('now')
          WHERE id = ?`
      )
      .run(enabled ? 1 : 0, enabled ? 1 : 0, id);
    if (result.changes === 0) {
      throw new Error(`scan root not found: ${id}`);
    }
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
