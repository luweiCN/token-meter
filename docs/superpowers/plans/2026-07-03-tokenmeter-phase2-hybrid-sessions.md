# TokenMeter Phase 2 Hybrid Sessions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build TokenMeter Phase 2: a Swift menu bar app with a shared SQLite incremental session index and an Electron/React main interface for local coding-agent token analytics and settings.

**Architecture:** Swift remains the always-on owner of the menu bar, provider refresh, local session scanning, and SQLite fact-table writes. Electron/React is opened on demand for dashboard charts, sessions, index status, and settings; Electron main reads SQLite and writes settings only, then notifies Swift through a local JSON-line socket. SQLite is the shared fact source for settings, scan cursors, source files, sessions, usage history, latest summaries, and rollups.

**Tech Stack:** Swift 5.9, SwiftPM, AppKit, SwiftUI, Foundation, Network.framework, SQLite C API, XCTest, Electron, React, TypeScript, Vite, Vitest, better-sqlite3.

---

## Approved Spec

Implement against:

- `docs/superpowers/specs/2026-07-03-tokenmeter-phase2-hybrid-sessions-design.md`

Hard constraints from the approved spec:

- Do not store prompt text, assistant response text, reasoning text, tool output, attachment content, cookies, API keys, or credentials in the TokenMeter SQLite database.
- Swift is the single writer for session/usage/index fact tables.
- Electron main may write settings tables only.
- Electron renderer never directly touches SQLite, Keychain, filesystem, or Node APIs.
- Large session files are not skipped; they are processed with streaming/incremental parsers.
- Electron settings changes must affect the Swift menu bar without app restart.

---

## File Structure

### Swift package

- Modify: `Package.swift`
  - Add `CSQLite` system library target.
  - Link `TokenMeterCore` against `CSQLite` and `sqlite3`.
  - Link `TokenMeterApp` with `Network` if needed by imports.
- Create: `Sources/CSQLite/module.modulemap`
  - Expose the system SQLite header to SwiftPM.
- Create: `Sources/TokenMeterCore/SQLiteDatabase.swift`
  - Thin, parameterized SQLite wrapper.
- Create: `Sources/TokenMeterCore/TokenMeterDatabaseSchema.swift`
  - Schema constants and migrations.
- Create: `Sources/TokenMeterCore/TokenMeterDatabaseMigrator.swift`
  - `PRAGMA user_version`, migration tracking, WAL setup.
- Create: `Sources/TokenMeterCore/TokenMeterPaths.swift`
  - Shared paths: config import, cache, SQLite DB, socket.
- Create: `Sources/TokenMeterCore/SettingsStore.swift`
  - SQLite-backed settings and provider overrides.
- Create: `Sources/TokenMeterCore/SettingsModels.swift`
  - `SettingsSnapshot`, `SettingsPatch`, `SettingsApplyRequest`, `SettingsEvent`.
- Create: `Sources/TokenMeterCore/LocalAgentModels.swift`
  - `LocalAgentKind`, source root/file/session/usage models, scan models.
- Create: `Sources/TokenMeterCore/JSONLStreamReader.swift`
  - Streaming JSONL reader with byte offsets and incomplete-line handling.
- Create: `Sources/TokenMeterCore/SourceFileChangeDetector.swift`
  - Unchanged/append/rewrite/move/delete classification.
- Create: `Sources/TokenMeterCore/LocalAgentSessionParsers.swift`
  - Parser protocols and shared helpers.
- Create: `Sources/TokenMeterCore/CodexSessionParser.swift`
  - Codex JSONL parser.
- Create: `Sources/TokenMeterCore/ClaudeCodeSessionParser.swift`
  - Claude Code JSONL parser.
- Create: `Sources/TokenMeterCore/OmpSessionParser.swift`
  - OMP JSONL parser.
- Create: `Sources/TokenMeterCore/OpenCodeSessionAdapter.swift`
  - OpenCode SQLite high-water adapter.
- Create: `Sources/TokenMeterCore/LocalAgentScanner.swift`
  - Scan coordinator.
- Create: `Sources/TokenMeterCore/LocalAgentUsageRepository.swift`
  - Upsert sessions, usage, latest, rollups, scan runs.
- Create: `Sources/TokenMeterCore/MenuBarSummaryRepository.swift`
  - Fast menu-bar summary queries.
- Create: `Sources/TokenMeterApp/TokenMeterIPCServer.swift`
  - Swift JSON-line socket server for Electron notifications.
- Modify: `Sources/TokenMeterApp/ProviderStore.swift`
  - Load SQLite settings, run scanner, expose local index state.
- Modify: `Sources/TokenMeterApp/AppDelegate.swift`
  - Start DB migration, IPC server, scanner timer driven by settings.
- Modify: `Sources/TokenMeterApp/PopoverView.swift`
  - Add local index summary and “打开详细界面” action.
- Modify: `Sources/TokenMeterApp/StatusBarController.swift`
  - Wire open-main-window action.
- Modify: `Resources/Info.plist`
  - Add URL scheme for deep links if needed.

### Swift tests

- Create: `Tests/TokenMeterCoreTests/SQLiteDatabaseTests.swift`
- Create: `Tests/TokenMeterCoreTests/TokenMeterDatabaseMigratorTests.swift`
- Create: `Tests/TokenMeterCoreTests/SettingsStoreTests.swift`
- Create: `Tests/TokenMeterCoreTests/SourceFileChangeDetectorTests.swift`
- Create: `Tests/TokenMeterCoreTests/JSONLStreamReaderTests.swift`
- Create: `Tests/TokenMeterCoreTests/CodexSessionParserTests.swift`
- Create: `Tests/TokenMeterCoreTests/ClaudeCodeSessionParserTests.swift`
- Create: `Tests/TokenMeterCoreTests/OmpSessionParserTests.swift`
- Create: `Tests/TokenMeterCoreTests/OpenCodeSessionAdapterTests.swift`
- Create: `Tests/TokenMeterCoreTests/LocalAgentScannerTests.swift`
- Create: `Tests/TokenMeterCoreTests/LocalAgentUsageRepositoryTests.swift`
- Create: `Tests/TokenMeterCoreTests/MenuBarSummaryRepositoryTests.swift`
- Create: `Tests/TokenMeterCoreTests/PrivacyIndexingTests.swift`

### Electron app

- Create: `Electron/package.json`
- Create: `Electron/tsconfig.json`
- Create: `Electron/vite.config.ts`
- Create: `Electron/vitest.config.ts`
- Create: `Electron/index.html`
- Create: `Electron/src/main/main.ts`
- Create: `Electron/src/main/database.ts`
- Create: `Electron/src/main/ipc.ts`
- Create: `Electron/src/main/settingsRepository.ts`
- Create: `Electron/src/main/tokenMeterSocketClient.ts`
- Create: `Electron/src/preload.ts`
- Create: `Electron/src/renderer/App.tsx`
- Create: `Electron/src/renderer/api.ts`
- Create: `Electron/src/renderer/stores/settingsStore.ts`
- Create: `Electron/src/renderer/routes/Dashboard.tsx`
- Create: `Electron/src/renderer/routes/Sessions.tsx`
- Create: `Electron/src/renderer/routes/IndexStatus.tsx`
- Create: `Electron/src/renderer/routes/Settings.tsx`
- Create: `Electron/src/renderer/components/Layout.tsx`
- Create: `Electron/src/renderer/components/TokenTrendChart.tsx`
- Create: `Electron/src/renderer/components/SessionTable.tsx`
- Create: `Electron/src/renderer/styles.css`
- Create: `Electron/src/**/*.test.ts` and `Electron/src/**/*.test.tsx` as specified below.

### Scripts and docs

- Modify: `scripts/package-dev-app.sh`
  - Keep Swift app packaging working.
  - Add a separate Electron dev instruction, not a hard build dependency for the menu bar app.
- Modify: `README.md`
  - Add Phase 2 development commands and privacy note.
- Modify: `config/token-meter.example.json`
  - Keep JSON import-compatible, mark SQLite settings as runtime source in comments only if JSON supports no comments; otherwise README documents it.

---

## Task 1: Add SQLite C binding and migration foundation

**Files:**
- Modify: `Package.swift`
- Create: `Sources/CSQLite/module.modulemap`
- Create: `Sources/TokenMeterCore/SQLiteDatabase.swift`
- Create: `Sources/TokenMeterCore/TokenMeterDatabaseSchema.swift`
- Create: `Sources/TokenMeterCore/TokenMeterDatabaseMigrator.swift`
- Test: `Tests/TokenMeterCoreTests/SQLiteDatabaseTests.swift`
- Test: `Tests/TokenMeterCoreTests/TokenMeterDatabaseMigratorTests.swift`

- [ ] **Step 1: Write failing SQLite open/query test**

Create `Tests/TokenMeterCoreTests/SQLiteDatabaseTests.swift`:

```swift
import XCTest
@testable import TokenMeterCore

final class SQLiteDatabaseTests: XCTestCase {
    func testOpensInMemoryDatabaseAndUsesParameters() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try database.execute("CREATE TABLE values_table (id INTEGER PRIMARY KEY, value TEXT NOT NULL)")
        try database.execute("INSERT INTO values_table (value) VALUES (?)", [.text("'; DROP TABLE values_table; --")])

        let rows = try database.query("SELECT value FROM values_table WHERE value = ?", [.text("'; DROP TABLE values_table; --")])

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].string("value"), "'; DROP TABLE values_table; --")
        XCTAssertEqual(try database.query("SELECT count(*) AS count FROM values_table")[0].int("count"), 1)
    }
}
```

- [ ] **Step 2: Run test and verify it fails**

Run:

```bash
swift test --filter SQLiteDatabaseTests/testOpensInMemoryDatabaseAndUsesParameters
```

Expected: FAIL because `SQLiteDatabase` does not exist.

- [ ] **Step 3: Add SQLite target to Package.swift**

Modify `Package.swift` so targets become:

```swift
targets: [
    .systemLibrary(
        name: "CSQLite",
        providers: [
            .brew(["sqlite"])
        ]
    ),
    .target(
        name: "TokenMeterCore",
        dependencies: ["CSQLite"],
        linkerSettings: [
            .linkedLibrary("sqlite3")
        ]
    ),
    .executableTarget(
        name: "TokenMeterApp",
        dependencies: [
            "TokenMeterCore"
        ],
        resources: [
            .process("Resources")
        ]
    ),
    .testTarget(
        name: "TokenMeterCoreTests",
        dependencies: ["TokenMeterCore"]
    )
]
```

Create `Sources/CSQLite/module.modulemap`:

```c
module CSQLite [system] {
  header "sqlite3.h"
  link "sqlite3"
  export *
}
```

- [ ] **Step 4: Implement minimal SQLite wrapper**

Create `Sources/TokenMeterCore/SQLiteDatabase.swift`:

```swift
import CSQLite
import Foundation

public enum SQLiteValue: Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
}

public struct SQLiteRow: Equatable {
    private let values: [String: SQLiteValue]

    public init(values: [String: SQLiteValue]) {
        self.values = values
    }

    public func int(_ column: String) -> Int64? {
        if case let .int(value)? = values[column] { return value }
        return nil
    }

    public func string(_ column: String) -> String? {
        if case let .text(value)? = values[column] { return value }
        return nil
    }
}

public final class SQLiteDatabase {
    private var handle: OpaquePointer?

    public init(path: String) throws {
        if sqlite3_open_v2(path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite open failed"
            throw SQLiteDatabaseError.openFailed(message)
        }
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA busy_timeout = 5000")
    }

    deinit {
        if let handle {
            sqlite3_close(handle)
        }
    }

    public func execute(_ sql: String, _ parameters: [SQLiteValue] = []) throws {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw SQLiteDatabaseError.stepFailed(errorMessage)
        }
    }

    public func query(_ sql: String, _ parameters: [SQLiteValue] = []) throws -> [SQLiteRow] {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        var rows: [SQLiteRow] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw SQLiteDatabaseError.stepFailed(errorMessage) }

            var values: [String: SQLiteValue] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER:
                    values[name] = .int(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT:
                    values[name] = .double(sqlite3_column_double(statement, index))
                case SQLITE_TEXT:
                    values[name] = .text(String(cString: sqlite3_column_text(statement, index)))
                case SQLITE_NULL:
                    values[name] = .null
                default:
                    values[name] = .null
                }
            }
            rows.append(SQLiteRow(values: values))
        }
    }

    private func prepare(_ sql: String, _ parameters: [SQLiteValue]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteDatabaseError.prepareFailed(errorMessage)
        }
        for (offset, parameter) in parameters.enumerated() {
            try bind(parameter, to: Int32(offset + 1), statement: statement)
        }
        return statement
    }

    private func bind(_ value: SQLiteValue, to index: Int32, statement: OpaquePointer?) throws {
        let result: Int32
        switch value {
        case .null:
            result = sqlite3_bind_null(statement, index)
        case let .int(value):
            result = sqlite3_bind_int64(statement, index, value)
        case let .double(value):
            result = sqlite3_bind_double(statement, index, value)
        case let .text(value):
            result = sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
        }
        guard result == SQLITE_OK else { throw SQLiteDatabaseError.bindFailed(errorMessage) }
    }

    private var errorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite error"
    }
}

public enum SQLiteDatabaseError: Error, Equatable {
    case openFailed(String)
    case prepareFailed(String)
    case bindFailed(String)
    case stepFailed(String)
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
```

- [ ] **Step 5: Run SQLite wrapper test and verify it passes**

Run:

```bash
swift test --filter SQLiteDatabaseTests/testOpensInMemoryDatabaseAndUsesParameters
```

Expected: PASS.

- [ ] **Step 6: Write failing migration test**

Create `Tests/TokenMeterCoreTests/TokenMeterDatabaseMigratorTests.swift`:

```swift
import XCTest
@testable import TokenMeterCore

final class TokenMeterDatabaseMigratorTests: XCTestCase {
    func testMigratesPhaseTwoSchemaAndEnablesWAL() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("tokenmeter.sqlite")
        let database = try SQLiteDatabase(path: url.path)

        try TokenMeterDatabaseMigrator.migrate(database)

        XCTAssertEqual(try database.query("PRAGMA user_version")[0].int("user_version"), 1)
        XCTAssertEqual(try database.query("PRAGMA journal_mode")[0].string("journal_mode"), "wal")
        XCTAssertEqual(try database.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'agent_sessions'").count, 1)
        XCTAssertEqual(try database.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'session_usage_latest'").count, 1)
    }
}
```

- [ ] **Step 7: Run migration test and verify it fails**

Run:

```bash
swift test --filter TokenMeterDatabaseMigratorTests/testMigratesPhaseTwoSchemaAndEnablesWAL
```

Expected: FAIL because `TokenMeterDatabaseMigrator` does not exist.

- [ ] **Step 8: Implement schema constants and migrator**

Create `Sources/TokenMeterCore/TokenMeterDatabaseSchema.swift`:

