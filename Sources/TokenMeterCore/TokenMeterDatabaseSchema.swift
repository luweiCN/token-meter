public enum TokenMeterDatabaseSchema {
    public static let currentVersion: Int64 = 2

    public static let v1 = """
    CREATE TABLE IF NOT EXISTS schema_migrations (
      version INTEGER PRIMARY KEY,
      name TEXT NOT NULL UNIQUE,
      applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    );

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
      source_file_id INTEGER REFERENCES source_files(id) ON DELETE SET NULL,
      project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL,
      provider_id TEXT,
      agent_name TEXT,
      model_provider TEXT,
      model_name TEXT,
      cli_version TEXT,
      session_started_at TEXT,
      session_updated_at TEXT,
      session_closed_at TEXT,
      cwd_path TEXT,
      worktree_path TEXT,
      title TEXT,
      status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'closed', 'deleted', 'orphaned')),
      message_count INTEGER,
      event_count INTEGER,
      total_cost_usd_micros INTEGER,
      source_revision TEXT NOT NULL,
      first_seen_run_id INTEGER REFERENCES scan_runs(id) ON DELETE SET NULL,
      last_seen_run_id INTEGER REFERENCES scan_runs(id) ON DELETE SET NULL,
      last_indexed_run_id INTEGER REFERENCES scan_runs(id) ON DELETE SET NULL,
      deleted_at TEXT,
      raw_meta_json TEXT,
      UNIQUE(source_kind, source_session_key)
    );

    CREATE TABLE IF NOT EXISTS session_usage (
      id INTEGER PRIMARY KEY,
      session_id INTEGER NOT NULL REFERENCES agent_sessions(id) ON DELETE CASCADE,
      observed_at TEXT NOT NULL,
      usage_seq INTEGER NOT NULL,
      metric_scope TEXT NOT NULL DEFAULT 'session' CHECK (metric_scope IN ('session', 'window', 'total')),
      window_label TEXT,
      tokens_input INTEGER,
      tokens_output INTEGER,
      tokens_reasoning INTEGER,
      tokens_cache_read INTEGER,
      tokens_cache_write INTEGER,
      tokens_total INTEGER GENERATED ALWAYS AS (
        coalesce(tokens_input,0) + coalesce(tokens_output,0) + coalesce(tokens_reasoning,0) +
        coalesce(tokens_cache_read,0) + coalesce(tokens_cache_write,0)
      ) VIRTUAL,
      cost_usd_micros INTEGER,
      source_event_id TEXT,
      source_offset INTEGER,
      source_hash TEXT,
      is_cumulative INTEGER NOT NULL DEFAULT 1 CHECK (is_cumulative IN (0,1)),
      UNIQUE(session_id, usage_seq),
      UNIQUE(session_id, source_event_id),
      UNIQUE(session_id, source_offset),
      UNIQUE(session_id, id)
    );

    CREATE TABLE IF NOT EXISTS session_usage_latest (
      session_id INTEGER PRIMARY KEY REFERENCES agent_sessions(id) ON DELETE CASCADE,
      session_usage_id INTEGER NOT NULL UNIQUE REFERENCES session_usage(id) ON DELETE CASCADE,
      updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY (session_id, session_usage_id) REFERENCES session_usage(session_id, id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS provider_daily_usage (
      usage_date TEXT NOT NULL,
      provider_id TEXT NOT NULL,
      project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL,
      source_kind TEXT NOT NULL,
      sessions_count INTEGER NOT NULL,
      tokens_input INTEGER NOT NULL DEFAULT 0,
      tokens_output INTEGER NOT NULL DEFAULT 0,
      tokens_reasoning INTEGER NOT NULL DEFAULT 0,
      tokens_cache_read INTEGER NOT NULL DEFAULT 0,
      tokens_cache_write INTEGER NOT NULL DEFAULT 0,
      total_cost_usd_micros INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (usage_date, provider_id, project_id, source_kind)
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
    CREATE INDEX IF NOT EXISTS idx_sessions_source_file ON agent_sessions(source_file_id);
    CREATE INDEX IF NOT EXISTS idx_sessions_status_updated ON agent_sessions(status, session_updated_at DESC);
    CREATE INDEX IF NOT EXISTS idx_usage_session_observed ON session_usage(session_id, observed_at DESC);
    CREATE INDEX IF NOT EXISTS idx_daily_provider_date ON provider_daily_usage(provider_id, usage_date DESC);
    CREATE UNIQUE INDEX IF NOT EXISTS idx_daily_unique_project_scope ON provider_daily_usage(usage_date, provider_id, coalesce(project_id, -1), source_kind);
    CREATE INDEX IF NOT EXISTS idx_daily_project_provider_date ON provider_daily_usage(project_id, provider_id, usage_date DESC);
    CREATE INDEX IF NOT EXISTS idx_settings_updated ON settings(updated_at DESC);

    INSERT OR IGNORE INTO schema_migrations(version, name) VALUES (1, 'phase2_hybrid_sessions');
    PRAGMA user_version = 1;
    """

    /// v2 只做加法：新增四张表，不触碰 v1 的任何表。
    /// v1 全是 CREATE TABLE IF NOT EXISTS，migrator 顺序执行两段即可：
    /// 全新库跑 v1 + v2Additions，v1 老库只跑 v2Additions。
    /// 旧表的删除由 Task 18 负责，那时 scanner 已切换完毕。
    public static let v2Additions = """
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

    INSERT OR IGNORE INTO schema_migrations(version, name) VALUES (2, 'phase3_message_level_usage');
    PRAGMA user_version = 2;
    """
}
