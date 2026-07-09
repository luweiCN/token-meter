public enum TokenMeterDatabaseSchema {
    /// 派生数据的 schema 版本。改动它 == 下次启动删光派生表、重建、等一次全量重扫。
    /// 这是【零成本】的：数据的真相在会话文件里（~/.claude、~/.codex、~/.omp、opencode.db），不在这里。
    /// 因此不需要 V1/V2/V3 那套版本化迁移链，也不需要「加列必须是加法」那套开发期约束。
    ///
    /// 为什么是 4 而不是 1：历史迁移链用 user_version 1/2/3 编号，生产库现在停在 user_version = 1
    /// 的老 v1 形状（没有 usage_events）。若 derivedVersion 也取 1，migrate 会把老 v1 库误判成
    /// 「已是最新」而跳过重建，永远建不出 usage_events。取 4（大于历史最大值 3）保证任何遗留库
    /// （user_version ∈ 0/1/2/3）都与之不等，从而在下次启动时触发一次重建。
    public static let derivedVersion: Int64 = 4

    /// 用户配置。永不删除。这三张表存的是无法从会话文件重建的东西：
    /// - settings：过滤器 / 菜单栏偏好 / 自动刷新间隔
    /// - provider_config_overrides：各 provider 的启用、显示名、菜单顺序
    /// - scan_roots：扫描哪些目录（用户可能加了自定义路径），及其扫描状态列
    /// 全是 CREATE TABLE IF NOT EXISTS，幂等，每次启动都跑也安全。以后要加列，请用
    /// `ALTER TABLE ... ADD COLUMN`（同样幂等），永远不要把配置表卷进 derivedVersion 的重建。
    public static let configTables = """
    CREATE TABLE IF NOT EXISTS settings (
      key TEXT PRIMARY KEY,
      value_json TEXT NOT NULL,
      value_type TEXT NOT NULL CHECK (value_type IN ('string', 'int', 'bool', 'json')),
      version INTEGER NOT NULL,
      updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_by TEXT NOT NULL CHECK (updated_by IN ('swift', 'electron', 'migrator', 'importer'))
    );

    CREATE TABLE IF NOT EXISTS provider_config_overrides (
      provider_id TEXT PRIMARY KEY,
      enabled INTEGER CHECK (enabled IN (0,1)),
      display_name TEXT,
      menu_rank INTEGER,
      show_in_menu_bar INTEGER CHECK (show_in_menu_bar IN (0,1)),
      show_in_charts INTEGER CHECK (show_in_charts IN (0,1)),
      updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    );

    CREATE TABLE IF NOT EXISTS scan_roots (
      id INTEGER PRIMARY KEY,
      kind TEXT NOT NULL CHECK (kind IN ('claude_jsonl', 'codex_jsonl', 'omp_jsonl', 'opencode_sqlite')),
      root_path TEXT NOT NULL,
      display_name TEXT NOT NULL,
      enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0,1)),
      scan_mode TEXT NOT NULL DEFAULT 'incremental' CHECK (scan_mode IN ('incremental', 'full', 'disabled')),
      file_glob TEXT,
      source_db_path TEXT,
      stable_source_key TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
      last_scan_started_at TEXT,
      last_scan_finished_at TEXT,
      last_successful_cursor TEXT,
      last_error TEXT,
      UNIQUE(kind, root_path),
      UNIQUE(stable_source_key)
    );

    CREATE INDEX IF NOT EXISTS idx_settings_updated ON settings(updated_at DESC);
    """

    /// 派生数据。全部可由一次全量重扫从会话文件重建，故 schema 版本一变就整体 DROP + CREATE。
    /// 这里包含 source_files / projects / agent_sessions / scan_runs / usage_events /
    /// daily_rollup / session_rollup / model_pricing 及它们的索引。
    /// 注意：agent_sessions 用的是「事件级」之后的最终形状——已删掉下沉到 usage_events 的
    /// source_file_id / model_name / total_cost_usd_micros / worktree_path / session_closed_at 五列。
    public static let derivedTables = """
    CREATE TABLE IF NOT EXISTS source_files (
      id INTEGER PRIMARY KEY,
      scan_root_id INTEGER NOT NULL REFERENCES scan_roots(id) ON DELETE CASCADE,
      relative_path TEXT NOT NULL,
      canonical_path TEXT NOT NULL,
      file_type TEXT NOT NULL CHECK (file_type IN ('jsonl_session', 'sqlite_db')),
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
      parse_status TEXT NOT NULL DEFAULT 'pending' CHECK (parse_status IN ('pending', 'ok', 'partial', 'failed')),
      parse_error TEXT,
      created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
      UNIQUE(scan_root_id, relative_path),
      UNIQUE(scan_root_id, canonical_path)
    );

    CREATE TABLE IF NOT EXISTS projects (
      id INTEGER PRIMARY KEY,
      project_key TEXT NOT NULL UNIQUE,
      canonical_path TEXT NOT NULL,
      display_name TEXT NOT NULL,
      first_seen_at TEXT NOT NULL,
      last_seen_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS agent_sessions (
      id INTEGER PRIMARY KEY,
      source_kind TEXT NOT NULL,
      source_session_key TEXT NOT NULL,
      scan_root_id INTEGER NOT NULL REFERENCES scan_roots(id) ON DELETE CASCADE,
      project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL,
      provider_id TEXT,
      agent_name TEXT,
      model_provider TEXT,
      cli_version TEXT,
      session_started_at TEXT,
      session_updated_at TEXT,
      cwd_path TEXT,
      title TEXT,
      status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'closed', 'deleted', 'orphaned')),
      message_count INTEGER,
      event_count INTEGER,
      source_revision TEXT NOT NULL,
      first_seen_run_id INTEGER REFERENCES scan_runs(id) ON DELETE SET NULL,
      last_seen_run_id INTEGER REFERENCES scan_runs(id) ON DELETE SET NULL,
      last_indexed_run_id INTEGER REFERENCES scan_runs(id) ON DELETE SET NULL,
      deleted_at TEXT,
      raw_meta_json TEXT,
      UNIQUE(source_kind, source_session_key)
    );

    CREATE TABLE IF NOT EXISTS scan_runs (
      id INTEGER PRIMARY KEY,
      scan_root_id INTEGER REFERENCES scan_roots(id) ON DELETE CASCADE,
      run_kind TEXT NOT NULL CHECK (run_kind IN ('discover', 'incremental', 'full', 'repair')),
      started_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
      finished_at TEXT,
      status TEXT NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'ok', 'partial', 'failed')),
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

    CREATE INDEX IF NOT EXISTS idx_source_files_active ON source_files(scan_root_id, disappeared_at, mtime_ns, size_bytes);
    CREATE INDEX IF NOT EXISTS idx_source_files_inode ON source_files(scan_root_id, dev, inode) WHERE inode IS NOT NULL;
    CREATE INDEX IF NOT EXISTS idx_sessions_project_updated ON agent_sessions(project_id, session_updated_at DESC);
    CREATE INDEX IF NOT EXISTS idx_sessions_provider_updated ON agent_sessions(provider_id, session_updated_at DESC);
    CREATE INDEX IF NOT EXISTS idx_sessions_status_updated ON agent_sessions(status, session_updated_at DESC);

    CREATE TABLE IF NOT EXISTS usage_events (
      id INTEGER PRIMARY KEY,
      session_id INTEGER NOT NULL REFERENCES agent_sessions(id) ON DELETE CASCADE,
      source_file_id INTEGER NOT NULL REFERENCES source_files(id) ON DELETE CASCADE,
      event_seq INTEGER NOT NULL,
      observed_epoch_ms INTEGER NOT NULL,
      model_name TEXT,
      model_canonical TEXT,
      tokens_input INTEGER NOT NULL DEFAULT 0,
      tokens_output INTEGER NOT NULL DEFAULT 0,
      tokens_reasoning INTEGER NOT NULL DEFAULT 0,
      tokens_cache_read INTEGER NOT NULL DEFAULT 0,
      tokens_cache_write_5m INTEGER NOT NULL DEFAULT 0,
      tokens_cache_write_1h INTEGER NOT NULL DEFAULT 0,
      tokens_total INTEGER GENERATED ALWAYS AS (
        tokens_input + tokens_output +
        tokens_cache_read + tokens_cache_write_5m + tokens_cache_write_1h
      ) VIRTUAL,
      cost_usd_micros INTEGER,
      cost_source TEXT NOT NULL CHECK (cost_source IN ('reported', 'computed', 'unknown')),
      dedupe_key TEXT,
      source_offset INTEGER NOT NULL,
      is_sidechain INTEGER NOT NULL DEFAULT 0 CHECK (is_sidechain IN (0,1)),
      UNIQUE(source_file_id, event_seq)
    );

    CREATE UNIQUE INDEX IF NOT EXISTS idx_usage_dedupe
      ON usage_events(session_id, dedupe_key) WHERE dedupe_key IS NOT NULL;
    CREATE INDEX IF NOT EXISTS idx_usage_time ON usage_events(observed_epoch_ms);
    CREATE INDEX IF NOT EXISTS idx_usage_session ON usage_events(session_id, observed_epoch_ms);
    CREATE INDEX IF NOT EXISTS idx_usage_model_time ON usage_events(model_canonical, observed_epoch_ms);
    CREATE INDEX IF NOT EXISTS idx_usage_source_file ON usage_events(source_file_id, source_offset DESC);

    CREATE TABLE IF NOT EXISTS daily_rollup (
      usage_date TEXT NOT NULL,
      provider_id TEXT NOT NULL,
      source_kind TEXT NOT NULL,
      project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL,
      model_canonical TEXT NOT NULL,
      sessions_count INTEGER NOT NULL DEFAULT 0,
      events_count INTEGER NOT NULL DEFAULT 0,
      tokens_input INTEGER NOT NULL DEFAULT 0,
      tokens_output INTEGER NOT NULL DEFAULT 0,
      tokens_reasoning INTEGER NOT NULL DEFAULT 0,
      tokens_cache_read INTEGER NOT NULL DEFAULT 0,
      tokens_cache_write_5m INTEGER NOT NULL DEFAULT 0,
      tokens_cache_write_1h INTEGER NOT NULL DEFAULT 0,
      cost_usd_micros INTEGER NOT NULL DEFAULT 0,
      cost_unknown_events INTEGER NOT NULL DEFAULT 0
    );

    CREATE UNIQUE INDEX IF NOT EXISTS idx_daily_rollup_unique
      ON daily_rollup(usage_date, provider_id, source_kind, coalesce(project_id, -1), model_canonical);
    CREATE INDEX IF NOT EXISTS idx_daily_rollup_date ON daily_rollup(usage_date DESC);
    CREATE INDEX IF NOT EXISTS idx_daily_rollup_model ON daily_rollup(model_canonical, usage_date DESC);

    CREATE TABLE IF NOT EXISTS session_rollup (
      session_id INTEGER PRIMARY KEY REFERENCES agent_sessions(id) ON DELETE CASCADE,
      first_event_epoch_ms INTEGER NOT NULL,
      last_event_epoch_ms INTEGER NOT NULL,
      events_count INTEGER NOT NULL,
      tokens_total INTEGER NOT NULL,
      cost_usd_micros INTEGER NOT NULL,
      -- 与 daily_rollup 对齐：sum() 会静默跳过 cost 为 NULL 的行，
      -- 会话中途换到未定价的模型时，金额会偏低却看起来精确。
      cost_unknown_events INTEGER NOT NULL DEFAULT 0,
      primary_model TEXT
    );

    CREATE INDEX IF NOT EXISTS idx_session_rollup_last ON session_rollup(last_event_epoch_ms DESC);

    CREATE TABLE IF NOT EXISTS model_pricing (
      model_key TEXT PRIMARY KEY,
      input_per_mtok_micros INTEGER NOT NULL,
      output_per_mtok_micros INTEGER NOT NULL,
      cache_read_per_mtok_micros INTEGER NOT NULL,
      cache_write_5m_per_mtok_micros INTEGER NOT NULL,
      cache_write_1h_per_mtok_micros INTEGER NOT NULL,
      source TEXT NOT NULL CHECK (source IN ('litellm', 'builtin', 'user')),
      snapshot_version TEXT
    );
    """

    /// 重建派生表后，把 scan_roots 上的扫描状态清回「从未扫描过」。
    /// last_successful_cursor 是关键：OpenCode 的 changedSessions(after:) 用它做
    /// `time_updated > cursor` 的增量过滤——若 usage_events 被清空而游标还在，适配器会因
    /// 「游标之后无变化」返回空集，被清掉的 OpenCode 事件永不重建（Phase 1 Task 15 的教训）。
    /// 另外三列（started/finished/last_error）是扫描进度与错误的展示状态，一并清掉，
    /// 让 scan_roots 诚实地反映「派生数据已清空、尚未重扫」。
    /// TokenMeterDatabaseMigrator 的重建与 LocalAgentScanner.fullRescan 都执行这一段常量，
    /// 清同样的列——共用一份 SQL，故两处不会漂移。
    public static let resetScanState = """
    UPDATE scan_roots SET
      last_successful_cursor = NULL,
      last_scan_started_at = NULL,
      last_scan_finished_at = NULL,
      last_error = NULL
    """
}