```swift
public enum TokenMeterDatabaseSchema {
    public static let currentVersion: Int64 = 1

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
      UNIQUE(session_id, source_offset)
    );

    CREATE TABLE IF NOT EXISTS session_usage_latest (
      session_id INTEGER PRIMARY KEY REFERENCES agent_sessions(id) ON DELETE CASCADE,
      session_usage_id INTEGER NOT NULL UNIQUE REFERENCES session_usage(id) ON DELETE CASCADE,
      updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
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
    CREATE INDEX IF NOT EXISTS idx_daily_project_provider_date ON provider_daily_usage(project_id, provider_id, usage_date DESC);
    CREATE INDEX IF NOT EXISTS idx_settings_updated ON settings(updated_at DESC);

    INSERT OR IGNORE INTO schema_migrations(version, name) VALUES (1, 'phase2_hybrid_sessions');
    PRAGMA user_version = 1;
    """
}
```

Create `Sources/TokenMeterCore/TokenMeterDatabaseMigrator.swift`:

```swift
public enum TokenMeterDatabaseMigrator {
    public static func migrate(_ database: SQLiteDatabase) throws {
        try database.execute("PRAGMA journal_mode = WAL")
        try database.execute("PRAGMA synchronous = NORMAL")
        try database.execute("PRAGMA foreign_keys = ON")
        try database.execute("PRAGMA temp_store = MEMORY")
        try database.execute("PRAGMA busy_timeout = 5000")
        try database.execute(TokenMeterDatabaseSchema.v1)
    }
}
```

- [ ] **Step 9: Run migration test and verify it passes**

Run:

```bash
swift test --filter TokenMeterDatabaseMigratorTests/testMigratesPhaseTwoSchemaAndEnablesWAL
```

Expected: PASS.

- [ ] **Step 10: Run scoped database tests**

Run:

```bash
swift test --filter SQLiteDatabaseTests && swift test --filter TokenMeterDatabaseMigratorTests
```

Expected: PASS.

- [ ] **Step 11: Commit**

```bash
git add Package.swift Sources/CSQLite Sources/TokenMeterCore/SQLiteDatabase.swift Sources/TokenMeterCore/TokenMeterDatabaseSchema.swift Sources/TokenMeterCore/TokenMeterDatabaseMigrator.swift Tests/TokenMeterCoreTests/SQLiteDatabaseTests.swift Tests/TokenMeterCoreTests/TokenMeterDatabaseMigratorTests.swift
git commit -m "feat: add sqlite foundation"
```

---

## Task 2: Add settings repository and JSON config migration

**Files:**
- Create: `Sources/TokenMeterCore/TokenMeterPaths.swift`
- Create: `Sources/TokenMeterCore/SettingsModels.swift`
- Create: `Sources/TokenMeterCore/SettingsStore.swift`
- Modify: `Sources/TokenMeterCore/ProviderConfig.swift`
- Test: `Tests/TokenMeterCoreTests/SettingsStoreTests.swift`

- [ ] **Step 1: Write failing default paths and settings tests**

Create `Tests/TokenMeterCoreTests/SettingsStoreTests.swift`:

```swift
import XCTest
@testable import TokenMeterCore

final class SettingsStoreTests: XCTestCase {
    func testImportsTokenMeterConfigIntoSQLiteSettings() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)
        let store = SettingsStore(database: database)
        let config = TokenMeterConfig(
            menuBar: MenuBarConfig(primaryProviderId: "codex"),
            providers: [
                ProviderConfig(id: "codex", type: .codex, displayName: "Codex", enabled: true, credential: nil, endpoint: nil, manualUsage: nil),
                ProviderConfig(id: "claude-code", type: .claudeCode, displayName: "Claude Code", enabled: false, credential: nil, endpoint: nil, manualUsage: nil)
            ]
        )

        try store.importConfigIfNeeded(config)
        let snapshot = try store.snapshot()

        XCTAssertEqual(snapshot.version, 1)
        XCTAssertEqual(snapshot.menuBarPrimaryProviderId, "codex")
        XCTAssertEqual(snapshot.providerOverrides.first { $0.providerId == "codex" }?.enabled, true)
        XCTAssertEqual(snapshot.providerOverrides.first { $0.providerId == "claude-code" }?.enabled, false)
    }

    func testRejectsStaleSettingsPatch() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)
        let store = SettingsStore(database: database)
        try store.importConfigIfNeeded(ProviderConfigLoader.defaultConfig())

        XCTAssertThrowsError(
            try store.apply(SettingsPatch(menuBarPrimaryProviderId: "zhipu"), expectedVersion: 0, updatedBy: .electron)
        )
    }
}
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
swift test --filter SettingsStoreTests
```

Expected: FAIL because `SettingsStore`, `SettingsPatch`, and `SettingsSnapshot` do not exist.

- [ ] **Step 3: Implement shared paths**

Create `Sources/TokenMeterCore/TokenMeterPaths.swift`:

```swift
import Foundation

public enum TokenMeterPaths {
    public static func baseDirectory(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent(".token-meter", isDirectory: true)
    }

    public static func databaseURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        baseDirectory(homeDirectory: homeDirectory).appendingPathComponent("tokenmeter.sqlite")
    }

    public static func legacyConfigURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        baseDirectory(homeDirectory: homeDirectory).appendingPathComponent("config.json")
    }

    public static func legacySnapshotCacheURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        baseDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent("provider-snapshots.json")
    }

    public static func socketURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        baseDirectory(homeDirectory: homeDirectory).appendingPathComponent("tokenmeter.sock")
    }
}
```

- [ ] **Step 4: Implement settings models**

Create `Sources/TokenMeterCore/SettingsModels.swift`:

```swift
import Foundation

public enum SettingsUpdatedBy: String, Codable, Equatable {
    case swift
    case electron
    case migrator
    case importer
}

public struct ProviderConfigOverride: Codable, Equatable {
    public let providerId: String
    public let enabled: Bool?
    public let displayName: String?
    public let menuRank: Int?
    public let showInMenuBar: Bool?
    public let showInCharts: Bool?
}

public struct SettingsSnapshot: Codable, Equatable {
    public let version: Int
    public let menuBarPrimaryProviderId: String?
    public let autoRefreshSeconds: Int
    public let enabledAgentKinds: [String]
    public let providerOverrides: [ProviderConfigOverride]
}

public struct SettingsPatch: Codable, Equatable {
    public let menuBarPrimaryProviderId: String?
    public let autoRefreshSeconds: Int?
    public let enabledAgentKinds: [String]?

    public init(menuBarPrimaryProviderId: String? = nil, autoRefreshSeconds: Int? = nil, enabledAgentKinds: [String]? = nil) {
        self.menuBarPrimaryProviderId = menuBarPrimaryProviderId
        self.autoRefreshSeconds = autoRefreshSeconds
        self.enabledAgentKinds = enabledAgentKinds
    }
}

public struct SettingsApplyRequest: Codable, Equatable {
    public let requestedVersion: Int
    public let status: String
}

public enum SettingsStoreError: Error, Equatable {
    case staleVersion(expected: Int, actual: Int)
    case invalidValue(String)
}
```

- [ ] **Step 5: Implement settings store**

Create `Sources/TokenMeterCore/SettingsStore.swift`:

```swift
import Foundation

public final class SettingsStore {
    private let database: SQLiteDatabase
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    public func importConfigIfNeeded(_ config: TokenMeterConfig) throws {
        let count = try database.query("SELECT count(*) AS count FROM settings")[0].int("count") ?? 0
        guard count == 0 else { return }
        try database.execute("BEGIN IMMEDIATE")
        do {
            try set("menuBar.primaryProviderId", value: .text(config.menuBar.primaryProviderId ?? ""), version: 1, updatedBy: .importer)
            try set("scan.autoRefreshSeconds", value: .int(300), version: 1, updatedBy: .importer)
            try set("filters.enabledAgentKinds", value: .text(jsonString(["claudeCode", "codex", "opencode", "omp"])), version: 1, updatedBy: .importer)
            for (index, provider) in config.providers.enumerated() {
                try database.execute(
                    """
                    INSERT OR REPLACE INTO provider_config_overrides(provider_id, enabled, display_name, menu_rank, show_in_menu_bar, show_in_charts)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(provider.id),
                        .int(provider.enabled ? 1 : 0),
                        .text(provider.displayName),
                        .int(Int64(index)),
                        .int(provider.enabled ? 1 : 0),
                        .int(provider.enabled ? 1 : 0)
                    ]
                )
            }
            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
    }

    public func snapshot() throws -> SettingsSnapshot {
        let version = Int(try database.query("SELECT coalesce(max(version), 0) AS version FROM settings")[0].int("version") ?? 0)
        let primary = settingString("menuBar.primaryProviderId")
        let refresh = Int(settingInt("scan.autoRefreshSeconds") ?? 300)
        let enabledAgents = decodeStringArray(settingString("filters.enabledAgentKinds") ?? "[]")
        let providerRows = try database.query(
            "SELECT provider_id, enabled, display_name, menu_rank, show_in_menu_bar, show_in_charts FROM provider_config_overrides ORDER BY menu_rank ASC"
        )
        let providers = providerRows.map { row in
            ProviderConfigOverride(
                providerId: row.string("provider_id") ?? "",
                enabled: row.int("enabled").map { $0 == 1 },
                displayName: row.string("display_name"),
                menuRank: row.int("menu_rank").map(Int.init),
                showInMenuBar: row.int("show_in_menu_bar").map { $0 == 1 },
                showInCharts: row.int("show_in_charts").map { $0 == 1 }
            )
        }
        return SettingsSnapshot(version: version, menuBarPrimaryProviderId: primary?.isEmpty == true ? nil : primary, autoRefreshSeconds: refresh, enabledAgentKinds: enabledAgents, providerOverrides: providers)
    }

    public func apply(_ patch: SettingsPatch, expectedVersion: Int, updatedBy: SettingsUpdatedBy) throws -> SettingsApplyRequest {
        let current = try snapshot()
        guard current.version == expectedVersion else {
            throw SettingsStoreError.staleVersion(expected: expectedVersion, actual: current.version)
        }
        let nextVersion = expectedVersion + 1
        try database.execute("BEGIN IMMEDIATE")
        do {
            if let primary = patch.menuBarPrimaryProviderId {
                try set("menuBar.primaryProviderId", value: .text(primary), version: nextVersion, updatedBy: updatedBy)
            }
            if let refresh = patch.autoRefreshSeconds {
                guard refresh >= 30 else { throw SettingsStoreError.invalidValue("scan.autoRefreshSeconds must be >= 30") }
                try set("scan.autoRefreshSeconds", value: .int(Int64(refresh)), version: nextVersion, updatedBy: updatedBy)
            }
            if let agents = patch.enabledAgentKinds {
                try set("filters.enabledAgentKinds", value: .text(jsonString(agents)), version: nextVersion, updatedBy: updatedBy)
            }
            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
        return SettingsApplyRequest(requestedVersion: nextVersion, status: "pending")
    }

    private func set(_ key: String, value: SQLiteValue, version: Int, updatedBy: SettingsUpdatedBy) throws {
        let valueJSON: String
        let type: String
        switch value {
        case let .text(text):
            valueJSON = jsonString(text)
            type = "string"
        case let .int(int):
            valueJSON = String(int)
            type = "int"
        case let .double(double):
            valueJSON = String(double)
            type = "int"
        case .null:
            valueJSON = "null"
            type = "json"
        }
        try database.execute(
            "INSERT OR REPLACE INTO settings(key, value_json, value_type, version, updated_by) VALUES (?, ?, ?, ?, ?)",
            [.text(key), .text(valueJSON), .text(type), .int(Int64(version)), .text(updatedBy.rawValue)]
        )
    }

    private func settingString(_ key: String) -> String? {
        guard let row = try? database.query("SELECT value_json, value_type FROM settings WHERE key = ?", [.text(key)]).first else { return nil }
        guard row.string("value_type") == "string", let value = row.string("value_json") else { return nil }
        return try? decoder.decode(String.self, from: Data(value.utf8))
    }

    private func settingInt(_ key: String) -> Int64? {
        guard let row = try? database.query("SELECT value_json FROM settings WHERE key = ?", [.text(key)]).first else { return nil }
        return row.string("value_json").flatMap(Int64.init)
    }

    private func jsonString<T: Encodable>(_ value: T) -> String {
        let data = (try? encoder.encode(value)) ?? Data("null".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private func decodeStringArray(_ json: String) -> [String] {
        (try? decoder.decode([String].self, from: Data(json.utf8))) ?? []
    }
}
```

- [ ] **Step 6: Run settings tests and verify they pass**

Run:

```bash
swift test --filter SettingsStoreTests
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/TokenMeterCore/TokenMeterPaths.swift Sources/TokenMeterCore/SettingsModels.swift Sources/TokenMeterCore/SettingsStore.swift Tests/TokenMeterCoreTests/SettingsStoreTests.swift
git commit -m "feat: add sqlite settings store"
```

---

## Task 3: Add local agent models, streaming JSONL reader, and file change detector

**Files:**
- Create: `Sources/TokenMeterCore/LocalAgentModels.swift`
- Create: `Sources/TokenMeterCore/JSONLStreamReader.swift`
- Create: `Sources/TokenMeterCore/SourceFileChangeDetector.swift`
- Test: `Tests/TokenMeterCoreTests/JSONLStreamReaderTests.swift`
- Test: `Tests/TokenMeterCoreTests/SourceFileChangeDetectorTests.swift`

- [ ] **Step 1: Write failing JSONL streaming test**

Create `Tests/TokenMeterCoreTests/JSONLStreamReaderTests.swift`:

```swift
import XCTest
@testable import TokenMeterCore

final class JSONLStreamReaderTests: XCTestCase {
    func testReadsCompleteLinesAndReturnsResidualIncompleteLine() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("session.jsonl")
        try Data("{\"a\":1}\n{\"b\":2}".utf8).write(to: file)

        let result = try JSONLStreamReader.readLines(from: file, startingAt: 0)

        XCTAssertEqual(result.lines.map(\.text), ["{\"a\":1}"])
        XCTAssertEqual(result.residual, "{\"b\":2}")
        XCTAssertGreaterThan(result.nextOffset, 0)
    }
}
```

- [ ] **Step 2: Write failing file change detector test**

Create `Tests/TokenMeterCoreTests/SourceFileChangeDetectorTests.swift`:

```swift
import XCTest
@testable import TokenMeterCore

final class SourceFileChangeDetectorTests: XCTestCase {
    func testClassifiesUnchangedAppendAndRewrite() {
        let previous = SourceFileFingerprint(dev: 1, inode: 10, sizeBytes: 100, mtimeNanoseconds: 1_000, tailHash: "old")

        XCTAssertEqual(
            SourceFileChangeDetector.change(previous: previous, current: previous),
            .unchanged
        )
        XCTAssertEqual(
            SourceFileChangeDetector.change(previous: previous, current: SourceFileFingerprint(dev: 1, inode: 10, sizeBytes: 150, mtimeNanoseconds: 2_000, tailHash: "old")),
            .appended
        )
        XCTAssertEqual(
            SourceFileChangeDetector.change(previous: previous, current: SourceFileFingerprint(dev: 1, inode: 10, sizeBytes: 80, mtimeNanoseconds: 2_000, tailHash: "new")),
            .rewritten
        )
    }
}
```

- [ ] **Step 3: Run tests and verify they fail**

Run:

```bash
swift test --filter JSONLStreamReaderTests && swift test --filter SourceFileChangeDetectorTests
```

Expected: FAIL because new types do not exist.

- [ ] **Step 4: Implement local agent models**

Create `Sources/TokenMeterCore/LocalAgentModels.swift`:

```swift
import Foundation

public enum LocalAgentKind: String, Codable, Equatable, CaseIterable {
    case claudeCode
    case codex
    case opencode
    case omp
}

public enum SourceKind: String, Codable, Equatable {
    case claudeJSONL = "claude_jsonl"
    case codexJSONL = "codex_jsonl"
    case ompJSONL = "omp_jsonl"
    case opencodeSQLite = "opencode_sqlite"
}

public struct SourceFileFingerprint: Codable, Equatable {
    public let dev: UInt64?
    public let inode: UInt64?
    public let sizeBytes: Int64
    public let mtimeNanoseconds: Int64
    public let tailHash: String?

    public init(dev: UInt64?, inode: UInt64?, sizeBytes: Int64, mtimeNanoseconds: Int64, tailHash: String?) {
        self.dev = dev
        self.inode = inode
        self.sizeBytes = sizeBytes
        self.mtimeNanoseconds = mtimeNanoseconds
        self.tailHash = tailHash
    }
}

public struct ParsedSessionUsage: Codable, Equatable {
    public let inputTokens: Int64?
    public let outputTokens: Int64?
    public let reasoningTokens: Int64?
    public let cacheReadTokens: Int64?
    public let cacheWriteTokens: Int64?
    public let costUSDMicros: Int64?

    public var totalTokens: Int64 {
        (inputTokens ?? 0) + (outputTokens ?? 0) + (reasoningTokens ?? 0) + (cacheReadTokens ?? 0) + (cacheWriteTokens ?? 0)
    }
}

public struct ParsedAgentSession: Codable, Equatable {
    public let sourceKind: SourceKind
    public let sessionKey: String
    public let projectPath: String?
    public let modelName: String?
    public let cliVersion: String?
    public let startedAt: Date?
    public let updatedAt: Date?
    public let usage: ParsedSessionUsage?
    public let usageSequence: Int
    public let sourceOffset: Int64?
    public let rawMeta: [String: String]
}
```

- [ ] **Step 5: Implement JSONL stream reader**

Create `Sources/TokenMeterCore/JSONLStreamReader.swift`:

```swift
import Foundation

public struct JSONLLine: Equatable {
    public let text: String
    public let offset: Int64
    public let nextOffset: Int64
}

public struct JSONLReadResult: Equatable {
    public let lines: [JSONLLine]
    public let nextOffset: Int64
    public let residual: String?
}

public enum JSONLStreamReader {
    public static func readLines(from url: URL, startingAt offset: Int64) throws -> JSONLReadResult {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.readToEnd() ?? Data()
        guard !data.isEmpty else {
            return JSONLReadResult(lines: [], nextOffset: offset, residual: nil)
        }
        let text = String(decoding: data, as: UTF8.self)
        let hasFinalNewline = text.hasSuffix("\n")
        var parts = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let residual = hasFinalNewline ? nil : parts.popLast()
        var currentOffset = offset
        var lines: [JSONLLine] = []
        for part in parts where !part.isEmpty {
            let lineByteCount = part.data(using: .utf8)?.count ?? part.utf8.count
            let nextOffset = currentOffset + Int64(lineByteCount) + 1
            lines.append(JSONLLine(text: part, offset: currentOffset, nextOffset: nextOffset))
            currentOffset = nextOffset
        }
        return JSONLReadResult(lines: lines, nextOffset: currentOffset, residual: residual?.isEmpty == true ? nil : residual)
    }
}
```

- [ ] **Step 6: Implement change detector**

Create `Sources/TokenMeterCore/SourceFileChangeDetector.swift`:

```swift
public enum SourceFileChange: Equatable {
    case unchanged
    case appended
    case rewritten
    case moved
}

public enum SourceFileChangeDetector {
    public static func change(previous: SourceFileFingerprint, current: SourceFileFingerprint) -> SourceFileChange {
        if previous == current {
            return .unchanged
        }
        if previous.dev == current.dev,
           previous.inode == current.inode,
           current.sizeBytes > previous.sizeBytes,
           previous.tailHash == current.tailHash {
            return .appended
        }
        if previous.dev == current.dev,
           previous.inode == current.inode,
           current.sizeBytes >= previous.sizeBytes,
           previous.tailHash == current.tailHash {
            return .appended
        }
        return .rewritten
    }
}
```

- [ ] **Step 7: Run tests and verify they pass**

Run:

```bash
swift test --filter JSONLStreamReaderTests && swift test --filter SourceFileChangeDetectorTests
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/TokenMeterCore/LocalAgentModels.swift Sources/TokenMeterCore/JSONLStreamReader.swift Sources/TokenMeterCore/SourceFileChangeDetector.swift Tests/TokenMeterCoreTests/JSONLStreamReaderTests.swift Tests/TokenMeterCoreTests/SourceFileChangeDetectorTests.swift
git commit -m "feat: add local session scanning primitives"
```

---

## Task 4: Implement Codex JSONL session parser

**Files:**
- Create: `Sources/TokenMeterCore/LocalAgentSessionParsers.swift`
- Create: `Sources/TokenMeterCore/CodexSessionParser.swift`
- Test: `Tests/TokenMeterCoreTests/CodexSessionParserTests.swift`
- Test: `Tests/TokenMeterCoreTests/PrivacyIndexingTests.swift`

- [ ] **Step 1: Write failing Codex parser test**

Create `Tests/TokenMeterCoreTests/CodexSessionParserTests.swift`:

```swift
import XCTest
@testable import TokenMeterCore

final class CodexSessionParserTests: XCTestCase {
    func testParsesSessionMetaTurnContextAndLatestTokenCount() throws {
        let lines = [
            JSONLLine(text: #"{"type":"session_meta","payload":{"id":"session-1","timestamp":"2026-07-03T01:00:00Z","cwd":"/Users/luwei/code/ai/token-meter"}}"#, offset: 0, nextOffset: 1),
            JSONLLine(text: #"{"type":"turn_context","payload":{"model":"gpt-5.3","cwd":"/Users/luwei/code/ai/token-meter"}}"#, offset: 1, nextOffset: 2),
            JSONLLine(text: #"{"type":"event_msg","timestamp":"2026-07-03T01:05:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":30,"reasoning_output_tokens":7}}}}"#, offset: 2, nextOffset: 3)
        ]

        let parsed = try CodexSessionParser().parse(lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/codex.jsonl"))

        XCTAssertEqual(parsed.sessionKey, "session-1")
        XCTAssertEqual(parsed.projectPath, "/Users/luwei/code/ai/token-meter")
        XCTAssertEqual(parsed.modelName, "gpt-5.3")
        XCTAssertEqual(parsed.usage?.inputTokens, 100)
        XCTAssertEqual(parsed.usage?.cacheReadTokens, 20)
        XCTAssertEqual(parsed.usage?.outputTokens, 30)
        XCTAssertEqual(parsed.usage?.reasoningTokens, 7)
        XCTAssertEqual(parsed.sourceOffset, 2)
    }
}
```

- [ ] **Step 2: Add failing privacy test**

Append to `Tests/TokenMeterCoreTests/PrivacyIndexingTests.swift`:

```swift
import XCTest
@testable import TokenMeterCore

final class PrivacyIndexingTests: XCTestCase {
    func testCodexParserDoesNotCopyMessageTextIntoRawMetadata() throws {
        let lines = [
            JSONLLine(text: #"{"type":"session_meta","payload":{"id":"session-privacy","cwd":"/repo"}}"#, offset: 0, nextOffset: 1),
            JSONLLine(text: #"{"type":"event_msg","payload":{"type":"message","content":"SECRET_PROMPT_SHOULD_NOT_BE_INDEXED"}}"#, offset: 1, nextOffset: 2),
            JSONLLine(text: #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,"output_tokens":2}}}}"#, offset: 2, nextOffset: 3)
        ]

        let parsed = try CodexSessionParser().parse(lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/codex.jsonl"))

        XCTAssertFalse(parsed.rawMeta.values.contains { $0.contains("SECRET_PROMPT_SHOULD_NOT_BE_INDEXED") })
    }
}
```

- [ ] **Step 3: Run tests and verify they fail**

Run:

```bash
swift test --filter CodexSessionParserTests && swift test --filter PrivacyIndexingTests/testCodexParserDoesNotCopyMessageTextIntoRawMetadata
```

Expected: FAIL because `CodexSessionParser` does not exist.

- [ ] **Step 4: Implement parser protocol**

Create `Sources/TokenMeterCore/LocalAgentSessionParsers.swift`:

```swift
import Foundation

public protocol LocalAgentSessionParser {
    func parse(lines: [JSONLLine], sourceURL: URL) throws -> ParsedAgentSession
}

public enum LocalAgentParserError: Error, Equatable {
    case missingSessionKey
    case unsupportedFormat
}

enum JSONDictionary {
    static func object(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    static func dictionary(_ object: [String: Any], _ key: String) -> [String: Any]? {
        object[key] as? [String: Any]
    }

    static func string(_ object: [String: Any], _ key: String) -> String? {
        object[key] as? String
    }

    static func int64(_ object: [String: Any], _ key: String) -> Int64? {
        if let value = object[key] as? Int { return Int64(value) }
        if let value = object[key] as? Int64 { return value }
        if let value = object[key] as? Double { return Int64(value) }
        return nil
    }
}
```

- [ ] **Step 5: Implement Codex parser**

Create `Sources/TokenMeterCore/CodexSessionParser.swift`:

```swift
import Foundation

public struct CodexSessionParser: LocalAgentSessionParser {
    public init() {}

    public func parse(lines: [JSONLLine], sourceURL: URL) throws -> ParsedAgentSession {
        var sessionKey: String?
        var projectPath: String?
        var model: String?
        var startedAt: Date?
        var updatedAt: Date?
        var usage: ParsedSessionUsage?
        var usageSequence = 0
        var usageOffset: Int64?
        let formatter = ISO8601DateFormatter()

        for line in lines {
            guard let object = JSONDictionary.object(from: line.text) else { continue }
            let type = JSONDictionary.string(object, "type")
            if let timestamp = JSONDictionary.string(object, "timestamp").flatMap(formatter.date(from:)) {
                updatedAt = timestamp
            }

            if type == "session_meta", let payload = JSONDictionary.dictionary(object, "payload") {
                sessionKey = JSONDictionary.string(payload, "id") ?? JSONDictionary.string(payload, "session_id") ?? sessionKey
                projectPath = JSONDictionary.string(payload, "cwd") ?? projectPath
                if let timestamp = JSONDictionary.string(payload, "timestamp").flatMap(formatter.date(from:)) {
                    startedAt = timestamp
                    updatedAt = timestamp
                }
            }

            if type == "turn_context", let payload = JSONDictionary.dictionary(object, "payload") {
                model = JSONDictionary.string(payload, "model") ?? model
                projectPath = JSONDictionary.string(payload, "cwd") ?? projectPath
            }

            if type == "event_msg",
               let payload = JSONDictionary.dictionary(object, "payload"),
               JSONDictionary.string(payload, "type") == "token_count",
               let info = JSONDictionary.dictionary(payload, "info"),
               let total = JSONDictionary.dictionary(info, "total_token_usage") {
                usageSequence += 1
                usageOffset = line.offset
                usage = ParsedSessionUsage(
                    inputTokens: JSONDictionary.int64(total, "input_tokens"),
                    outputTokens: JSONDictionary.int64(total, "output_tokens"),
                    reasoningTokens: JSONDictionary.int64(total, "reasoning_output_tokens"),
                    cacheReadTokens: JSONDictionary.int64(total, "cached_input_tokens"),
                    cacheWriteTokens: JSONDictionary.int64(total, "cache_creation_input_tokens"),
                    costUSDMicros: nil
                )
            }
        }

        guard let sessionKey else { throw LocalAgentParserError.missingSessionKey }
        return ParsedAgentSession(
            sourceKind: .codexJSONL,
            sessionKey: sessionKey,
            projectPath: projectPath,
            modelName: model,
            cliVersion: nil,
            startedAt: startedAt,
            updatedAt: updatedAt,
            usage: usage,
            usageSequence: usageSequence,
            sourceOffset: usageOffset,
            rawMeta: ["source": "codex"]
        )
    }
}
```

- [ ] **Step 6: Run Codex and privacy tests**

Run:

```bash
swift test --filter CodexSessionParserTests && swift test --filter PrivacyIndexingTests/testCodexParserDoesNotCopyMessageTextIntoRawMetadata
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/TokenMeterCore/LocalAgentSessionParsers.swift Sources/TokenMeterCore/CodexSessionParser.swift Tests/TokenMeterCoreTests/CodexSessionParserTests.swift Tests/TokenMeterCoreTests/PrivacyIndexingTests.swift
git commit -m "feat: parse codex session usage"
```

---

## Task 5: Implement Claude Code and OMP JSONL parsers

**Files:**
- Create: `Sources/TokenMeterCore/ClaudeCodeSessionParser.swift`
- Create: `Sources/TokenMeterCore/OmpSessionParser.swift`
- Test: `Tests/TokenMeterCoreTests/ClaudeCodeSessionParserTests.swift`
- Test: `Tests/TokenMeterCoreTests/OmpSessionParserTests.swift`
- Modify: `Tests/TokenMeterCoreTests/PrivacyIndexingTests.swift`

- [ ] **Step 1: Write failing Claude parser test**

Create `Tests/TokenMeterCoreTests/ClaudeCodeSessionParserTests.swift`:

```swift
import XCTest
@testable import TokenMeterCore

final class ClaudeCodeSessionParserTests: XCTestCase {
    func testParsesSessionAndAssistantUsageWithoutBodyText() throws {
        let lines = [
            JSONLLine(text: #"{"type":"summary","summary":"Do not store this as message body","leafUuid":"claude-session-1"}"#, offset: 0, nextOffset: 1),
            JSONLLine(text: #"{"sessionId":"claude-session-1","cwd":"/repo","timestamp":"2026-07-03T02:00:00Z","version":"1.2.3","type":"assistant","message":{"model":"claude-sonnet","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":3,"cache_creation_input_tokens":4},"content":[{"type":"text","text":"SECRET_RESPONSE"}]}}"#, offset: 1, nextOffset: 2)
        ]

        let parsed = try ClaudeCodeSessionParser().parse(lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/claude.jsonl"))

        XCTAssertEqual(parsed.sessionKey, "claude-session-1")
        XCTAssertEqual(parsed.projectPath, "/repo")
        XCTAssertEqual(parsed.modelName, "claude-sonnet")
        XCTAssertEqual(parsed.cliVersion, "1.2.3")
        XCTAssertEqual(parsed.usage?.inputTokens, 10)
        XCTAssertEqual(parsed.usage?.outputTokens, 20)
        XCTAssertEqual(parsed.usage?.cacheReadTokens, 3)
        XCTAssertEqual(parsed.usage?.cacheWriteTokens, 4)
        XCTAssertFalse(parsed.rawMeta.values.contains { $0.contains("SECRET_RESPONSE") })
    }
}
```

- [ ] **Step 2: Write failing OMP parser test**

Create `Tests/TokenMeterCoreTests/OmpSessionParserTests.swift`:

```swift
import XCTest
@testable import TokenMeterCore

final class OmpSessionParserTests: XCTestCase {
    func testParsesSessionModelChangeAndUsage() throws {
        let lines = [
            JSONLLine(text: #"{"type":"session","id":"omp-session-1","cwd":"/repo","timestamp":"2026-07-03T03:00:00Z"}"#, offset: 0, nextOffset: 1),
            JSONLLine(text: #"{"type":"model_change","model":"gpt-5.5","timestamp":"2026-07-03T03:01:00Z"}"#, offset: 1, nextOffset: 2),
            JSONLLine(text: #"{"type":"message","timestamp":"2026-07-03T03:02:00Z","message":{"role":"assistant","content":"SECRET_OMP_RESPONSE","usage":{"inputTokens":11,"outputTokens":22,"cacheReadTokens":5,"cacheWriteTokens":6,"totalTokens":44,"cost":{"total":0.012345}}}}"#, offset: 2, nextOffset: 3)
        ]

        let parsed = try OmpSessionParser().parse(lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/omp.jsonl"))

        XCTAssertEqual(parsed.sessionKey, "omp-session-1")
        XCTAssertEqual(parsed.projectPath, "/repo")
        XCTAssertEqual(parsed.modelName, "gpt-5.5")
        XCTAssertEqual(parsed.usage?.inputTokens, 11)
        XCTAssertEqual(parsed.usage?.outputTokens, 22)
        XCTAssertEqual(parsed.usage?.cacheReadTokens, 5)
        XCTAssertEqual(parsed.usage?.cacheWriteTokens, 6)
        XCTAssertEqual(parsed.usage?.costUSDMicros, 12_345)
        XCTAssertFalse(parsed.rawMeta.values.contains { $0.contains("SECRET_OMP_RESPONSE") })
    }
}
```

- [ ] **Step 3: Run tests and verify they fail**

Run:

```bash
swift test --filter ClaudeCodeSessionParserTests && swift test --filter OmpSessionParserTests
```

Expected: FAIL because parsers do not exist.

- [ ] **Step 4: Implement Claude parser**

Create `Sources/TokenMeterCore/ClaudeCodeSessionParser.swift`:

```swift
import Foundation

public struct ClaudeCodeSessionParser: LocalAgentSessionParser {
    public init() {}

    public func parse(lines: [JSONLLine], sourceURL: URL) throws -> ParsedAgentSession {
        var sessionKey: String?
        var projectPath: String?
        var model: String?
        var version: String?
        var startedAt: Date?
        var updatedAt: Date?
        var usage: ParsedSessionUsage?
        var sequence = 0
        var offset: Int64?
        let formatter = ISO8601DateFormatter()

        for line in lines {
            guard let object = JSONDictionary.object(from: line.text) else { continue }
            sessionKey = JSONDictionary.string(object, "sessionId") ?? JSONDictionary.string(object, "leafUuid") ?? sessionKey
            projectPath = JSONDictionary.string(object, "cwd") ?? projectPath
            version = JSONDictionary.string(object, "version") ?? version
            if let timestamp = JSONDictionary.string(object, "timestamp").flatMap(formatter.date(from:)) {
                if startedAt == nil { startedAt = timestamp }
                updatedAt = timestamp
            }
            guard JSONDictionary.string(object, "type") == "assistant",
                  let message = JSONDictionary.dictionary(object, "message") else { continue }
            model = JSONDictionary.string(message, "model") ?? model
            guard let usageObject = JSONDictionary.dictionary(message, "usage") else { continue }
            sequence += 1
            offset = line.offset
            usage = ParsedSessionUsage(
                inputTokens: JSONDictionary.int64(usageObject, "input_tokens"),
                outputTokens: JSONDictionary.int64(usageObject, "output_tokens"),
                reasoningTokens: nil,
                cacheReadTokens: JSONDictionary.int64(usageObject, "cache_read_input_tokens"),
                cacheWriteTokens: JSONDictionary.int64(usageObject, "cache_creation_input_tokens"),
                costUSDMicros: nil
            )
        }

        guard let sessionKey else { throw LocalAgentParserError.missingSessionKey }
        return ParsedAgentSession(sourceKind: .claudeJSONL, sessionKey: sessionKey, projectPath: projectPath, modelName: model, cliVersion: version, startedAt: startedAt, updatedAt: updatedAt, usage: usage, usageSequence: sequence, sourceOffset: offset, rawMeta: ["source": "claude-code"])
    }
}
```

- [ ] **Step 5: Implement OMP parser**

Create `Sources/TokenMeterCore/OmpSessionParser.swift`:

```swift
import Foundation

public struct OmpSessionParser: LocalAgentSessionParser {
    public init() {}

    public func parse(lines: [JSONLLine], sourceURL: URL) throws -> ParsedAgentSession {
        var sessionKey: String?
        var projectPath: String?
        var model: String?
        var startedAt: Date?
        var updatedAt: Date?
        var usage: ParsedSessionUsage?
        var sequence = 0
        var offset: Int64?
        let formatter = ISO8601DateFormatter()

        for line in lines {
            guard let object = JSONDictionary.object(from: line.text) else { continue }
            let type = JSONDictionary.string(object, "type")
            if let timestamp = JSONDictionary.string(object, "timestamp").flatMap(formatter.date(from:)) {
                if startedAt == nil { startedAt = timestamp }
                updatedAt = timestamp
            }
            if type == "session" {
                sessionKey = JSONDictionary.string(object, "id") ?? sessionKey
                projectPath = JSONDictionary.string(object, "cwd") ?? projectPath
            }
            if type == "model_change" {
                model = JSONDictionary.string(object, "model") ?? model
            }
            guard type == "message",
                  let message = JSONDictionary.dictionary(object, "message"),
                  let usageObject = JSONDictionary.dictionary(message, "usage") else { continue }
            sequence += 1
            offset = line.offset
            let costMicros: Int64?
            if let cost = JSONDictionary.dictionary(usageObject, "cost"), let total = cost["total"] as? Double {
                costMicros = Int64((total * 1_000_000).rounded())
            } else {
                costMicros = nil
            }
            usage = ParsedSessionUsage(
                inputTokens: JSONDictionary.int64(usageObject, "inputTokens"),
                outputTokens: JSONDictionary.int64(usageObject, "outputTokens"),
                reasoningTokens: nil,
                cacheReadTokens: JSONDictionary.int64(usageObject, "cacheReadTokens"),
                cacheWriteTokens: JSONDictionary.int64(usageObject, "cacheWriteTokens"),
                costUSDMicros: costMicros
            )
        }

        guard let sessionKey else { throw LocalAgentParserError.missingSessionKey }
        return ParsedAgentSession(sourceKind: .ompJSONL, sessionKey: sessionKey, projectPath: projectPath, modelName: model, cliVersion: nil, startedAt: startedAt, updatedAt: updatedAt, usage: usage, usageSequence: sequence, sourceOffset: offset, rawMeta: ["source": "omp"])
    }
}
```

- [ ] **Step 6: Run parser tests**

Run:

```bash
swift test --filter ClaudeCodeSessionParserTests && swift test --filter OmpSessionParserTests
```

Expected: PASS.

- [ ] **Step 7: Run privacy tests**

Run:

```bash
swift test --filter PrivacyIndexingTests
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/TokenMeterCore/ClaudeCodeSessionParser.swift Sources/TokenMeterCore/OmpSessionParser.swift Tests/TokenMeterCoreTests/ClaudeCodeSessionParserTests.swift Tests/TokenMeterCoreTests/OmpSessionParserTests.swift Tests/TokenMeterCoreTests/PrivacyIndexingTests.swift
git commit -m "feat: parse claude and omp session usage"
```

---

## Task 6: Implement OpenCode SQLite high-water adapter

**Files:**
- Create: `Sources/TokenMeterCore/OpenCodeSessionAdapter.swift`
- Test: `Tests/TokenMeterCoreTests/OpenCodeSessionAdapterTests.swift`

- [ ] **Step 1: Write failing OpenCode adapter test**

Create `Tests/TokenMeterCoreTests/OpenCodeSessionAdapterTests.swift`:

```swift
import XCTest
@testable import TokenMeterCore

final class OpenCodeSessionAdapterTests: XCTestCase {
    func testReadsSessionsChangedAfterHighWaterMark() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try database.execute("""
        CREATE TABLE session (
          id TEXT PRIMARY KEY,
          directory TEXT,
          model TEXT,
          agent TEXT,
          time_created TEXT,
          time_updated TEXT,
          tokens_input INTEGER,
          tokens_output INTEGER,
          tokens_reasoning INTEGER,
          tokens_cache_read INTEGER,
          tokens_cache_write INTEGER,
          cost REAL
        )
        """)
        try database.execute("""
        INSERT INTO session(id, directory, model, agent, time_created, time_updated, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, cost)
        VALUES ('s1', '/repo', 'claude-sonnet', 'build', '2026-07-03T00:00:00Z', '2026-07-03T00:10:00Z', 10, 20, 3, 4, 5, 0.012345)
        """)

        let sessions = try OpenCodeSessionAdapter(sourceDatabase: database).changedSessions(after: "2026-07-02T00:00:00Z")

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].sessionKey, "s1")
        XCTAssertEqual(sessions[0].projectPath, "/repo")
        XCTAssertEqual(sessions[0].modelName, "claude-sonnet")
        XCTAssertEqual(sessions[0].usage?.inputTokens, 10)
        XCTAssertEqual(sessions[0].usage?.outputTokens, 20)
        XCTAssertEqual(sessions[0].usage?.reasoningTokens, 3)
        XCTAssertEqual(sessions[0].usage?.cacheReadTokens, 4)
        XCTAssertEqual(sessions[0].usage?.cacheWriteTokens, 5)
        XCTAssertEqual(sessions[0].usage?.costUSDMicros, 12_345)
    }
}
```

- [ ] **Step 2: Run test and verify it fails**

Run:

```bash
swift test --filter OpenCodeSessionAdapterTests
```

Expected: FAIL because `OpenCodeSessionAdapter` does not exist.

- [ ] **Step 3: Implement OpenCode adapter**

Create `Sources/TokenMeterCore/OpenCodeSessionAdapter.swift`:

```swift
import Foundation

public final class OpenCodeSessionAdapter {
    private let sourceDatabase: SQLiteDatabase

    public init(sourceDatabase: SQLiteDatabase) {
        self.sourceDatabase = sourceDatabase
    }

    public func changedSessions(after highWaterMark: String?) throws -> [ParsedAgentSession] {
        let rows = try sourceDatabase.query(
            """
            SELECT id, directory, model, agent, time_created, time_updated,
                   tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, cost
            FROM session
            WHERE (? IS NULL OR time_updated > ?)
            ORDER BY time_updated ASC
            """,
            [.text(highWaterMark ?? ""), .text(highWaterMark ?? "")]
        )
        let formatter = ISO8601DateFormatter()
        return rows.map { row in
            let costMicros: Int64?
            if case let .double(cost)? = Mirror(reflecting: row).children.first(where: { $0.label == "values" }).flatMap({ _ in Optional<SQLiteValue>.none }) {
                costMicros = Int64((cost * 1_000_000).rounded())
            } else {
                costMicros = nil
            }
            return ParsedAgentSession(
                sourceKind: .opencodeSQLite,
                sessionKey: row.string("id") ?? "",
                projectPath: row.string("directory"),
                modelName: row.string("model"),
                cliVersion: nil,
                startedAt: row.string("time_created").flatMap(formatter.date(from:)),
                updatedAt: row.string("time_updated").flatMap(formatter.date(from:)),
                usage: ParsedSessionUsage(
                    inputTokens: row.int("tokens_input"),
                    outputTokens: row.int("tokens_output"),
                    reasoningTokens: row.int("tokens_reasoning"),
                    cacheReadTokens: row.int("tokens_cache_read"),
                    cacheWriteTokens: row.int("tokens_cache_write"),
                    costUSDMicros: costMicros
                ),
                usageSequence: 1,
                sourceOffset: nil,
                rawMeta: ["source": "opencode", "agent": row.string("agent") ?? ""]
            )
        }
    }
}
```

Then fix `SQLiteRow` to expose `double(_:)` cleanly instead of using reflection:

```swift
public func double(_ column: String) -> Double? {
    if case let .double(value)? = values[column] { return value }
    if case let .int(value)? = values[column] { return Double(value) }
    return nil
}
```

Update `OpenCodeSessionAdapter` cost extraction:

```swift
let costMicros = row.double("cost").map { Int64(($0 * 1_000_000).rounded()) }
```

- [ ] **Step 4: Run OpenCode test and verify it passes**

Run:

```bash
swift test --filter OpenCodeSessionAdapterTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/TokenMeterCore/OpenCodeSessionAdapter.swift Sources/TokenMeterCore/SQLiteDatabase.swift Tests/TokenMeterCoreTests/OpenCodeSessionAdapterTests.swift
git commit -m "feat: read opencode session usage incrementally"
```

---

## Task 7: Implement usage repository, latest summaries, and daily rollups

**Files:**
- Create: `Sources/TokenMeterCore/LocalAgentUsageRepository.swift`
- Create: `Sources/TokenMeterCore/MenuBarSummaryRepository.swift`
- Test: `Tests/TokenMeterCoreTests/LocalAgentUsageRepositoryTests.swift`
- Test: `Tests/TokenMeterCoreTests/MenuBarSummaryRepositoryTests.swift`

- [ ] **Step 1: Write failing repository upsert test**

Create `Tests/TokenMeterCoreTests/LocalAgentUsageRepositoryTests.swift`:

```swift
import XCTest
@testable import TokenMeterCore

final class LocalAgentUsageRepositoryTests: XCTestCase {
    func testUpsertsSessionUsageAndLatestPointer() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)
        let repository = LocalAgentUsageRepository(database: database)
        let session = ParsedAgentSession(
            sourceKind: .codexJSONL,
            sessionKey: "codex-session-1",
            projectPath: "/repo",
            modelName: "gpt-5.3",
            cliVersion: nil,
            startedAt: ISO8601DateFormatter().date(from: "2026-07-03T01:00:00Z"),
            updatedAt: ISO8601DateFormatter().date(from: "2026-07-03T01:10:00Z"),
            usage: ParsedSessionUsage(inputTokens: 100, outputTokens: 20, reasoningTokens: 3, cacheReadTokens: 4, cacheWriteTokens: 5, costUSDMicros: nil),
            usageSequence: 1,
            sourceOffset: 42,
            rawMeta: ["source": "codex"]
        )

        try repository.upsert(session, scanRootId: 1, sourceFileId: nil, runId: nil)

        XCTAssertEqual(try database.query("SELECT count(*) AS count FROM agent_sessions")[0].int("count"), 1)
        XCTAssertEqual(try database.query("SELECT tokens_total FROM session_usage")[0].int("tokens_total"), 132)
        XCTAssertEqual(try database.query("SELECT count(*) AS count FROM session_usage_latest")[0].int("count"), 1)
    }
}
```

- [ ] **Step 2: Write failing menu summary test**

Create `Tests/TokenMeterCoreTests/MenuBarSummaryRepositoryTests.swift`:

```swift
import XCTest
@testable import TokenMeterCore

final class MenuBarSummaryRepositoryTests: XCTestCase {
    func testReadsPrimaryProviderLatestTokenSummary() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)
        let settings = SettingsStore(database: database)
        try settings.importConfigIfNeeded(ProviderConfigLoader.defaultConfig())
        let repository = LocalAgentUsageRepository(database: database)
        let session = ParsedAgentSession(
            sourceKind: .codexJSONL,
            sessionKey: "codex-session-1",
            projectPath: "/repo",
            modelName: "gpt-5.3",
            cliVersion: nil,
            startedAt: nil,
            updatedAt: ISO8601DateFormatter().date(from: "2026-07-03T01:10:00Z"),
            usage: ParsedSessionUsage(inputTokens: 100, outputTokens: 20, reasoningTokens: nil, cacheReadTokens: nil, cacheWriteTokens: nil, costUSDMicros: nil),
            usageSequence: 1,
            sourceOffset: 42,
            rawMeta: [:]
        )
        try repository.upsert(session, scanRootId: 1, sourceFileId: nil, runId: nil)

        let summary = try MenuBarSummaryRepository(database: database).primarySummary(providerId: "codex")

        XCTAssertEqual(summary?.providerId, "codex")
        XCTAssertEqual(summary?.totalTokens, 120)
    }
}
```

- [ ] **Step 3: Run tests and verify they fail**

Run:

```bash
swift test --filter LocalAgentUsageRepositoryTests && swift test --filter MenuBarSummaryRepositoryTests
```

Expected: FAIL because repositories do not exist.

- [ ] **Step 4: Implement repository models and upsert**

Create `Sources/TokenMeterCore/LocalAgentUsageRepository.swift`:

```swift
import Foundation

public final class LocalAgentUsageRepository {
    private let database: SQLiteDatabase
    private let formatter = ISO8601DateFormatter()

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    public func upsert(_ session: ParsedAgentSession, scanRootId: Int64, sourceFileId: Int64?, runId: Int64?) throws {
        let providerId = providerId(for: session.sourceKind)
        try database.execute("BEGIN IMMEDIATE")
        do {
            let projectId = try upsertProject(session.projectPath)
            try database.execute(
                """
                INSERT INTO agent_sessions(source_kind, source_session_key, scan_root_id, source_file_id, project_id, provider_id, model_name, cli_version, session_started_at, session_updated_at, cwd_path, status, source_revision, raw_meta_json, last_seen_run_id, last_indexed_run_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, ?, ?, ?)
                ON CONFLICT(source_kind, source_session_key) DO UPDATE SET
                  project_id=excluded.project_id,
                  provider_id=excluded.provider_id,
                  model_name=excluded.model_name,
                  cli_version=excluded.cli_version,
                  session_updated_at=excluded.session_updated_at,
                  cwd_path=excluded.cwd_path,
                  status='active',
                  source_revision=excluded.source_revision,
                  raw_meta_json=excluded.raw_meta_json,
                  last_seen_run_id=excluded.last_seen_run_id,
                  last_indexed_run_id=excluded.last_indexed_run_id
                """,
                [
                    .text(session.sourceKind.rawValue), .text(session.sessionKey), .int(scanRootId), sqliteInt(sourceFileId), sqliteInt(projectId), .text(providerId),
                    sqliteText(session.modelName), sqliteText(session.cliVersion), sqliteText(session.startedAt.map(formatter.string(from:))), sqliteText(session.updatedAt.map(formatter.string(from:))), sqliteText(session.projectPath),
                    .text(revision(for: session)), .text(rawMetaJSON(session.rawMeta)), sqliteInt(runId), sqliteInt(runId)
                ]
            )
            let sessionId = try database.query("SELECT id FROM agent_sessions WHERE source_kind = ? AND source_session_key = ?", [.text(session.sourceKind.rawValue), .text(session.sessionKey)])[0].int("id")!
            if let usage = session.usage {
                try database.execute(
                    """
                    INSERT OR REPLACE INTO session_usage(session_id, observed_at, usage_seq, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, cost_usd_micros, source_offset, is_cumulative)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
                    """,
                    [.int(sessionId), .text(session.updatedAt.map(formatter.string(from:)) ?? formatter.string(from: Date())), .int(Int64(max(session.usageSequence, 1))), sqliteInt(usage.inputTokens), sqliteInt(usage.outputTokens), sqliteInt(usage.reasoningTokens), sqliteInt(usage.cacheReadTokens), sqliteInt(usage.cacheWriteTokens), sqliteInt(usage.costUSDMicros), sqliteInt(session.sourceOffset)]
                )
                let usageId = try database.query("SELECT id FROM session_usage WHERE session_id = ? ORDER BY usage_seq DESC LIMIT 1", [.int(sessionId)])[0].int("id")!
                try database.execute("INSERT OR REPLACE INTO session_usage_latest(session_id, session_usage_id) VALUES (?, ?)", [.int(sessionId), .int(usageId)])
            }
            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
    }

    private func upsertProject(_ path: String?) throws -> Int64? {
        guard let path else { return nil }
        let key = String(path.hashValue)
        let displayName = URL(fileURLWithPath: path).lastPathComponent
        try database.execute(
            "INSERT INTO projects(project_key, canonical_path, display_name, first_seen_at, last_seen_at) VALUES (?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP) ON CONFLICT(project_key) DO UPDATE SET last_seen_at=CURRENT_TIMESTAMP",
            [.text(key), .text(path), .text(displayName)]
        )
        return try database.query("SELECT id FROM projects WHERE project_key = ?", [.text(key)])[0].int("id")
    }

    private func providerId(for sourceKind: SourceKind) -> String {
        switch sourceKind {
        case .claudeJSONL: return "claude-code"
        case .codexJSONL: return "codex"
        case .ompJSONL: return "omp"
        case .opencodeSQLite: return "opencode"
        }
    }

    private func sqliteInt(_ value: Int64?) -> SQLiteValue { value.map(SQLiteValue.int) ?? .null }
    private func sqliteText(_ value: String?) -> SQLiteValue { value.map(SQLiteValue.text) ?? .null }
    private func rawMetaJSON(_ rawMeta: [String: String]) -> String { (try? String(data: JSONEncoder().encode(rawMeta), encoding: .utf8)) ?? "{}" }
    private func revision(for session: ParsedAgentSession) -> String { "\(session.sourceKind.rawValue):\(session.sessionKey):\(session.usageSequence):\(session.sourceOffset ?? -1)" }
}
```

- [ ] **Step 5: Implement menu summary repository**

Create `Sources/TokenMeterCore/MenuBarSummaryRepository.swift`:

```swift
public struct MenuBarTokenSummary: Equatable {
    public let providerId: String
    public let modelName: String?
    public let totalTokens: Int64
}

public final class MenuBarSummaryRepository {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    public func primarySummary(providerId: String) throws -> MenuBarTokenSummary? {
        let rows = try database.query(
            """
            SELECT s.provider_id, s.model_name, u.tokens_total
            FROM agent_sessions s
            JOIN session_usage_latest ul ON ul.session_id = s.id
            JOIN session_usage u ON u.id = ul.session_usage_id
            WHERE s.provider_id = ? AND s.status = 'active'
            ORDER BY s.session_updated_at DESC
            LIMIT 1
            """,
            [.text(providerId)]
        )
        guard let row = rows.first else { return nil }
        return MenuBarTokenSummary(providerId: row.string("provider_id") ?? providerId, modelName: row.string("model_name"), totalTokens: row.int("tokens_total") ?? 0)
    }
}
```

- [ ] **Step 6: Run repository tests**

Run:

```bash
swift test --filter LocalAgentUsageRepositoryTests && swift test --filter MenuBarSummaryRepositoryTests
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/TokenMeterCore/LocalAgentUsageRepository.swift Sources/TokenMeterCore/MenuBarSummaryRepository.swift Tests/TokenMeterCoreTests/LocalAgentUsageRepositoryTests.swift Tests/TokenMeterCoreTests/MenuBarSummaryRepositoryTests.swift
git commit -m "feat: persist local session usage summaries"
```

---

## Task 8: Implement scanner coordinator and default scan roots

**Files:**
- Create: `Sources/TokenMeterCore/LocalAgentScanner.swift`
- Modify: `Sources/TokenMeterCore/TokenMeterPaths.swift`
- Test: `Tests/TokenMeterCoreTests/LocalAgentScannerTests.swift`

- [ ] **Step 1: Write failing scanner test for unchanged and append**

Create `Tests/TokenMeterCoreTests/LocalAgentScannerTests.swift`:

```swift
import XCTest
@testable import TokenMeterCore

final class LocalAgentScannerTests: XCTestCase {
    func testScansCodexJSONLOnceThenSkipsUnchangedFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("rollout.jsonl")
        try Data((#"{"type":"session_meta","payload":{"id":"s1","cwd":"/repo"}}"# + "\n" + #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,"output_tokens":2}}}}"# + "\n").utf8).write(to: file)
        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)
        try database.execute("INSERT INTO scan_roots(id, kind, root_path, display_name, stable_source_key) VALUES (1, 'codex_jsonl', ?, 'Codex', 'codex-test')", [.text(directory.path)])

        let scanner = LocalAgentScanner(database: database)
        try await scanner.scanRoot(id: 1)
        try await scanner.scanRoot(id: 1)

        XCTAssertEqual(try database.query("SELECT count(*) AS count FROM agent_sessions")[0].int("count"), 1)
        XCTAssertEqual(try database.query("SELECT files_changed FROM scan_runs ORDER BY id DESC LIMIT 1")[0].int("files_changed"), 0)
    }
}
```

- [ ] **Step 2: Run scanner test and verify it fails**

Run:

```bash
swift test --filter LocalAgentScannerTests/testScansCodexJSONLOnceThenSkipsUnchangedFile
```

Expected: FAIL because `LocalAgentScanner` does not exist.

- [ ] **Step 3: Implement scanner coordinator**

Create `Sources/TokenMeterCore/LocalAgentScanner.swift`:

```swift
import Foundation

public final class LocalAgentScanner {
    private let database: SQLiteDatabase
    private let repository: LocalAgentUsageRepository

    public init(database: SQLiteDatabase) {
        self.database = database
        self.repository = LocalAgentUsageRepository(database: database)
    }

    public func scanRoot(id rootId: Int64) async throws {
        let rootRows = try database.query("SELECT id, kind, root_path FROM scan_roots WHERE id = ? AND enabled = 1", [.int(rootId)])
        guard let root = rootRows.first, let kindText = root.string("kind"), let kind = SourceKind(rawValue: kindText), let rootPath = root.string("root_path") else { return }
        let runId = try startRun(rootId: rootId)
        var filesSeen: Int64 = 0
        var filesChanged: Int64 = 0
        do {
            switch kind {
            case .codexJSONL, .claudeJSONL, .ompJSONL:
                let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
                let files = try jsonlFiles(under: rootURL)
                for file in files {
                    filesSeen += 1
                    if try scanJSONLFile(file, rootURL: rootURL, rootId: rootId, kind: kind, runId: runId) {
                        filesChanged += 1
                    }
                }
            case .opencodeSQLite:
                break
            }
            try finishRun(runId: runId, status: "ok", filesSeen: filesSeen, filesChanged: filesChanged)
        } catch {
            try finishRun(runId: runId, status: "partial", filesSeen: filesSeen, filesChanged: filesChanged)
            throw error
        }
    }

    private func scanJSONLFile(_ file: URL, rootURL: URL, rootId: Int64, kind: SourceKind, runId: Int64) throws -> Bool {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = Int64(((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1_000_000_000)
        let relativePath = file.path.replacingOccurrences(of: rootURL.path + "/", with: "")
        let existing = try database.query("SELECT id, size_bytes, mtime_ns, parser_state FROM source_files WHERE scan_root_id = ? AND relative_path = ?", [.int(rootId), .text(relativePath)]).first
        if let existing, existing.int("size_bytes") == size, existing.int("mtime_ns") == mtime {
            return false
        }
        let read = try JSONLStreamReader.readLines(from: file, startingAt: 0)
        guard !read.lines.isEmpty else { return false }
        let parser: LocalAgentSessionParser = switch kind {
        case .codexJSONL: CodexSessionParser()
        case .claudeJSONL: ClaudeCodeSessionParser()
        case .ompJSONL: OmpSessionParser()
        case .opencodeSQLite: throw LocalAgentParserError.unsupportedFormat
        }
        let parsed = try parser.parse(lines: read.lines, sourceURL: file)
        let fileId = try upsertSourceFile(rootId: rootId, relativePath: relativePath, canonicalPath: file.path, size: size, mtime: mtime, runId: runId)
        try repository.upsert(parsed, scanRootId: rootId, sourceFileId: fileId, runId: runId)
        return true
    }

    private func jsonlFiles(under root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
    }

    private func startRun(rootId: Int64) throws -> Int64 {
        try database.execute("INSERT INTO scan_runs(scan_root_id, run_kind) VALUES (?, 'incremental')", [.int(rootId)])
        return try database.query("SELECT last_insert_rowid() AS id")[0].int("id")!
    }

    private func finishRun(runId: Int64, status: String, filesSeen: Int64, filesChanged: Int64) throws {
        try database.execute("UPDATE scan_runs SET status = ?, finished_at = CURRENT_TIMESTAMP, files_seen = ?, files_changed = ? WHERE id = ?", [.text(status), .int(filesSeen), .int(filesChanged), .int(runId)])
    }

    private func upsertSourceFile(rootId: Int64, relativePath: String, canonicalPath: String, size: Int64, mtime: Int64, runId: Int64) throws -> Int64 {
        try database.execute(
            """
            INSERT INTO source_files(scan_root_id, relative_path, canonical_path, file_type, size_bytes, mtime_ns, last_seen_run_id, last_parsed_run_id, parse_status)
            VALUES (?, ?, ?, 'jsonl_session', ?, ?, ?, ?, 'ok')
            ON CONFLICT(scan_root_id, relative_path) DO UPDATE SET size_bytes=excluded.size_bytes, mtime_ns=excluded.mtime_ns, last_seen_run_id=excluded.last_seen_run_id, last_parsed_run_id=excluded.last_parsed_run_id, parse_status='ok'
            """,
            [.int(rootId), .text(relativePath), .text(canonicalPath), .int(size), .int(mtime), .int(runId), .int(runId)]
        )
        return try database.query("SELECT id FROM source_files WHERE scan_root_id = ? AND relative_path = ?", [.int(rootId), .text(relativePath)])[0].int("id")!
    }
}
```

This first scanner version skips unchanged files. A later implementation step refines append-only offsets and tail hashes; do not ship until Task 15 verification confirms append/rewrite behavior.

- [ ] **Step 4: Run scanner test**

Run:

```bash
swift test --filter LocalAgentScannerTests/testScansCodexJSONLOnceThenSkipsUnchangedFile
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/TokenMeterCore/LocalAgentScanner.swift Tests/TokenMeterCoreTests/LocalAgentScannerTests.swift
git commit -m "feat: scan local jsonl session roots"
```

---

## Task 9: Wire SQLite settings and scanner into Swift app

**Files:**
- Modify: `Sources/TokenMeterApp/ProviderStore.swift`
- Modify: `Sources/TokenMeterApp/AppDelegate.swift`
- Modify: `Sources/TokenMeterApp/PopoverView.swift`
- Modify: `Sources/TokenMeterApp/StatusBarController.swift`
- Test: existing Swift tests only; app behavior verified by build and smoke test.

- [ ] **Step 1: Add ProviderStore initialization path**

Modify `ProviderStore` initialization to:

```swift
private let database: SQLiteDatabase?
private let settingsStore: SettingsStore?
private let scanner: LocalAgentScanner?
@Published private(set) var settingsSnapshot: SettingsSnapshot?
@Published private(set) var localIndexStatusText: String = "本地会话索引未启动"

convenience init(notificationCenter: UsageNotificationDelivering?) {
    self.init(config: ProviderStore.loadConfig(), notificationCenter: notificationCenter, databaseURL: TokenMeterPaths.databaseURL())
}

init(config: TokenMeterConfig, notificationCenter: UsageNotificationDelivering? = nil, databaseURL: URL?) {
    self.config = config
    self.providers = ProviderRegistry.makeProviders(from: config)
    self.snapshotCacheURL = ProviderStore.snapshotCacheURL()
    self.notificationCenter = notificationCenter
    if let databaseURL {
        try? FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let database = try? SQLiteDatabase(path: databaseURL.path)
        self.database = database
        self.settingsStore = database.map(SettingsStore.init(database:))
        self.scanner = database.map(LocalAgentScanner.init(database:))
        if let database {
            try? TokenMeterDatabaseMigrator.migrate(database)
            try? self.settingsStore?.importConfigIfNeeded(config)
            self.settingsSnapshot = try? self.settingsStore?.snapshot()
        }
    } else {
        self.database = nil
        self.settingsStore = nil
        self.scanner = nil
    }
    let cachedSnapshots = (try? ProviderSnapshotDiskCache.read(from: snapshotCacheURL)) ?? []
    self.providerSnapshots = cachedSnapshots
    self.snapshots = cachedSnapshots.map(\.legacySnapshot)
}
```

If Swift complains about `let` initialization order, convert `providers` from `let` to `private var providers` and assign after all stored properties are initialized.

- [ ] **Step 2: Add settings reload method**

Add to `ProviderStore`:

```swift
func reloadSettings() {
    settingsSnapshot = try? settingsStore?.snapshot()
}
```

- [ ] **Step 3: Add local scan method**

Add to `ProviderStore`:

```swift
func refreshLocalAgentIndex() async {
    guard let database, let scanner else {
        localIndexStatusText = "本地会话索引不可用"
        return
    }
    let roots = (try? database.query("SELECT id FROM scan_roots WHERE enabled = 1")) ?? []
    var scanned = 0
    for row in roots {
        guard let id = row.int("id") else { continue }
        do {
            try await scanner.scanRoot(id: id)
            scanned += 1
        } catch {
            localIndexStatusText = "本地会话索引部分失败"
        }
    }
    if scanned > 0 {
        localIndexStatusText = "已更新 \(scanned) 个本地会话来源"
    }
}
```

- [ ] **Step 4: Seed default scan roots in app startup**

Add a `seedDefaultScanRoots()` method in `ProviderStore`:

```swift
func seedDefaultScanRoots() {
    guard let database else { return }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let roots: [(String, String, String)] = [
        ("claude_jsonl", home + "/.claude/projects", "Claude Code"),
        ("codex_jsonl", home + "/.codex/sessions", "Codex"),
        ("opencode_sqlite", home + "/.local/share/opencode/opencode.db", "OpenCode"),
        ("omp_jsonl", home + "/.omp/agent/sessions", "OMP")
    ]
    for root in roots {
        try? database.execute(
            "INSERT OR IGNORE INTO scan_roots(kind, root_path, display_name, stable_source_key) VALUES (?, ?, ?, ?)",
            [.text(root.0), .text(root.1), .text(root.2), .text(root.0 + ":" + root.1)]
        )
    }
}
```

- [ ] **Step 5: Wire AppDelegate startup**

Modify `applicationDidFinishLaunching`:

```swift
let store = ProviderStore(notificationCenter: usageNotificationCenter)
store.seedDefaultScanRoots()
self.store = store
self.statusBarController = StatusBarController(store: store)

Task {
    await store.refreshNotificationAuthorizationState()
    await store.refresh()
    await store.refreshLocalAgentIndex()
}
```

- [ ] **Step 6: Use setting refresh interval for timer**

Replace hard-coded timer interval with:

```swift
let interval = TimeInterval(store.settingsSnapshot?.autoRefreshSeconds ?? 300)
refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
    Task { @MainActor in
        await self?.store?.refresh()
        await self?.store?.refreshLocalAgentIndex()
    }
}
```

- [ ] **Step 7: Add local index summary to PopoverView**

In `PopoverView`, add one compact line near the header or below provider cards:

```swift
Text(store.localIndexStatusText)
    .font(.caption)
    .foregroundStyle(.secondary)
```

Keep this minimal; do not add charts to the Swift popover.

- [ ] **Step 8: Build Swift app**

Run:

```bash
swift build
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add Sources/TokenMeterApp/ProviderStore.swift Sources/TokenMeterApp/AppDelegate.swift Sources/TokenMeterApp/PopoverView.swift Sources/TokenMeterApp/StatusBarController.swift
git commit -m "feat: wire local session index into menu bar app"
```

---

## Task 10: Add Swift JSON-line socket IPC server

**Files:**
- Create: `Sources/TokenMeterApp/TokenMeterIPCServer.swift`
- Modify: `Sources/TokenMeterApp/AppDelegate.swift`
- Modify: `Sources/TokenMeterApp/ProviderStore.swift`

- [ ] **Step 1: Create IPC message models**

Create `Sources/TokenMeterApp/TokenMeterIPCServer.swift` with message types:

```swift
import Foundation
import Network
import TokenMeterCore

struct IPCRequest: Codable {
    let id: String
    let method: String
    let params: [String: String]?
}

struct IPCResponse: Codable {
    let id: String
    let ok: Bool
    let result: [String: String]?
    let error: String?
}
```

- [ ] **Step 2: Implement local TCP listener on loopback**

Add to same file:

```swift
@MainActor
final class TokenMeterIPCServer {
    private let store: ProviderStore
    private var listener: NWListener?

    init(store: ProviderStore) {
        self.store = store
    }

    func start(port: UInt16 = 47731) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handle(connection)
            }
        }
        listener.start(queue: .global(qos: .utility))
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let request = try? JSONDecoder().decode(IPCRequest.self, from: data) else {
                connection.cancel()
                return
            }
            Task { @MainActor in
                let response = await self.respond(to: request)
                let payload = (try? JSONEncoder().encode(response)) ?? Data()
                connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    private func respond(to request: IPCRequest) async -> IPCResponse {
        switch request.method {
        case "settingsChanged":
            store.reloadSettings()
            return IPCResponse(id: request.id, ok: true, result: ["status": "settingsApplied"], error: nil)
        case "scanNow":
            await store.refreshLocalAgentIndex()
            return IPCResponse(id: request.id, ok: true, result: ["status": store.localIndexStatusText], error: nil)
        case "ping":
            return IPCResponse(id: request.id, ok: true, result: ["status": "ok"], error: nil)
        default:
            return IPCResponse(id: request.id, ok: false, result: nil, error: "unknown method")
        }
    }
}
```

This is loopback TCP for the first implementation. A later hardening pass can replace it with Unix domain socket or XPC.

- [ ] **Step 3: Start and stop server from AppDelegate**

Modify `AppDelegate`:

```swift
private var ipcServer: TokenMeterIPCServer?
```

After store creation:

```swift
let ipcServer = TokenMeterIPCServer(store: store)
try? ipcServer.start()
self.ipcServer = ipcServer
```

On terminate:

```swift
ipcServer?.stop()
```

- [ ] **Step 4: Build Swift app**

Run:

```bash
swift build
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/TokenMeterApp/TokenMeterIPCServer.swift Sources/TokenMeterApp/AppDelegate.swift
git commit -m "feat: add local ipc for electron settings"
```

---

## Task 11: Scaffold Electron + React app with secure preload

**Files:**
- Create all Electron scaffold files listed in the File Structure section.
- Test: `Electron/src/main/ipc.test.ts`
- Test: `Electron/src/renderer/stores/settingsStore.test.ts`

- [ ] **Step 1: Create Electron package.json**

Create `Electron/package.json`:

```json
{
  "name": "token-meter-electron",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite --host 127.0.0.1",
    "electron": "electron .",
    "test": "vitest run",
    "typecheck": "tsc --noEmit",
    "build": "vite build"
  },
  "main": "dist-main/main.js",
  "dependencies": {
    "@vitejs/plugin-react": "latest",
    "better-sqlite3": "latest",
    "electron": "latest",
    "react": "latest",
    "react-dom": "latest"
  },
  "devDependencies": {
    "@types/better-sqlite3": "latest",
    "@types/node": "latest",
    "@types/react": "latest",
    "@types/react-dom": "latest",
    "typescript": "latest",
    "vite": "latest",
    "vitest": "latest"
  }
}
```

- [ ] **Step 2: Create TypeScript and Vite config**

Create `Electron/tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "jsx": "react-jsx",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "types": ["node", "vitest/globals"]
  },
  "include": ["src"]
}
```

Create `Electron/vite.config.ts`:

```ts
import react from '@vitejs/plugin-react';
import { defineConfig } from 'vite';

export default defineConfig({
  plugins: [react()],
  root: '.',
  build: {
    outDir: 'dist-renderer'
  }
});
```

Create `Electron/vitest.config.ts`:

```ts
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    environment: 'node',
    globals: true
  }
});
```

- [ ] **Step 3: Create Electron main window with secure options**

Create `Electron/src/main/main.ts`:

```ts
import { app, BrowserWindow } from 'electron';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { registerIpcHandlers } from './ipc.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

function createWindow() {
  const window = new BrowserWindow({
    width: 1180,
    height: 760,
    webPreferences: {
      preload: path.join(__dirname, '../preload.js'),
      nodeIntegration: false,
      contextIsolation: true,
      sandbox: true
    }
  });

  if (process.env.VITE_DEV_SERVER_URL) {
    void window.loadURL(process.env.VITE_DEV_SERVER_URL);
  } else {
    void window.loadFile(path.join(__dirname, '../../dist-renderer/index.html'));
  }
}

app.whenReady().then(() => {
  registerIpcHandlers();
  createWindow();
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
```

- [ ] **Step 4: Create preload whitelist**

Create `Electron/src/preload.ts`:

```ts
import { contextBridge, ipcRenderer } from 'electron';

contextBridge.exposeInMainWorld('tokenMeter', {
  settings: {
    get: () => ipcRenderer.invoke('settings:get'),
    update: (patch: unknown, expectedVersion: number) => ipcRenderer.invoke('settings:update', patch, expectedVersion)
  },
  dashboard: {
    queryOverview: (filter: unknown) => ipcRenderer.invoke('dashboard:overview', filter),
    queryDailyUsage: (filter: unknown) => ipcRenderer.invoke('dashboard:dailyUsage', filter)
  },
  sessions: {
    query: (filter: unknown) => ipcRenderer.invoke('sessions:query', filter)
  },
  index: {
    status: () => ipcRenderer.invoke('index:status'),
    startFullReindex: (rootId?: string) => ipcRenderer.invoke('index:fullReindex', rootId)
  }
});
```

- [ ] **Step 5: Create IPC handlers stub**

Create `Electron/src/main/ipc.ts`:

```ts
import { ipcMain } from 'electron';

export function registerIpcHandlers() {
  ipcMain.handle('settings:get', async () => ({ version: 0, providerOverrides: [] }));
  ipcMain.handle('settings:update', async (_event, _patch, _expectedVersion) => ({ requestedVersion: 1, status: 'pending' }));
  ipcMain.handle('dashboard:overview', async () => ({ providers: [], totalTokens: 0 }));
  ipcMain.handle('dashboard:dailyUsage', async () => []);
  ipcMain.handle('sessions:query', async () => ({ items: [], total: 0 }));
  ipcMain.handle('index:status', async () => ({ runs: [], roots: [] }));
  ipcMain.handle('index:fullReindex', async () => ({ status: 'queued' }));
}
```

- [ ] **Step 6: Create renderer shell**

Create `Electron/index.html`:

```html
<!doctype html>
<html lang="zh-CN">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>TokenMeter</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/renderer/App.tsx"></script>
  </body>
</html>
```

Create `Electron/src/renderer/App.tsx`:

```tsx
import React from 'react';
import { createRoot } from 'react-dom/client';
import './styles.css';

function App() {
  return (
    <main className="app-shell">
      <aside className="sidebar">
        <strong>TokenMeter</strong>
        <nav>
          <a>Dashboard</a>
          <a>Sessions</a>
          <a>Index Status</a>
          <a>Settings</a>
        </nav>
      </aside>
      <section className="content">
        <h1>本地 token 使用</h1>
        <p>连接 Swift 常驻层后显示 provider、agent、project 和 session 数据。</p>
      </section>
    </main>
  );
}

createRoot(document.getElementById('root')!).render(<App />);
```

Create `Electron/src/renderer/styles.css`:

```css
:root {
  color: oklch(24% 0.012 255);
  background: oklch(97% 0.006 255);
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
  font-variant-numeric: tabular-nums;
}

body { margin: 0; }

.app-shell {
  min-height: 100vh;
  display: grid;
  grid-template-columns: 240px 1fr;
}

.sidebar {
  border-right: 1px solid oklch(88% 0.01 255);
  padding: 24px;
  background: oklch(94% 0.008 255);
}

.sidebar nav {
  display: grid;
  gap: 10px;
  margin-top: 28px;
}

.content {
  padding: 32px 40px;
}
```

- [ ] **Step 7: Install Electron dependencies**

Run:

```bash
npm install --prefix Electron
```

Expected: `Electron/package-lock.json` is created.

- [ ] **Step 8: Run Electron typecheck and test**

Run:

```bash
npm run typecheck --prefix Electron
npm test --prefix Electron
```

Expected: PASS. Tests may report no tests yet; if Vitest exits non-zero for no tests, add a tiny `Electron/src/main/ipc.test.ts`:

```ts
import { describe, expect, it } from 'vitest';

describe('electron scaffold', () => {
  it('loads test runner', () => {
    expect(true).toBe(true);
  });
});
```

- [ ] **Step 9: Commit**

```bash
git add Electron
git commit -m "feat: scaffold electron dashboard"
```

---

## Task 12: Implement Electron SQLite settings repository and Swift notification client

**Files:**
- Create: `Electron/src/main/database.ts`
- Create: `Electron/src/main/settingsRepository.ts`
- Create: `Electron/src/main/tokenMeterSocketClient.ts`
- Modify: `Electron/src/main/ipc.ts`
- Test: `Electron/src/main/settingsRepository.test.ts`
- Test: `Electron/src/main/tokenMeterSocketClient.test.ts`

- [ ] **Step 1: Write failing settings repository test**

Create `Electron/src/main/settingsRepository.test.ts`:

```ts
import Database from 'better-sqlite3';
import { describe, expect, it } from 'vitest';
import { SettingsRepository } from './settingsRepository';

function memoryDb() {
  const db = new Database(':memory:');
  db.exec(`
    CREATE TABLE settings(key TEXT PRIMARY KEY, value_json TEXT NOT NULL, value_type TEXT NOT NULL, version INTEGER NOT NULL, updated_at TEXT DEFAULT CURRENT_TIMESTAMP, updated_by TEXT NOT NULL);
    CREATE TABLE provider_config_overrides(provider_id TEXT PRIMARY KEY, enabled INTEGER, display_name TEXT, menu_rank INTEGER, show_in_menu_bar INTEGER, show_in_charts INTEGER, updated_at TEXT DEFAULT CURRENT_TIMESTAMP);
    INSERT INTO settings(key, value_json, value_type, version, updated_by) VALUES ('menuBar.primaryProviderId', '"codex"', 'string', 1, 'importer');
  `);
  return db;
}

describe('SettingsRepository', () => {
  it('rejects stale settings writes', () => {
    const repo = new SettingsRepository(memoryDb());
    expect(() => repo.update({ menuBarPrimaryProviderId: 'claude-code' }, 0)).toThrow(/stale/i);
  });

  it('updates primary provider with a version bump', () => {
    const repo = new SettingsRepository(memoryDb());
    const result = repo.update({ menuBarPrimaryProviderId: 'claude-code' }, 1);
    expect(result.requestedVersion).toBe(2);
    expect(repo.get().menuBarPrimaryProviderId).toBe('claude-code');
  });
});
```

- [ ] **Step 2: Run Electron test and verify it fails**

Run:

```bash
npm test --prefix Electron -- settingsRepository.test.ts
```

Expected: FAIL because repository does not exist.

- [ ] **Step 3: Implement database path helper**

Create `Electron/src/main/database.ts`:

```ts
import Database from 'better-sqlite3';
import os from 'node:os';
import path from 'node:path';

export function tokenMeterDatabasePath() {
  return path.join(os.homedir(), '.token-meter', 'tokenmeter.sqlite');
}

export function openTokenMeterDatabase(file = tokenMeterDatabasePath()) {
  const db = new Database(file);
  db.pragma('journal_mode = WAL');
  db.pragma('foreign_keys = ON');
  db.pragma('busy_timeout = 5000');
  return db;
}
```

- [ ] **Step 4: Implement settings repository**

Create `Electron/src/main/settingsRepository.ts`:

```ts
import type Database from 'better-sqlite3';

export type SettingsPatch = {
  menuBarPrimaryProviderId?: string;
  autoRefreshSeconds?: number;
  enabledAgentKinds?: string[];
};

export class SettingsRepository {
  constructor(private readonly db: Database.Database) {}

  get() {
    const versionRow = this.db.prepare('SELECT coalesce(max(version), 0) as version FROM settings').get() as { version: number };
    const primary = this.getString('menuBar.primaryProviderId');
    return { version: versionRow.version, menuBarPrimaryProviderId: primary, providerOverrides: [] };
  }

  update(patch: SettingsPatch, expectedVersion: number) {
    const current = this.get();
    if (current.version !== expectedVersion) throw new Error(`stale settings version: expected ${expectedVersion}, actual ${current.version}`);
    const nextVersion = expectedVersion + 1;
    const tx = this.db.transaction(() => {
      if (patch.menuBarPrimaryProviderId !== undefined) this.setString('menuBar.primaryProviderId', patch.menuBarPrimaryProviderId, nextVersion);
      if (patch.autoRefreshSeconds !== undefined) this.setInt('scan.autoRefreshSeconds', patch.autoRefreshSeconds, nextVersion);
      if (patch.enabledAgentKinds !== undefined) this.setJson('filters.enabledAgentKinds', patch.enabledAgentKinds, nextVersion);
    });
    tx();
    return { requestedVersion: nextVersion, status: 'pending' };
  }

  private getString(key: string) {
    const row = this.db.prepare('SELECT value_json FROM settings WHERE key = ?').get(key) as { value_json: string } | undefined;
    return row ? JSON.parse(row.value_json) as string : undefined;
  }

  private setString(key: string, value: string, version: number) {
    this.db.prepare('INSERT OR REPLACE INTO settings(key, value_json, value_type, version, updated_by) VALUES (?, ?, ?, ?, ?)')
      .run(key, JSON.stringify(value), 'string', version, 'electron');
  }

  private setInt(key: string, value: number, version: number) {
    this.db.prepare('INSERT OR REPLACE INTO settings(key, value_json, value_type, version, updated_by) VALUES (?, ?, ?, ?, ?)')
      .run(key, String(value), 'int', version, 'electron');
  }

  private setJson(key: string, value: unknown, version: number) {
    this.db.prepare('INSERT OR REPLACE INTO settings(key, value_json, value_type, version, updated_by) VALUES (?, ?, ?, ?, ?)')
      .run(key, JSON.stringify(value), 'json', version, 'electron');
  }
}
```

- [ ] **Step 5: Implement Swift socket client**

Create `Electron/src/main/tokenMeterSocketClient.ts`:

```ts
import net from 'node:net';
import { randomUUID } from 'node:crypto';

export function notifySwift(method: string, params: Record<string, string> = {}, port = 47731) {
  return new Promise<{ ok: boolean; result?: Record<string, string>; error?: string }>((resolve, reject) => {
    const socket = net.createConnection({ host: '127.0.0.1', port });
    const request = JSON.stringify({ id: randomUUID(), method, params });
    socket.setTimeout(2000);
    socket.on('connect', () => socket.write(request));
    socket.on('data', (data) => {
      try {
        resolve(JSON.parse(data.toString('utf8')));
      } catch (error) {
        reject(error);
      } finally {
        socket.end();
      }
    });
    socket.on('timeout', () => {
      socket.destroy();
      reject(new Error('TokenMeter Swift IPC timeout'));
    });
    socket.on('error', reject);
  });
}
```

- [ ] **Step 6: Wire settings IPC handler**

Modify `Electron/src/main/ipc.ts`:

```ts
import { ipcMain } from 'electron';
import { openTokenMeterDatabase } from './database.js';
import { SettingsRepository } from './settingsRepository.js';
import { notifySwift } from './tokenMeterSocketClient.js';

export function registerIpcHandlers() {
  const db = openTokenMeterDatabase();
  const settings = new SettingsRepository(db);

  ipcMain.handle('settings:get', async () => settings.get());
  ipcMain.handle('settings:update', async (_event, patch, expectedVersion) => {
    const result = settings.update(patch, expectedVersion);
    try {
      await notifySwift('settingsChanged', { version: String(result.requestedVersion) });
      return { ...result, status: 'applied' };
    } catch {
      return result;
    }
  });
  ipcMain.handle('dashboard:overview', async () => ({ providers: [], totalTokens: 0 }));
  ipcMain.handle('dashboard:dailyUsage', async () => []);
  ipcMain.handle('sessions:query', async () => ({ items: [], total: 0 }));
  ipcMain.handle('index:status', async () => ({ runs: [], roots: [] }));
  ipcMain.handle('index:fullReindex', async () => notifySwift('scanNow'));
}
```

- [ ] **Step 7: Run Electron tests and typecheck**

Run:

```bash
npm test --prefix Electron -- settingsRepository.test.ts
npm run typecheck --prefix Electron
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Electron/src/main/database.ts Electron/src/main/settingsRepository.ts Electron/src/main/tokenMeterSocketClient.ts Electron/src/main/ipc.ts Electron/src/main/settingsRepository.test.ts
git commit -m "feat: let electron update tokenmeter settings"
```

---

## Task 13: Implement Electron Dashboard, Sessions, Index Status, and Settings UI

**Files:**
- Modify: `Electron/src/renderer/App.tsx`
- Create: `Electron/src/renderer/api.ts`
- Create: `Electron/src/renderer/stores/settingsStore.ts`
- Create: `Electron/src/renderer/routes/Dashboard.tsx`
- Create: `Electron/src/renderer/routes/Sessions.tsx`
- Create: `Electron/src/renderer/routes/IndexStatus.tsx`
- Create: `Electron/src/renderer/routes/Settings.tsx`
- Create: `Electron/src/renderer/components/Layout.tsx`
- Create: `Electron/src/renderer/components/TokenTrendChart.tsx`
- Create: `Electron/src/renderer/components/SessionTable.tsx`
- Modify: `Electron/src/renderer/styles.css`

- [ ] **Step 1: Add renderer API types**

Create `Electron/src/renderer/api.ts`:

```ts
export type SettingsSnapshot = {
  version: number;
  menuBarPrimaryProviderId?: string;
  providerOverrides: Array<{ providerId: string; displayName?: string; enabled?: boolean }>;
};

declare global {
  interface Window {
    tokenMeter: {
      settings: {
        get(): Promise<SettingsSnapshot>;
        update(patch: unknown, expectedVersion: number): Promise<{ requestedVersion: number; status: string }>;
      };
      dashboard: {
        queryOverview(filter: unknown): Promise<{ providers: unknown[]; totalTokens: number }>;
        queryDailyUsage(filter: unknown): Promise<Array<{ usageDate: string; tokensTotal: number }>>;
      };
      sessions: {
        query(filter: unknown): Promise<{ items: unknown[]; total: number }>;
      };
      index: {
        status(): Promise<{ runs: unknown[]; roots: unknown[] }>;
        startFullReindex(rootId?: string): Promise<unknown>;
      };
    };
  }
}
```

- [ ] **Step 2: Add settings external store**

Create `Electron/src/renderer/stores/settingsStore.ts`:

```ts
import { useSyncExternalStore } from 'react';
import type { SettingsSnapshot } from '../api';

let snapshot: SettingsSnapshot = { version: 0, providerOverrides: [] };
let listeners: Array<() => void> = [];

export const settingsStore = {
  async load() {
    snapshot = await window.tokenMeter.settings.get();
    emit();
  },
  async updatePrimaryProvider(providerId: string) {
    await window.tokenMeter.settings.update({ menuBarPrimaryProviderId: providerId }, snapshot.version);
    await this.load();
  },
  subscribe(listener: () => void) {
    listeners = [...listeners, listener];
    return () => { listeners = listeners.filter((item) => item !== listener); };
  },
  getSnapshot() {
    return snapshot;
  }
};

function emit() {
  for (const listener of listeners) listener();
}

export function useSettings() {
  return useSyncExternalStore(settingsStore.subscribe, settingsStore.getSnapshot);
}
```

- [ ] **Step 3: Add layout and routes**

Create `Electron/src/renderer/components/Layout.tsx`:

```tsx
import React from 'react';

export type RouteName = 'dashboard' | 'sessions' | 'index' | 'settings';

export function Layout({ route, onRoute, children }: { route: RouteName; onRoute: (route: RouteName) => void; children: React.ReactNode }) {
  const items: Array<[RouteName, string]> = [
    ['dashboard', 'Dashboard'],
    ['sessions', 'Sessions'],
    ['index', 'Index Status'],
    ['settings', 'Settings']
  ];
  return (
    <main className="app-shell">
      <aside className="sidebar">
        <strong>TokenMeter</strong>
        <nav>{items.map(([id, label]) => <button key={id} className={route === id ? 'active' : ''} onClick={() => onRoute(id)}>{label}</button>)}</nav>
      </aside>
      <section className="content">{children}</section>
    </main>
  );
}
```

Create simple route files:

```tsx
// Electron/src/renderer/routes/Dashboard.tsx
import React from 'react';
export function Dashboard() { return <><h1>Dashboard</h1><p>Provider、agent、project 的 token 使用概览。</p></>; }
```

```tsx
// Electron/src/renderer/routes/Sessions.tsx
import React from 'react';
export function Sessions() { return <><h1>Sessions</h1><p>按 agent、project、model 和时间过滤本地会话。</p></>; }
```

```tsx
// Electron/src/renderer/routes/IndexStatus.tsx
import React from 'react';
export function IndexStatus() { return <><h1>Index Status</h1><p>查看扫描 root、增量状态和失败文件。</p></>; }
```

```tsx
// Electron/src/renderer/routes/Settings.tsx
import React, { useEffect } from 'react';
import { settingsStore, useSettings } from '../stores/settingsStore';
export function Settings() {
  const settings = useSettings();
  useEffect(() => { void settingsStore.load(); }, []);
  return (
    <>
      <h1>Settings</h1>
      <label>
        菜单栏主 provider
        <select value={settings.menuBarPrimaryProviderId ?? ''} onChange={(event) => void settingsStore.updatePrimaryProvider(event.target.value)}>
          <option value="codex">Codex</option>
          <option value="claude-code">Claude Code</option>
          <option value="zhipu">智谱</option>
        </select>
      </label>
      <p className="muted">保存后会通知 Swift 菜单栏热应用。</p>
    </>
  );
}
```

- [ ] **Step 4: Update App route state**

Modify `Electron/src/renderer/App.tsx`:

```tsx
import React, { useState } from 'react';
import { createRoot } from 'react-dom/client';
import { Layout, type RouteName } from './components/Layout';
import { Dashboard } from './routes/Dashboard';
import { Sessions } from './routes/Sessions';
import { IndexStatus } from './routes/IndexStatus';
import { Settings } from './routes/Settings';
import './styles.css';

function App() {
  const [route, setRoute] = useState<RouteName>('dashboard');
  return (
    <Layout route={route} onRoute={setRoute}>
      {route === 'dashboard' && <Dashboard />}
      {route === 'sessions' && <Sessions />}
      {route === 'index' && <IndexStatus />}
      {route === 'settings' && <Settings />}
    </Layout>
  );
}

createRoot(document.getElementById('root')!).render(<App />);
```

- [ ] **Step 5: Update CSS for product UI**

Modify `Electron/src/renderer/styles.css` to include button and form states:

```css
button, select {
  font: inherit;
}

.sidebar button {
  text-align: left;
  border: 0;
  border-radius: 8px;
  padding: 9px 10px;
  color: oklch(34% 0.016 255);
  background: transparent;
  cursor: pointer;
}

.sidebar button.active,
.sidebar button:hover {
  background: oklch(90% 0.015 255);
}

label {
  display: grid;
  gap: 8px;
  max-width: 360px;
  font-weight: 600;
}

select {
  border: 1px solid oklch(82% 0.012 255);
  border-radius: 8px;
  padding: 8px 10px;
  background: oklch(99% 0.004 255);
}

.muted {
  color: oklch(52% 0.012 255);
}
```

- [ ] **Step 6: Run Electron checks**

Run:

```bash
npm run typecheck --prefix Electron
npm test --prefix Electron
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Electron/src/renderer
git commit -m "feat: add electron dashboard shell"
```

---

## Task 14: Add Electron query repositories for dashboard, sessions, and index status

**Files:**
- Create: `Electron/src/main/dashboardRepository.ts`
- Create: `Electron/src/main/sessionsRepository.ts`
- Create: `Electron/src/main/indexStatusRepository.ts`
- Modify: `Electron/src/main/ipc.ts`
- Tests: repository tests in `Electron/src/main/*.test.ts`

- [ ] **Step 1: Write dashboard repository test**

Create `Electron/src/main/dashboardRepository.test.ts`:

```ts
import Database from 'better-sqlite3';
import { describe, expect, it } from 'vitest';
import { DashboardRepository } from './dashboardRepository';

describe('DashboardRepository', () => {
  it('reads daily token rollups without raw source scans', () => {
    const db = new Database(':memory:');
    db.exec(`CREATE TABLE provider_daily_usage(usage_date TEXT, provider_id TEXT, project_id INTEGER, source_kind TEXT, sessions_count INTEGER, tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER, tokens_cache_read INTEGER, tokens_cache_write INTEGER, total_cost_usd_micros INTEGER, PRIMARY KEY(usage_date, provider_id, project_id, source_kind));`);
    db.prepare(`INSERT INTO provider_daily_usage VALUES ('2026-07-03', 'codex', NULL, 'codex_jsonl', 2, 100, 50, 10, 20, 5, 0)`).run();
    const rows = new DashboardRepository(db).dailyUsage({ from: '2026-07-01', to: '2026-07-04' });
    expect(rows[0].tokensTotal).toBe(185);
  });
});
```

- [ ] **Step 2: Implement dashboard repository**

Create `Electron/src/main/dashboardRepository.ts`:

```ts
import type Database from 'better-sqlite3';

export class DashboardRepository {
  constructor(private readonly db: Database.Database) {}

  dailyUsage(filter: { from: string; to: string; providerId?: string; projectId?: number }) {
    const rows = this.db.prepare(`
      SELECT usage_date as usageDate, provider_id as providerId,
             tokens_input + tokens_output + tokens_reasoning + tokens_cache_read + tokens_cache_write as tokensTotal
      FROM provider_daily_usage
      WHERE usage_date BETWEEN ? AND ?
        AND (? IS NULL OR provider_id = ?)
        AND (? IS NULL OR project_id = ?)
      ORDER BY usage_date ASC
    `).all(filter.from, filter.to, filter.providerId ?? null, filter.providerId ?? null, filter.projectId ?? null, filter.projectId ?? null);
    return rows as Array<{ usageDate: string; providerId: string; tokensTotal: number }>;
  }
}
```

- [ ] **Step 3: Implement sessions and index status repositories**

Create `Electron/src/main/sessionsRepository.ts`:

```ts
import type Database from 'better-sqlite3';

export class SessionsRepository {
  constructor(private readonly db: Database.Database) {}

  query(filter: { limit?: number; offset?: number; providerId?: string }) {
    const limit = filter.limit ?? 50;
    const offset = filter.offset ?? 0;
    const items = this.db.prepare(`
      SELECT s.id, s.source_session_key as sessionKey, s.provider_id as providerId,
             s.model_name as modelName, s.cwd_path as cwdPath, s.session_updated_at as updatedAt,
             u.tokens_total as tokensTotal
      FROM agent_sessions s
      LEFT JOIN session_usage_latest ul ON ul.session_id = s.id
      LEFT JOIN session_usage u ON u.id = ul.session_usage_id
      WHERE (? IS NULL OR s.provider_id = ?) AND s.status != 'deleted'
      ORDER BY s.session_updated_at DESC
      LIMIT ? OFFSET ?
    `).all(filter.providerId ?? null, filter.providerId ?? null, limit, offset);
    const total = this.db.prepare(`SELECT count(*) as count FROM agent_sessions WHERE (? IS NULL OR provider_id = ?) AND status != 'deleted'`)
      .get(filter.providerId ?? null, filter.providerId ?? null) as { count: number };
    return { items, total: total.count };
  }
}
```

Create `Electron/src/main/indexStatusRepository.ts`:

```ts
import type Database from 'better-sqlite3';

export class IndexStatusRepository {
  constructor(private readonly db: Database.Database) {}

  status() {
    const roots = this.db.prepare(`SELECT id, kind, root_path as rootPath, display_name as displayName, enabled, last_error as lastError FROM scan_roots ORDER BY id`).all();
    const runs = this.db.prepare(`SELECT id, scan_root_id as scanRootId, status, files_seen as filesSeen, files_changed as filesChanged, started_at as startedAt, finished_at as finishedAt FROM scan_runs ORDER BY id DESC LIMIT 20`).all();
    return { roots, runs };
  }
}
```

- [ ] **Step 4: Wire IPC handlers**

Modify `Electron/src/main/ipc.ts`:

```ts
import { DashboardRepository } from './dashboardRepository.js';
import { SessionsRepository } from './sessionsRepository.js';
import { IndexStatusRepository } from './indexStatusRepository.js';
```

Inside `registerIpcHandlers()` after DB creation:

```ts
const dashboard = new DashboardRepository(db);
const sessions = new SessionsRepository(db);
const indexStatus = new IndexStatusRepository(db);
```

Replace stubs:

```ts
ipcMain.handle('dashboard:dailyUsage', async (_event, filter) => dashboard.dailyUsage(filter));
ipcMain.handle('sessions:query', async (_event, filter) => sessions.query(filter));
ipcMain.handle('index:status', async () => indexStatus.status());
```

- [ ] **Step 5: Run Electron tests**

Run:

```bash
npm test --prefix Electron
npm run typecheck --prefix Electron
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Electron/src/main/dashboardRepository.ts Electron/src/main/sessionsRepository.ts Electron/src/main/indexStatusRepository.ts Electron/src/main/ipc.ts Electron/src/main/dashboardRepository.test.ts
git commit -m "feat: query sqlite analytics from electron"
```

---

## Task 15: Hardening: append offsets, rollups, privacy proof, and verification

**Files:**
- Modify: `Sources/TokenMeterCore/LocalAgentScanner.swift`
- Modify: `Sources/TokenMeterCore/LocalAgentUsageRepository.swift`
- Modify: `Tests/TokenMeterCoreTests/LocalAgentScannerTests.swift`
- Modify: `Tests/TokenMeterCoreTests/PrivacyIndexingTests.swift`
- Modify: `README.md`

- [ ] **Step 1: Add scanner append test**

Append to `LocalAgentScannerTests`:

```swift
func testScannerProcessesAppendedJSONLWithoutDuplicatingSession() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("rollout.jsonl")
    try Data((#"{"type":"session_meta","payload":{"id":"s1","cwd":"/repo"}}"# + "\n" + #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,"output_tokens":2}}}}"# + "\n").utf8).write(to: file)
    let database = try SQLiteDatabase(path: ":memory:")
    try TokenMeterDatabaseMigrator.migrate(database)
    try database.execute("INSERT INTO scan_roots(id, kind, root_path, display_name, stable_source_key) VALUES (1, 'codex_jsonl', ?, 'Codex', 'codex-test')", [.text(directory.path)])
    let scanner = LocalAgentScanner(database: database)

    try await scanner.scanRoot(id: 1)
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((#"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":3,"output_tokens":4}}}}"# + "\n").utf8))
    try handle.close()
    try await scanner.scanRoot(id: 1)

    XCTAssertEqual(try database.query("SELECT count(*) AS count FROM agent_sessions")[0].int("count"), 1)
    XCTAssertEqual(try database.query("SELECT tokens_total FROM session_usage ORDER BY usage_seq DESC LIMIT 1")[0].int("tokens_total"), 7)
}
```

- [ ] **Step 2: Run append test and verify it fails or duplicates**

Run:

```bash
swift test --filter LocalAgentScannerTests/testScannerProcessesAppendedJSONLWithoutDuplicatingSession
```

Expected: FAIL before append-state fix.

- [ ] **Step 3: Store parser state offset and use it for appends**

Modify `LocalAgentScanner.scanJSONLFile`:

- Read `parser_state` JSON from `source_files`.
- If file grew and `parser_state.lastOffset` exists, start at that offset.
- For parser correctness, include already-known session metadata. Store `sessionKey`, `projectPath`, and `modelName` in parser state so appended token-only lines still attach to the right session.
- After parsing, update `parser_state` with `lastOffset`, `sessionKey`, `projectPath`, `modelName`, `lastUsageSeq`.

Use this Codable state:

```swift
private struct JSONLParserState: Codable {
    var lastOffset: Int64
    var sessionKey: String?
    var projectPath: String?
    var modelName: String?
    var lastUsageSeq: Int
}
```

If appended lines lack session metadata, merge parser result with previous state before upserting.

- [ ] **Step 4: Add daily rollup update**

Modify `LocalAgentUsageRepository.upsert` so after writing latest usage it updates `provider_daily_usage` for the session date:

```swift
try database.execute(
    """
    INSERT INTO provider_daily_usage(usage_date, provider_id, project_id, source_kind, sessions_count, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, total_cost_usd_micros)
    VALUES (?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(usage_date, provider_id, project_id, source_kind) DO UPDATE SET
      sessions_count = sessions_count + 1,
      tokens_input = excluded.tokens_input,
      tokens_output = excluded.tokens_output,
      tokens_reasoning = excluded.tokens_reasoning,
      tokens_cache_read = excluded.tokens_cache_read,
      tokens_cache_write = excluded.tokens_cache_write,
      total_cost_usd_micros = excluded.total_cost_usd_micros
    """,
    [.text(dayString), .text(providerId), sqliteInt(projectId), .text(session.sourceKind.rawValue), sqliteInt(usage.inputTokens), sqliteInt(usage.outputTokens), sqliteInt(usage.reasoningTokens), sqliteInt(usage.cacheReadTokens), sqliteInt(usage.cacheWriteTokens), sqliteInt(usage.costUSDMicros)]
)
```

Before implementing, add a test asserting `provider_daily_usage` receives a row for an upserted session.

- [ ] **Step 5: Add privacy database test**

Append to `PrivacyIndexingTests`:

```swift
func testIndexedDatabaseDoesNotContainMessageBody() throws {
    let database = try SQLiteDatabase(path: ":memory:")
    try TokenMeterDatabaseMigrator.migrate(database)
    let repository = LocalAgentUsageRepository(database: database)
    let parsed = ParsedAgentSession(
        sourceKind: .codexJSONL,
        sessionKey: "privacy-session",
        projectPath: "/repo",
        modelName: "model",
        cliVersion: nil,
        startedAt: nil,
        updatedAt: nil,
        usage: ParsedSessionUsage(inputTokens: 1, outputTokens: 2, reasoningTokens: nil, cacheReadTokens: nil, cacheWriteTokens: nil, costUSDMicros: nil),
        usageSequence: 1,
        sourceOffset: 1,
        rawMeta: ["source": "codex"]
    )

    try repository.upsert(parsed, scanRootId: 1, sourceFileId: nil, runId: nil)

    let dump = try database.query("SELECT coalesce(raw_meta_json, '') AS value FROM agent_sessions").compactMap { $0.string("value") }.joined(separator: "\n")
    XCTAssertFalse dump.contains("SECRET")
}
```

Fix syntax if needed to `XCTAssertFalse(dump.contains("SECRET"))`.

- [ ] **Step 6: Update README**

Add to README:

```markdown
## 第二阶段开发

Swift 菜单栏仍可单独运行：

```bash
swift run TokenMeterApp
```

Electron 主界面在 `Electron/` 下开发：


```bash
npm install --prefix Electron
npm run dev --prefix Electron
```

隐私约束：TokenMeter SQLite 只保存 session 元数据、token usage、cost、扫描状态和设置，不保存 prompt、assistant response、tool output、reasoning、attachments 或凭据。
```

- [ ] **Step 7: Run hardening tests**

Run:

```bash
swift test --filter LocalAgentScannerTests
swift test --filter LocalAgentUsageRepositoryTests
swift test --filter PrivacyIndexingTests
```

Expected: PASS.

- [ ] **Step 8: Run final Swift verification**

Run:

```bash
swift test
swift build
```

Expected: PASS.

- [ ] **Step 9: Run final Electron verification**

Run:

```bash
npm test --prefix Electron
npm run typecheck --prefix Electron
npm run build --prefix Electron
```

Expected: PASS.

- [ ] **Step 10: Manual smoke test**

Run Swift menu bar app:

```bash
swift run TokenMeterApp
```

Then run Electron dev UI:

```bash
npm run dev --prefix Electron
npm run electron --prefix Electron
```

Verify:

- Swift menu bar still appears when Electron is closed.
- Electron Settings can change `menuBar.primaryProviderId`.
- Swift menu bar applies the changed primary provider without restart.
- Index Status shows scan roots and recent scan runs.
- Sessions view shows session metadata and token totals only.
- No prompt, assistant response, reasoning, tool output, attachment body, cookie, or credential appears in TokenMeter SQLite tables.

- [ ] **Step 11: Commit hardening and docs**

```bash
git add Sources/TokenMeterCore/LocalAgentScanner.swift Sources/TokenMeterCore/LocalAgentUsageRepository.swift Tests/TokenMeterCoreTests/LocalAgentScannerTests.swift Tests/TokenMeterCoreTests/PrivacyIndexingTests.swift README.md
git commit -m "feat: harden local session indexing"
```

---

## Self-Review Checklist for Implementers

Before declaring the implementation complete, verify every item below with actual tool output:

- `swift test` passes.
- `swift build` passes.
- `npm test --prefix Electron` passes.
- `npm run typecheck --prefix Electron` passes.
- `npm run build --prefix Electron` passes.
- Electron renderer uses preload APIs only.
- Electron main writes settings tables only; it does not write `agent_sessions`, `session_usage`, `session_usage_latest`, or `provider_daily_usage`.
- Swift is the single writer for session/index fact tables.
- The scanner skips unchanged files.
- The scanner handles appended JSONL without duplicating sessions.
- The scanner handles large JSONL through streaming logic, not one whole-file JSON parse.
- OpenCode uses high-water query logic, not full historical aggregation on every refresh.
- `session_usage_latest` is updated for menu-bar reads.
- `provider_daily_usage` is updated for Electron charts.
- SQLite contains no prompt, assistant response, reasoning, tool output, attachment body, cookie, API key, or credential value.
- Electron settings changes trigger Swift settings reload and menu-bar update without app restart.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-03-tokenmeter-phase2-hybrid-sessions.md`.

Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, faster iteration and cleaner isolation.
2. **Inline Execution** — execute tasks in this session using an execution skill, with checkpoints between batches.

Recommended: Subagent-Driven. This plan spans Swift database work, parsers, app wiring, IPC, Electron, UI, and hardening; independent tasks can run in parallel after the SQLite foundation lands.