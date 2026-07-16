# 菜单栏样式族 + 定制化设置 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 菜单栏额度组件支持 16 种可切换样式与全套定制开关（元素/窗口/今日尾巴/按家配置/窗口顺序），在 Electron 设置页「菜单栏外观」下钻页中配置、即时生效。

**Architecture:** 设置沿现有链路（Electron SettingsRepository 写 SQLite → notifySwift → Swift reloadSettings → 菜单栏重投影）。Swift 端把 `MenuBarQuotaModel` 升级为纯函数投影（settings + snapshots + todaySummary → `MenuBarProjection`），SwiftUI 视图层按样式分发渲染；Electron 端新增下钻页与演示口径预览渲染器。规则权威 = spec `docs/superpowers/specs/2026-07-17-menubar-styles-implementation-design.md`（含 16 样式规则表、元素锁定、切换副作用）。

**Tech Stack:** Swift 5.9 / SwiftUI / XCTest；TypeScript / React / vitest / better-sqlite3。

**测试命令**：Swift `swift test --filter <TestClass>`（全量 `swift test`）；Electron `cd Electron && npx vitest run <file>`（全量 `npm test`）。

---

## 文件结构

| 文件 | 职责 |
|---|---|
| `Sources/TokenMeterCore/SettingsModels.swift`（改） | `MenuBarStyleId`/`MenuBarWindowChoice`/`MenuBarUsageTail`/`MenuBarWindowOrder`/`MenuBarAppearanceSettings` 新类型；`SettingsSnapshot`、`ProviderConfigOverride` 扩展 |
| `Sources/TokenMeterCore/TokenMeterDatabaseSchema.swift`（改） | overrides 表定义加 2 列 |
| `Sources/TokenMeterCore/TokenMeterDatabaseMigrator.swift`（改） | 配置表 additive 列迁移（幂等） |
| `Sources/TokenMeterCore/SettingsStore.swift`（改） | snapshot() 读新 kv 与新列 |
| `Sources/TokenMeterApp/MenuBarQuotaModel.swift`（重构） | 投影模型：Cell（双窗+choices+stale+mono）、`MenuBarProjection`、effective 元素、worst/聚合/哨兵/降级纯函数 |
| `Sources/TokenMeterApp/MenuBarStyleViews.swift`（新） | 16 样式 SwiftUI 视图 + 共享小件（tone 色、数字组、deck unit、mini logo） |
| `Sources/TokenMeterApp/StatusBarController.swift`（改） | `StatusBarContentView` 按 projection 分发；bindStore 三源合并 |
| `Electron/src/main/settingsRepository.ts`（改） | ensure 列、patch 新字段 + 校验、snapshot 新字段 |
| `Electron/src/renderer/api.ts`（改） | 类型同步（`MenubarAppearance`、patch 字段） |
| `Electron/src/renderer/components/MenubarPreview.tsx`（新） | 演示口径预览渲染器（16 样式，稿 JS 的 React 翻译） |
| `Electron/src/renderer/components/MenubarAppearance.tsx`（新） | 下钻页（预览/画廊/元素/今日/按家表格/窗口顺序） |
| `Electron/src/renderer/routes/Settings.tsx`（改） | 入口摘要卡 + main/menubar 子页切换 |
| `Electron/src/renderer/styles.css`（改） | `.mb*` 预览样式 + 画廊/入口卡样式（移植设计稿，品牌青禁入 cell） |

规则去重说明：元素锁定/切换副作用两端各实现一份（Swift 归一化渲染、Electron 设置 UI），无法共享代码——两处注释互指 spec §3 表格，测试各自覆盖同一张表。

---

### Task 1: Swift 设置模型、schema 迁移与读取

**Files:**
- Modify: `Sources/TokenMeterCore/SettingsModels.swift`
- Modify: `Sources/TokenMeterCore/TokenMeterDatabaseSchema.swift`（`provider_config_overrides` CREATE TABLE 段，行 53-61 附近）
- Modify: `Sources/TokenMeterCore/TokenMeterDatabaseMigrator.swift`
- Modify: `Sources/TokenMeterCore/SettingsStore.swift`
- Test: `Tests/TokenMeterCoreTests/SettingsStoreTests.swift`

- [ ] **Step 1: 写失败测试**（追加到 `SettingsStoreTests.swift`；该文件已有内存库/建表辅助，沿用其现有 helper 建 store——先读文件头 30 行确认 helper 名，下面假设 `makeStore()` 风格不存在时按现有模式内联建库）

```swift
func testMenuBarAppearanceDefaultsWhenUnset() throws {
    let database = try SQLiteDatabase(path: ":memory:")
    try TokenMeterDatabaseMigrator.migrate(database)
    let store = SettingsStore(database: database)
    let snapshot = try store.snapshot()
    XCTAssertEqual(snapshot.menuBarAppearance, .default)
    XCTAssertEqual(snapshot.menuBarAppearance.style, .rings)
    XCTAssertEqual(snapshot.menuBarAppearance.windowOrder, .longFirst)
}

func testMenuBarAppearanceReadsStoredValues() throws {
    let database = try SQLiteDatabase(path: ":memory:")
    try TokenMeterDatabaseMigrator.migrate(database)
    try database.execute(
        "INSERT OR REPLACE INTO settings(key, value_json, value_type, version, updated_by) VALUES ('menubar.style', '\"deck2\"', 'string', 2, 'electron')"
    )
    try database.execute(
        "INSERT OR REPLACE INTO settings(key, value_json, value_type, version, updated_by) VALUES ('menubar.showName', '0', 'int', 2, 'electron')"
    )
    try database.execute(
        "INSERT OR REPLACE INTO settings(key, value_json, value_type, version, updated_by) VALUES ('menubar.usage', '\"cost\"', 'string', 2, 'electron')"
    )
    try database.execute(
        "INSERT OR REPLACE INTO settings(key, value_json, value_type, version, updated_by) VALUES ('menubar.windowOrder', '\"shortFirst\"', 'string', 2, 'electron')"
    )
    try database.execute(
        "INSERT INTO provider_config_overrides(provider_id, menubar_glyph_window, menubar_number_window) VALUES ('claude-code', 'both', 'short')"
    )
    let snapshot = try SettingsStore(database: database).snapshot()
    XCTAssertEqual(snapshot.menuBarAppearance.style, .deck2)
    XCTAssertFalse(snapshot.menuBarAppearance.showName)
    XCTAssertTrue(snapshot.menuBarAppearance.showGlyph)
    XCTAssertEqual(snapshot.menuBarAppearance.usage, .cost)
    XCTAssertEqual(snapshot.menuBarAppearance.windowOrder, .shortFirst)
    let override = snapshot.providerOverrides.first { $0.providerId == "claude-code" }
    XCTAssertEqual(override?.menuBarGlyphWindow, .both)
    XCTAssertEqual(override?.menuBarNumberWindow, .short)
}

func testMenuBarAppearanceUnknownValuesFallBackToDefault() throws {
    let database = try SQLiteDatabase(path: ":memory:")
    try TokenMeterDatabaseMigrator.migrate(database)
    try database.execute(
        "INSERT OR REPLACE INTO settings(key, value_json, value_type, version, updated_by) VALUES ('menubar.style', '\"holographic\"', 'string', 2, 'electron')"
    )
    let snapshot = try SettingsStore(database: database).snapshot()
    XCTAssertEqual(snapshot.menuBarAppearance.style, .rings)
}

func testMigratorAddsMenubarColumnsToLegacyOverridesTable() throws {
    let database = try SQLiteDatabase(path: ":memory:")
    // 老库：无 menubar 列的 overrides 表已存在
    try database.execute(
        """
        CREATE TABLE provider_config_overrides (
          provider_id TEXT PRIMARY KEY,
          enabled INTEGER CHECK (enabled IN (0,1)),
          display_name TEXT,
          menu_rank INTEGER,
          show_in_menu_bar INTEGER CHECK (show_in_menu_bar IN (0,1)),
          show_in_charts INTEGER CHECK (show_in_charts IN (0,1)),
          updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        )
        """
    )
    try database.execute("INSERT INTO provider_config_overrides(provider_id, enabled) VALUES ('zhipu', 1)")
    try TokenMeterDatabaseMigrator.migrate(database)
    let columns = try database.query("PRAGMA table_info(provider_config_overrides)").compactMap { $0.string("name") }
    XCTAssertTrue(columns.contains("menubar_glyph_window"))
    XCTAssertTrue(columns.contains("menubar_number_window"))
    // 旧行保留
    XCTAssertEqual(try database.query("SELECT count(*) AS c FROM provider_config_overrides")[0].int("c"), 1)
    // 幂等：再跑一次不炸
    try TokenMeterDatabaseMigrator.migrate(database)
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter SettingsStoreTests 2>&1 | tail -20`
Expected: 编译失败（`menuBarAppearance`、`menuBarGlyphWindow` 不存在）——类型未定义即视为 RED。

- [ ] **Step 3: 实现类型与迁移**

`SettingsModels.swift` 文件末尾追加：

```swift
/// 菜单栏样式族（OpenDesign 稿 S0-S15，rawValue 与 Electron 端/DB 存储一致）。
public enum MenuBarStyleId: String, Codable, Equatable, CaseIterable {
    case rings, vbars, hbar, digits, dots, caps, ticks, ring1
    case grid, sentinel, monogram, strip, tagnum, deck2, ringdeck, barsdeck
}

/// 按家窗口选择：short=5h 类短窗、long=7d 类长窗。图形与数字各自独立。
public enum MenuBarWindowChoice: String, Codable, Equatable {
    case short, long, both
}

public enum MenuBarUsageTail: String, Codable, Equatable {
    case off, tok, cost
}

/// both 时的呈现顺序（图形双元素与双数字一致翻转）。默认 longFirst 保持
/// 既有 S0 视觉（外环/第一位数字 = 7d）；用户裁定做成设置项而非写死。
public enum MenuBarWindowOrder: String, Codable, Equatable {
    case longFirst, shortFirst
}

public struct MenuBarAppearanceSettings: Codable, Equatable {
    public let style: MenuBarStyleId
    public let showName: Bool
    public let showGlyph: Bool
    public let showNumber: Bool
    public let usage: MenuBarUsageTail
    public let windowOrder: MenuBarWindowOrder

    public static let `default` = MenuBarAppearanceSettings(
        style: .rings,
        showName: true,
        showGlyph: true,
        showNumber: true,
        usage: .tok,
        windowOrder: .longFirst
    )

    public init(
        style: MenuBarStyleId,
        showName: Bool,
        showGlyph: Bool,
        showNumber: Bool,
        usage: MenuBarUsageTail,
        windowOrder: MenuBarWindowOrder
    ) {
        self.style = style
        self.showName = showName
        self.showGlyph = showGlyph
        self.showNumber = showNumber
        self.usage = usage
        self.windowOrder = windowOrder
    }
}
```

`ProviderConfigOverride` 加两个存储属性（放 `showInCharts` 之后）与 init 参数（默认 nil，避免翻新既有调用点）：

```swift
    public let menuBarGlyphWindow: MenuBarWindowChoice?
    public let menuBarNumberWindow: MenuBarWindowChoice?

    public init(
        providerId: String,
        enabled: Bool?,
        displayName: String?,
        menuRank: Int?,
        showInMenuBar: Bool?,
        showInCharts: Bool?,
        menuBarGlyphWindow: MenuBarWindowChoice? = nil,
        menuBarNumberWindow: MenuBarWindowChoice? = nil
    ) {
        self.providerId = providerId
        self.enabled = enabled
        self.displayName = displayName
        self.menuRank = menuRank
        self.showInMenuBar = showInMenuBar
        self.showInCharts = showInCharts
        self.menuBarGlyphWindow = menuBarGlyphWindow
        self.menuBarNumberWindow = menuBarNumberWindow
    }
```

`SettingsSnapshot` 加 `public let menuBarAppearance: MenuBarAppearanceSettings`，init 参数 `menuBarAppearance: MenuBarAppearanceSettings = .default`（放 `quotaUsedThresholdPercent` 之后，同样带默认值保既有调用点）。

`TokenMeterDatabaseSchema.swift` 的 `provider_config_overrides` 建表语句在 `show_in_charts` 行后加：

```sql
      menubar_glyph_window TEXT CHECK (menubar_glyph_window IN ('short','long','both')),
      menubar_number_window TEXT CHECK (menubar_number_window IN ('short','long','both')),
```

`TokenMeterDatabaseMigrator.swift`：读全文后，在 `migrate(_:)` 里配置表建表语句执行之后、`user_version` 短路判断之前插入 `try ensureConfigColumns(database)` 调用（additive 迁移必须每次跑，不受版本短路影响），并新增私有函数：

```swift
    /// 配置表（settings / provider_config_overrides）不参与版本重建，
    /// 新增列走幂等 additive 迁移：缺列才 ALTER，老库数据原样保留。
    private static func ensureConfigColumns(_ database: SQLiteDatabase) throws {
        let columns = try database.query("PRAGMA table_info(provider_config_overrides)")
            .compactMap { $0.string("name") }
        if !columns.contains("menubar_glyph_window") {
            try database.execute(
                "ALTER TABLE provider_config_overrides ADD COLUMN menubar_glyph_window TEXT CHECK (menubar_glyph_window IN ('short','long','both'))"
            )
        }
        if !columns.contains("menubar_number_window") {
            try database.execute(
                "ALTER TABLE provider_config_overrides ADD COLUMN menubar_number_window TEXT CHECK (menubar_number_window IN ('short','long','both'))"
            )
        }
    }
```

`SettingsStore.swift`：`snapshot()` 的 SELECT 加两列 `menubar_glyph_window, menubar_number_window`，行映射加：

```swift
                menuBarGlyphWindow: row.string("menubar_glyph_window").flatMap(MenuBarWindowChoice.init(rawValue:)),
                menuBarNumberWindow: row.string("menubar_number_window").flatMap(MenuBarWindowChoice.init(rawValue:))
```

`snapshot()` 返回值组装 `menuBarAppearance`（非法/缺失一律回默认，向后兼容）：

```swift
        let appearance = MenuBarAppearanceSettings(
            style: (try? settingString("menubar.style")).flatMap { $0.flatMap(MenuBarStyleId.init(rawValue:)) } ?? .rings,
            showName: ((try? settingInt("menubar.showName")) ?? 1) != 0,
            showGlyph: ((try? settingInt("menubar.showGlyph")) ?? 1) != 0,
            showNumber: ((try? settingInt("menubar.showNumber")) ?? 1) != 0,
            usage: (try? settingString("menubar.usage")).flatMap { $0.flatMap(MenuBarUsageTail.init(rawValue:)) } ?? .tok,
            windowOrder: (try? settingString("menubar.windowOrder")).flatMap { $0.flatMap(MenuBarWindowOrder.init(rawValue:)) } ?? .longFirst
        )
```

注意 `settingInt` 返回 `Int64?`、`try?` 包裹后是双层 Optional，`?? 1` 前先 `((try? ...) ?? nil)` 展平——实现时以编译器为准展平（`let raw = (try? settingInt("menubar.showName")) ?? nil; showName: (raw ?? 1) != 0`）。

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter SettingsStoreTests 2>&1 | tail -5`
Expected: 全部 PASS（含既有测试——新 init 参数带默认值不破坏旧构造）。

- [ ] **Step 5: 全量 Swift 测试防回归 + commit**

Run: `swift test 2>&1 | tail -5` → 全绿。

```bash
git add Sources/TokenMeterCore/SettingsModels.swift Sources/TokenMeterCore/TokenMeterDatabaseSchema.swift Sources/TokenMeterCore/TokenMeterDatabaseMigrator.swift Sources/TokenMeterCore/SettingsStore.swift Tests/TokenMeterCoreTests/SettingsStoreTests.swift
git commit -m "feat: menubar appearance settings schema + Swift read path"
```

---

### Task 2: Electron 存储层（列 ensure + patch 字段 + 类型链）

**Files:**
- Modify: `Electron/src/main/settingsRepository.ts`
- Modify: `Electron/src/renderer/api.ts`（`ProviderConfigOverride`/`SettingsSnapshot`/`SettingsPatch` 段，行 27-56）
- Test: `Electron/src/main/settingsRepository.test.ts`

- [ ] **Step 1: 写失败测试**（追加到 `settingsRepository.test.ts`，沿用文件内既有内存库构造模式——先读文件头确认建库 helper）

```ts
describe('menubar appearance settings', () => {
  it('returns defaults when nothing stored', () => {
    const repo = makeRepo(); // 沿用文件既有 helper；若名称不同以现有为准
    const snapshot = repo.get();
    expect(snapshot.menubarAppearance).toEqual({
      style: 'rings',
      showName: true,
      showGlyph: true,
      showNumber: true,
      usage: 'tok',
      windowOrder: 'longFirst'
    });
  });

  it('adds menubar columns to a legacy overrides table (idempotent)', () => {
    const db = makeLegacyDb(); // 建一个无 menubar 列的 provider_config_overrides 老表
    const repo = new SettingsRepository(db);
    const again = new SettingsRepository(db); // 第二次构造不抛
    expect(again.get().providerOverrides).toEqual(repo.get().providerOverrides);
    const cols = db.prepare('PRAGMA table_info(provider_config_overrides)').all() as Array<{ name: string }>;
    expect(cols.map((c) => c.name)).toContain('menubar_glyph_window');
    expect(cols.map((c) => c.name)).toContain('menubar_number_window');
  });

  it('applies menubar patch fields and bumps version', () => {
    const repo = makeRepo();
    const v0 = repo.get().version;
    const result = repo.update(
      {
        menubarStyle: 'deck2',
        menubarShowName: false,
        menubarUsage: 'cost',
        menubarWindowOrder: 'shortFirst',
        providerMenubarVisible: { codex: false },
        providerGlyphWindow: { 'claude-code': 'both' },
        providerNumberWindow: { 'claude-code': 'short' }
      },
      v0
    );
    expect(result.status).toBe('pending');
    const snapshot = repo.get();
    expect(snapshot.version).toBe(v0 + 1);
    expect(snapshot.menubarAppearance.style).toBe('deck2');
    expect(snapshot.menubarAppearance.showName).toBe(false);
    expect(snapshot.menubarAppearance.showGlyph).toBe(true);
    expect(snapshot.menubarAppearance.usage).toBe('cost');
    expect(snapshot.menubarAppearance.windowOrder).toBe('shortFirst');
    const codex = snapshot.providerOverrides.find((o) => o.providerId === 'codex');
    expect(codex?.showInMenuBar).toBe(false);
    const claude = snapshot.providerOverrides.find((o) => o.providerId === 'claude-code');
    expect(claude?.menubarGlyphWindow).toBe('both');
    expect(claude?.menubarNumberWindow).toBe('short');
  });

  it('rejects invalid enum values', () => {
    const repo = makeRepo();
    const v0 = repo.get().version;
    expect(() => repo.update({ menubarStyle: 'holographic' }, v0)).toThrow(/menubarStyle/);
    expect(() => repo.update({ menubarUsage: 'gold' }, v0)).toThrow(/menubarUsage/);
    expect(() => repo.update({ providerGlyphWindow: { codex: 'weekly' } }, v0)).toThrow(/providerGlyphWindow/);
    expect(() => repo.update({ menubarWindowOrder: 'upsideDown' }, v0)).toThrow(/menubarWindowOrder/);
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd Electron && npx vitest run src/main/settingsRepository.test.ts 2>&1 | tail -10`
Expected: FAIL（`menubarAppearance` undefined / update 抛 unknown key——按现 validate 实现是忽略未知键，则第一条断言 fail）。

- [ ] **Step 3: 实现**

`settingsRepository.ts`：

```ts
export const MENUBAR_STYLE_IDS = [
  'rings', 'vbars', 'hbar', 'digits', 'dots', 'caps', 'ticks', 'ring1',
  'grid', 'sentinel', 'monogram', 'strip', 'tagnum', 'deck2', 'ringdeck', 'barsdeck'
] as const;
export type MenubarStyleId = (typeof MENUBAR_STYLE_IDS)[number];
export type MenubarWindowChoice = 'short' | 'long' | 'both';

export interface MenubarAppearance {
  style: MenubarStyleId;
  showName: boolean;
  showGlyph: boolean;
  showNumber: boolean;
  usage: 'off' | 'tok' | 'cost';
  windowOrder: 'longFirst' | 'shortFirst';
}
```

- `ProviderConfigOverride` 接口加 `menubarGlyphWindow?: MenubarWindowChoice; menubarNumberWindow?: MenubarWindowChoice;`
- `SettingsSnapshot` 加 `menubarAppearance: MenubarAppearance;`
- `SettingsPatch` 加：

```ts
  menubarStyle?: MenubarStyleId;
  menubarShowName?: boolean;
  menubarShowGlyph?: boolean;
  menubarShowNumber?: boolean;
  menubarUsage?: 'off' | 'tok' | 'cost';
  menubarWindowOrder?: 'longFirst' | 'shortFirst';
  /// providerId → 菜单栏显示（写 show_in_menu_bar；独立于 enabled 的数据启停）。
  providerMenubarVisible?: Record<string, boolean>;
  providerGlyphWindow?: Record<string, MenubarWindowChoice>;
  providerNumberWindow?: Record<string, MenubarWindowChoice>;
```

- 构造器 ensure（放 constructor）：

```ts
  constructor(private readonly db: Database.Database) {
    this.ensureMenubarColumns();
  }

  /// 配置表新增列的幂等迁移：Swift 未升级/未运行时 Electron 也能安全查询。
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
```

- `get()` 组装（读 kv，非法回默认——与 Swift 同策略）：

```ts
      menubarAppearance: {
        style: this.enumSetting('menubar.style', MENUBAR_STYLE_IDS, 'rings'),
        showName: (this.settingInt('menubar.showName') ?? 1) !== 0,
        showGlyph: (this.settingInt('menubar.showGlyph') ?? 1) !== 0,
        showNumber: (this.settingInt('menubar.showNumber') ?? 1) !== 0,
        usage: this.enumSetting('menubar.usage', ['off', 'tok', 'cost'] as const, 'tok'),
        windowOrder: this.enumSetting('menubar.windowOrder', ['longFirst', 'shortFirst'] as const, 'longFirst')
      }
```

```ts
  private enumSetting<T extends string>(key: string, allowed: readonly T[], fallback: T): T {
    let raw: string | undefined;
    try {
      raw = this.settingString(key);
    } catch {
      return fallback;
    }
    return raw !== undefined && (allowed as readonly string[]).includes(raw) ? (raw as T) : fallback;
  }
```

- `providerOverrides()` SELECT 与行映射加两列（NULL 省略键，同现有风格）。
- `update()` 事务内追加（kv 写入 + overrides upsert；任一 overrides 类字段变更并入既有哨兵键条件）：

```ts
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
```

既有哨兵键条件扩为：

```ts
      if (
        validatedPatch.providerDisplayNames !== undefined ||
        validatedPatch.providerEnabled !== undefined ||
        validatedPatch.providerMenubarVisible !== undefined ||
        validatedPatch.providerGlyphWindow !== undefined ||
        validatedPatch.providerNumberWindow !== undefined
      ) {
        this.setSetting('providers.overridesUpdatedAt', JSON.stringify(new Date().toISOString()), 'string', nextVersion);
      }
```

- `validateSettingsPatch` 加各字段校验（枚举白名单、boolean 检查、Record 形状），`hasPatchChanges` 加全部新字段。校验错误信息包含字段名（测试用 `/menubarStyle/` 匹配）。
- `api.ts` 同步类型：`MenubarAppearance` 接口、`ProviderConfigOverride`/`SettingsSnapshot`/`SettingsPatch` 同名字段（保持两文件字面一致；`MENUBAR_STYLE_IDS` 在 api.ts 也导出一份常量供画廊用——renderer 不 import main 模块）。

- [ ] **Step 4: 跑测试确认通过**

Run: `cd Electron && npx vitest run src/main/settingsRepository.test.ts 2>&1 | tail -5`
Expected: PASS。

- [ ] **Step 5: Electron 全量测试 + commit**

Run: `cd Electron && npm test 2>&1 | tail -5` → 全绿（settingsStore.test.ts 的 initialSnapshot 若因类型加字段编译失败，给 `stores/settingsStore.ts` 的 `initialSnapshot` 补 `menubarAppearance` 默认对象，与 repository 默认一致）。

```bash
git add Electron/src/main/settingsRepository.ts Electron/src/main/settingsRepository.test.ts Electron/src/renderer/api.ts Electron/src/renderer/stores/settingsStore.ts
git commit -m "feat: menubar appearance settings in Electron repository + type chain"
```

---

### Task 3: Swift 投影模型（核心逻辑）

**Files:**
- Rewrite: `Sources/TokenMeterApp/MenuBarQuotaModel.swift`
- Test: `Tests/TokenMeterAppTests/MenuBarQuotaModelTests.swift`（保留可迁移的既有用例，按新 API 改写）

- [ ] **Step 1: 写失败测试**（新增核心用例；文件既有 `metric`/`snapshot` helper 沿用，另加 settings builder）

```swift
    private func appearance(
        style: MenuBarStyleId = .rings,
        name: Bool = true, glyph: Bool = true, number: Bool = true,
        usage: MenuBarUsageTail = .tok,
        order: MenuBarWindowOrder = .longFirst
    ) -> SettingsSnapshot {
        SettingsSnapshot(
            version: 1, menuBarPrimaryProviderId: nil, autoRefreshSeconds: 300,
            enabledAgentKinds: [], providerOverrides: overridesForTest,
            quotaUsedThresholdPercent: 0,
            menuBarAppearance: MenuBarAppearanceSettings(
                style: style, showName: name, showGlyph: glyph, showNumber: number,
                usage: usage, windowOrder: order
            )
        )
    }
    private var overridesForTest: [ProviderConfigOverride] = []

    func testWindowOrderControlsBothExpansion() { /* 断言 longFirst → [7d,5h]、shortFirst → [5h,7d] */ }
    func testPerProviderChoiceSplitsGlyphAndNumberWindows() { /* gwin=both nwin=short 交叉 */ }
    func testSingleWindowProviderIgnoresChoice() { /* 仅 7d 家，choice=short 仍返回唯一窗 */ }
    func testWorstPicksLowestRemaining() {}
    func testEffectiveElementsLockTable() { /* spec §3 锁定表逐条断言 */ }
    func testAtLeastOneElementFallback() { /* 全关→glyph 兜底；digits 全关→number 兜底 */ }
    func testMonogramDeduplicates() { /* [CC,CX,智谱,OMP] → [C,X,智,O] */ }
    func testSentinelQuietAlertAndStale() { /* 三态 + 红优先于黄 */ }
    func testDigitsCJKDualDegradesToWorst() { /* 智谱 both+name → degraded */ }
    func testStaleCellCarriesMinutes() { /* fetchedAt 12 分钟前 → staleMinutes == 12 */ }
    func testCellsFilteredByShowInMenuBar() { /* showInMenuBar=false 不产 cell */ }
    func testTailTokCostOffAndZeroHidden() { /* tok>0 文本、cost 用 usd 格式、0 → hidden */ }
```

每个测试写完整断言（此处逐个展开）：

```swift
    func testWindowOrderControlsBothExpansion() {
        let snapshots = [twoWindowSnapshot(shortRemaining: 96, longRemaining: 55)]
        let cell = MenuBarQuotaModel.projection(
            snapshots: snapshots, settings: appearance(order: .longFirst),
            todaySummary: .empty
        ).cells[0]
        XCTAssertEqual(cell.glyphWindows(order: .longFirst).map(\.roundedPercent), [55, 96])
        XCTAssertEqual(cell.glyphWindows(order: .shortFirst).map(\.roundedPercent), [96, 55])
    }
```

（其余用例同粒度：构造 → projection → 断言字段。`twoWindowSnapshot` helper 用既有 `metric(id:used:windowMinutes:)` 拼 5h=300 分钟、7d=10080 分钟两个 metric。`MenuBarTodaySummary.empty` 已存在。）

哨兵用例明确断言：

```swift
    func testSentinelQuietAlertAndStale() {
        // 全绿 → quiet
        XCTAssertEqual(MenuBarQuotaModel.sentinelState(cells: [greenCell]), .quiet)
        // 黄与红并存 → 红家胜出
        if case let .alert(cell, window) = MenuBarQuotaModel.sentinelState(cells: [warnCell, badCell]) {
            XCTAssertEqual(cell.providerId, badCell.providerId)
            XCTAssertEqual(window.tone, .bad)
        } else { XCTFail("expected alert") }
        // 全绿 + 一家 stale(12 分钟) → .stale(12)
        XCTAssertEqual(MenuBarQuotaModel.sentinelState(cells: [greenCell, staleCell12m]), .stale(minutes: 12))
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter MenuBarQuotaModelTests 2>&1 | tail -10`
Expected: 编译失败（新 API 未定义）。

- [ ] **Step 3: 重写 `MenuBarQuotaModel.swift`**（完整实现）

```swift
import Foundation
import TokenMeterCore

/// 菜单栏组件的数据投影：settings + snapshots + todaySummary → 渲染模型。
/// 纯函数、无 UI 依赖，16 种样式共用同一份 Cell；样式渲染差异全在
/// MenuBarStyleViews。规则权威：docs/superpowers/specs/2026-07-17-…-design.md §2-3。
enum MenuBarQuotaModel {
    struct Window: Equatable {
        let label: String
        /// 剩余百分比（越大越充裕，与弹窗环同语义）。
        let remainingPercent: Double
        let tone: UsageMetricTone
        var roundedPercent: Int { Int(remainingPercent.rounded()) }
    }

    struct Cell: Equatable {
        let providerId: String
        /// 品牌短名（displayName 首词）。
        let badge: String
        /// 单字符标（monogram/tagnum 用，全组去重后注入）。
        let mono: String
        /// 短窗（5h 类）；单窗家为 nil——唯一窗恒放 longWindow（沿现状「last=最长窗」口径）。
        let shortWindow: Window?
        let longWindow: Window
        /// 快照超时分钟数（QuotaDisplayModel 口径：≥10 分钟才非 nil）。
        let staleMinutes: Int?
        let glyphChoice: MenuBarWindowChoice
        let numberChoice: MenuBarWindowChoice

        var isStale: Bool { staleMinutes != nil }
        var isSingleWindow: Bool { shortWindow == nil }

        /// 窗口展开：单窗家无视 choice 恒取唯一窗；both 顺序由 windowOrder 决定。
        func windows(for choice: MenuBarWindowChoice, order: MenuBarWindowOrder) -> [Window] {
            guard let shortWindow else { return [longWindow] }
            switch choice {
            case .short: return [shortWindow]
            case .long: return [longWindow]
            case .both: return order == .shortFirst ? [shortWindow, longWindow] : [longWindow, shortWindow]
            }
        }

        func glyphWindows(order: MenuBarWindowOrder) -> [Window] { windows(for: glyphChoice, order: order) }
        func numberWindows(order: MenuBarWindowOrder) -> [Window] { windows(for: numberChoice, order: order) }
        var worstNumberWindow: Window { MenuBarQuotaModel.worst(of: windows(for: numberChoice, order: .longFirst)) }
        var worstGlyphWindow: Window { MenuBarQuotaModel.worst(of: windows(for: glyphChoice, order: .longFirst)) }
    }

    static func worst(of windows: [Window]) -> Window {
        windows.min { $0.remainingPercent < $1.remainingPercent } ?? Window(label: "", remainingPercent: 0, tone: .muted)
    }

    /// 哨兵样式的组件级状态（spec §3：红>黄>灰过期>安静）。
    enum SentinelState: Equatable {
        case quiet
        case alert(cell: Cell, window: Window)
        case stale(minutes: Int)
    }

    static func sentinelState(cells: [Cell]) -> SentinelState {
        let fresh = cells.filter { !$0.isStale }
        let alerts = fresh
            .map { (cell: $0, window: $0.worstNumberWindow) }
            .filter { $0.window.tone == .bad || $0.window.tone == .warning }
        if let hit = alerts.min(by: { lhs, rhs in
            let lb = lhs.window.tone == .bad, rb = rhs.window.tone == .bad
            if lb != rb { return lb }
            return lhs.window.remainingPercent < rhs.window.remainingPercent
        }) {
            return .alert(cell: hit.cell, window: hit.window)
        }
        if let minutes = cells.compactMap(\.staleMinutes).max() {
            return .stale(minutes: minutes)
        }
        return .quiet
    }

    /// 聚合样式的组件级最险数字（跳过 stale 家；数字窗口口径）。
    static func aggregateWorstNumber(cells: [Cell]) -> (cell: Cell, window: Window)? {
        cells.filter { !$0.isStale }
            .map { (cell: $0, window: $0.worstNumberWindow) }
            .min { $0.window.remainingPercent < $1.window.remainingPercent }
    }

    /// 元素开关的样式归一化（spec §3 锁定表 + 至少保一兜底）。
    static func effectiveElements(
        style: MenuBarStyleId, showName: Bool, showGlyph: Bool, showNumber: Bool
    ) -> (name: Bool, glyph: Bool, number: Bool) {
        var name = showName, glyph = showGlyph, number = showNumber
        switch style {
        case .digits: glyph = false
        case .monogram: name = true; glyph = false
        case .tagnum, .deck2: glyph = false; number = true
        case .ringdeck, .barsdeck: glyph = true; number = true
        case .grid, .strip, .sentinel: glyph = true
        default: break
        }
        if !name && !glyph && !number {
            if style == .digits { number = true } else { glyph = true }
        }
        return (name, glyph, number)
    }

    /// 文字样式的超宽降级（spec §2）：CJK 短名 + 双窗数字 + 名称开启 → 数字降最险单窗。
    static func numbersDegradeToWorst(style: MenuBarStyleId, cell: Cell, showName: Bool) -> Bool {
        guard style == .digits, showName, !cell.isSingleWindow, cell.numberChoice == .both else { return false }
        return cell.badge.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
    }

    /// 单字符标去重：依序取短名第一个未被占用的字符，全占用回落首字符。
    /// [CC, CX, 智谱, OMP] → [C, X, 智, O]（与设计稿 MONO_CH 一致）。
    static func monograms(for badges: [String]) -> [String] {
        var used = Set<String>()
        return badges.map { badge in
            let chars = badge.map(String.init)
            let pick = chars.first { !used.contains($0) } ?? chars.first ?? "?"
            used.insert(pick)
            return pick
        }
    }

    struct MenuBarProjection: Equatable {
        enum Tail: Equatable {
            case hidden
            case text(String)
        }

        let style: MenuBarStyleId
        let showName: Bool
        let showGlyph: Bool
        let showNumber: Bool
        let windowOrder: MenuBarWindowOrder
        let cells: [Cell]
        let tail: Tail
    }

    static func projection(
        snapshots: [ProviderUsageSnapshot],
        settings: SettingsSnapshot?,
        todaySummary: MenuBarTodaySummary,
        now: Date = Date()
    ) -> MenuBarProjection {
        let appearance = settings?.menuBarAppearance ?? .default
        let overrides = settings?.providerOverrides ?? []
        func override(_ id: String) -> ProviderConfigOverride? {
            overrides.first { $0.providerId == id }
        }

        var cells: [Cell] = snapshots.compactMap { snapshot in
            let o = override(snapshot.providerId)
            guard o?.showInMenuBar ?? true else { return nil }
            let model = QuotaDisplayModel(snapshot: snapshot, now: now)
            let windows = model.rings.map {
                Window(label: $0.label, remainingPercent: $0.percent, tone: $0.tone)
            }
            guard let longWindow = windows.last else { return nil }
            let shortName = snapshot.displayName.split(separator: " ").first.map(String.init)
                ?? snapshot.displayName
            return Cell(
                providerId: snapshot.providerId,
                badge: shortName,
                mono: "",
                shortWindow: windows.count > 1 ? windows.first : nil,
                longWindow: longWindow,
                staleMinutes: model.staleMinutes,
                glyphChoice: o?.menuBarGlyphWindow ?? .both,
                numberChoice: o?.menuBarNumberWindow ?? .both
            )
        }
        let monos = monograms(for: cells.map(\.badge))
        cells = zip(cells, monos).map { cell, mono in
            Cell(
                providerId: cell.providerId, badge: cell.badge, mono: mono,
                shortWindow: cell.shortWindow, longWindow: cell.longWindow,
                staleMinutes: cell.staleMinutes,
                glyphChoice: cell.glyphChoice, numberChoice: cell.numberChoice
            )
        }

        let elements = effectiveElements(
            style: appearance.style,
            showName: appearance.showName,
            showGlyph: appearance.showGlyph,
            showNumber: appearance.showNumber
        )

        let tail: MenuBarProjection.Tail
        switch appearance.usage {
        case .off: tail = .hidden
        case .tok:
            tail = todaySummary.tokens > 0
                ? .text(UsageFormatter.compactTokens(todaySummary.tokens))
                : .hidden
        case .cost:
            tail = todaySummary.costUsdMicros > 0
                ? .text(MenuBarNumberFormat.usd(todaySummary.costUsdMicros))
                : .hidden
        }

        return MenuBarProjection(
            style: appearance.style,
            showName: elements.name,
            showGlyph: elements.glyph,
            showNumber: elements.number,
            windowOrder: appearance.windowOrder,
            cells: cells,
            tail: tail
        )
    }
}
```

注意：`MenuBarNumberFormat.usd` 定义在 `PopoverView.swift`（App target 内可直接引用）；若签名不符（先 grep `enum MenuBarNumberFormat` 确认），以真实签名为准调整调用。

- [ ] **Step 4: 修复既有调用点**

`StatusBarController.swift` 的 `MenuBarQuotaModel.cells(from:)` 调用会编译失败——本任务先最小替换保编译（Task 4 再全面接线）：`bindStore` 里暂时改为

```swift
self.quotaCells = []
_ = MenuBarQuotaModel.projection(
    snapshots: self.store.displayProviderSnapshots,
    settings: self.store.settingsSnapshot,
    todaySummary: self.store.todaySummary
)
```

同时 `StatusBarContentView`/`MenuBarQuotaCellView` 里对 `Cell.windows` 的引用改为 `cell.glyphWindows(order: .longFirst)` 等价形式（保持现状视觉），`MenuBarBrandMark` 不动。既有 `MenuBarQuotaModelTests` 旧用例按新 API 改写（`cells(from:)` → `projection(...).cells`，`windows` 数组断言 → `shortWindow`/`longWindow` 断言）。

- [ ] **Step 5: 跑测试确认通过 + commit**

Run: `swift test --filter MenuBarQuotaModelTests 2>&1 | tail -5` → PASS；`swift test 2>&1 | tail -5` → 全绿。

```bash
git add Sources/TokenMeterApp/MenuBarQuotaModel.swift Sources/TokenMeterApp/StatusBarController.swift Tests/TokenMeterAppTests/MenuBarQuotaModelTests.swift
git commit -m "feat: menubar projection model with per-provider windows, sentinel, monogram"
```

---

### Task 4: Swift 基础样式视图（S0-S7）+ 分发与接线

**Files:**
- Create: `Sources/TokenMeterApp/MenuBarStyleViews.swift`
- Modify: `Sources/TokenMeterApp/StatusBarController.swift`（`MenuBarQuotaCellView`/`StatusBarContentView`/`bindStore` 段）
- Test: `Tests/TokenMeterAppTests/StatusBarControllerTests.swift`（扩展）

- [ ] **Step 1: 写失败测试**（追加到 `StatusBarControllerTests.swift`，先读现有测试确认 store 注入方式，沿用其构造模式）

```swift
    /// 投影驱动内容：settingsSnapshot 样式变化 → hosting rootView 跟随（间接以宽度层字符串与 cells 数验证）。
    func testProjectionTailFeedsTitleMirror() async throws {
        // 构造 store：todaySummary tokens=3_400_000 → tail 文本 "3.4M"
        // usage=cost 时 → "$..."；断言 controller.titleForTesting 同步为尾巴文本
    }

    func testHiddenProvidersDropFromStatusContent() async throws {
        // settingsSnapshot providerOverrides: codex showInMenuBar=false
        // 断言 projectionForTesting.cells 不含 codex
    }
```

（`StatusBarController` 暴露 `var projectionForTesting: MenuBarProjection` 只读镜像，模式与 `titleForTesting` 一致。测试体按现有 store 注入 helper 写完整——如 store 不易伪造 settingsSnapshot，用 `ProviderStore(config:notificationCenter:databaseURL:)` 内存库 + `reloadSettings` 写库路径构造。）

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter StatusBarControllerTests 2>&1 | tail -10`
Expected: 编译失败（`projectionForTesting` 不存在）。

- [ ] **Step 3: 实现 `MenuBarStyleViews.swift`**（S0-S7 完整代码 + 共享小件）

```swift
import SwiftUI
import TokenMeterCore

/// 16 样式共享的小件与 S0-S7 基础族视图。聚合/数字支/混合系见文件下半部（Task 5）。
/// 规则权威：spec §2-3。cell 内只用系统语义色（品牌色禁入菜单栏）。

enum MenuBarToneColor {
    static func color(_ tone: UsageMetricTone) -> Color {
        switch tone {
        case .ok: return Color(nsColor: .systemGreen)
        case .warning: return Color(nsColor: .systemYellow)
        case .bad: return Color(nsColor: .systemRed)
        case .muted: return Color(nsColor: .tertiaryLabelColor)
        }
    }

    /// stale 整 cell 灰：图形/数字染色前先过这层。
    static func display(_ tone: UsageMetricTone, stale: Bool) -> Color {
        color(stale ? .muted : tone)
    }
}

/// 品牌短名（11pt semibold，primary）。
struct CellNameText: View {
    let badge: String
    var body: some View {
        Text(badge)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.primary)
            .fixedSize()
    }
}

/// 数字组：双数字各自跟随所属窗口 tone（用户裁定的 S0 打磨，推广到全族）；
/// stale 显示 "—"。分隔点弱化、基线对齐（异色数字 center 对齐有高低错觉）。
struct CellNumbersView: View {
    let windows: [MenuBarQuotaModel.Window]
    let isStale: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if isStale {
            Text("—")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.tertiary)
                .fixedSize()
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                ForEach(Array(windows.enumerated()), id: \.offset) { index, window in
                    if index > 0 {
                        Text("·")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 1.5)
                    }
                    Text("\(window.roundedPercent)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(MenuBarToneColor.color(window.tone))
                        .fixedSize()
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: window.roundedPercent)
                }
            }
        }
    }
}

/// S0 同心双环（现状实现迁入：butt 端点、底环 0.28、overlay 同心）。
struct RingsGlyphView: View {
    let windows: [MenuBarQuotaModel.Window]   // 已按 windowOrder；[0]=外环
    let isStale: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func ring(_ window: MenuBarQuotaModel.Window, diameter: CGFloat) -> some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.28), lineWidth: 2)
            Circle()
                .trim(from: 0, to: window.remainingPercent / 100)
                .stroke(
                    MenuBarToneColor.display(window.tone, stale: isStale),
                    style: StrokeStyle(lineWidth: 2, lineCap: .butt)
                )
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .smooth(duration: 0.5), value: window.remainingPercent)
        }
        .frame(width: diameter, height: diameter)
    }

    var body: some View {
        if let outer = windows.first {
            ring(outer, diameter: 15)
                .overlay {
                    if windows.count > 1 { ring(windows[1], diameter: 8) }
                }
                .frame(width: 17, height: 17)
                .opacity(isStale ? 0.7 : 1)
        }
    }
}

/// S1 双竖条：3×13pt 底向上填充。
struct VBarsGlyphView: View {
    let windows: [MenuBarQuotaModel.Window]
    let isStale: Bool
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.14))
                    RoundedRectangle(cornerRadius: 1)
                        .fill(MenuBarToneColor.display(window.tone, stale: isStale))
                        .frame(height: max(1, 13 * window.remainingPercent / 100))
                        .opacity(isStale ? 0.5 : 1)
                }
                .frame(width: 3, height: 13)
            }
        }
    }
}

/// S2 迷你横条：22×3pt 上下叠，单窗加粗 4pt。
struct HBarGlyphView: View {
    let windows: [MenuBarQuotaModel.Window]
    let isStale: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.primary.opacity(0.14))
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(MenuBarToneColor.display(window.tone, stale: isStale))
                        .frame(width: max(1, 22 * window.remainingPercent / 100))
                        .opacity(isStale ? 0.5 : 1)
                }
                .frame(width: 22, height: windows.count == 1 ? 4 : 3)
            }
        }
    }
}

/// S4 状态点：6pt 圆点每窗一点。
struct DotsGlyphView: View {
    let windows: [MenuBarQuotaModel.Window]
    let isStale: Bool
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                Circle()
                    .fill(MenuBarToneColor.display(window.tone, stale: isStale))
                    .frame(width: 6, height: 6)
            }
        }
    }
}

/// S5 胶囊电池：14×8pt 内缩 1pt 填充。
struct CapsGlyphView: View {
    let windows: [MenuBarQuotaModel.Window]
    let isStale: Bool
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(MenuBarToneColor.display(window.tone, stale: isStale))
                        .frame(width: max(1, 12 * window.remainingPercent / 100))
                        .padding(1)
                        .opacity(isStale ? 0.5 : 1)
                }
                .frame(width: 14, height: 8)
            }
        }
    }
}

/// S6 分段刻度：5 格 2.5×10pt，亮格 = round(p/20) 至少 1。
struct TicksGlyphView: View {
    let windows: [MenuBarQuotaModel.Window]
    let isStale: Bool
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                let lit = max(1, Int((window.remainingPercent / 20).rounded()))
                HStack(spacing: 1.5) {
                    ForEach(0..<5, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(index < lit
                                ? MenuBarToneColor.display(window.tone, stale: isStale)
                                : Color.primary.opacity(0.14))
                            .frame(width: 2.5, height: 10)
                    }
                }
            }
        }
    }
}

/// S7 单环：15pt 只画一个窗口（both → windowOrder 首位）。
struct Ring1GlyphView: View {
    let window: MenuBarQuotaModel.Window
    let isStale: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.16), lineWidth: 2)
            Circle()
                .trim(from: 0, to: window.remainingPercent / 100)
                .stroke(
                    MenuBarToneColor.display(window.tone, stale: isStale),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .smooth(duration: 0.5), value: window.remainingPercent)
        }
        .frame(width: 15, height: 15)
    }
}

/// 基础族（S0-S7）单家 cell：[name][glyph][pct] 语法 + 元素开关 + ticks 双组静音数字。
struct BasicStyleCellView: View {
    let cell: MenuBarQuotaModel.Cell
    let projection: MenuBarQuotaModel.MenuBarProjection

    private var glyphWindows: [MenuBarQuotaModel.Window] { cell.glyphWindows(order: projection.windowOrder) }
    private var numberWindows: [MenuBarQuotaModel.Window] {
        if MenuBarQuotaModel.numbersDegradeToWorst(style: projection.style, cell: cell, showName: projection.showName) {
            return [cell.worstNumberWindow]
        }
        // 单数字样式（hbar/caps/dots/ticks/ring1）报最险窗；vbars/digits/rings 双窗全显。
        switch projection.style {
        case .rings, .vbars, .digits:
            return cell.numberWindows(order: projection.windowOrder)
        default:
            return [cell.worstNumberWindow]
        }
    }
    /// ticks 双组刻度时数字自动隐藏（稿定规则）。
    private var numberSuppressed: Bool {
        projection.style == .ticks && glyphWindows.count > 1
    }

    var body: some View {
        HStack(spacing: 4) {
            if projection.showName { CellNameText(badge: cell.badge) }
            if projection.showGlyph {
                switch projection.style {
                case .rings: RingsGlyphView(windows: glyphWindows, isStale: cell.isStale)
                case .vbars: VBarsGlyphView(windows: glyphWindows, isStale: cell.isStale)
                case .hbar: HBarGlyphView(windows: glyphWindows, isStale: cell.isStale)
                case .dots: DotsGlyphView(windows: glyphWindows, isStale: cell.isStale)
                case .caps: CapsGlyphView(windows: glyphWindows, isStale: cell.isStale)
                case .ticks: TicksGlyphView(windows: glyphWindows, isStale: cell.isStale)
                case .ring1: Ring1GlyphView(window: glyphWindows[0], isStale: cell.isStale)
                default: EmptyView()
                }
            }
            if projection.showNumber && !numberSuppressed {
                CellNumbersView(windows: numberWindows, isStale: cell.isStale)
            }
        }
        .fixedSize()
    }
}
```

- [ ] **Step 4: 接线 `StatusBarController.swift`**

1. 删除 `MenuBarQuotaCellView`（S0 逻辑已迁入 `RingsGlyphView`/`BasicStyleCellView`；`MenuBarBrandMark` 保留并加 `var size: CGFloat = 16` 参数供 13pt 复用）。
2. `StatusBarContentView` 改为：

```swift
struct StatusBarContentView: View {
    let projection: MenuBarQuotaModel.MenuBarProjection
    let title: String   // 尾巴文本镜像（a11y/宽度层同步用）

    private var tailText: String? {
        if case let .text(text) = projection.tail { return text }
        return nil
    }

    var body: some View {
        HStack(spacing: 9) {
            MenuBarStyleRouterView(projection: projection)
            if let tailText {
                StatusBarTitleView(title: tailText)
                    .opacity(0.75)
            } else if projection.cells.isEmpty {
                MenuBarBrandMark()
            }
        }
    }
}

/// 按样式分发：基础族逐家 cell；聚合/数字支/混合系见 Task 5（本任务先路由基础族，
/// 其余样式暂回落基础族 rings 渲染，Task 5 完成后替换为真实现）。
struct MenuBarStyleRouterView: View {
    let projection: MenuBarQuotaModel.MenuBarProjection

    var body: some View {
        switch projection.style {
        case .rings, .vbars, .hbar, .digits, .dots, .caps, .ticks, .ring1:
            HStack(spacing: 9) {
                ForEach(projection.cells, id: \.providerId) { cell in
                    BasicStyleCellView(cell: cell, projection: projection)
                }
            }
        default:
            HStack(spacing: 9) {
                ForEach(projection.cells, id: \.providerId) { cell in
                    BasicStyleCellView(cell: cell, projection: projection)
                }
            }
        }
    }
}
```

3. Controller 状态改 `private var projection = MenuBarQuotaModel.MenuBarProjection(style: .rings, showName: true, showGlyph: true, showNumber: true, windowOrder: .longFirst, cells: [], tail: .hidden)` + `var projectionForTesting: MenuBarQuotaModel.MenuBarProjection { projection }`；删除 `quotaCells`。
4. `bindStore` 三源合并（替换现有两条订阅）：

```swift
        store.$providerSnapshots
            .combineLatest(store.$settingsSnapshot, store.$todaySummary)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
                guard let self else { return }
                self.projection = MenuBarQuotaModel.projection(
                    snapshots: self.store.displayProviderSnapshots,
                    settings: self.store.settingsSnapshot,
                    todaySummary: self.store.todaySummary
                )
                if case let .text(text) = self.projection.tail {
                    self.updateTitle(text)
                } else {
                    self.updateTitle("")
                }
            }
            .store(in: &cancellables)
```

`applyStatusContent` 的 rootView 改 `StatusBarContentView(cells:title:)` → `StatusBarContentView(projection: projection, title: currentTitle)`；`installTitleHosting` 初始 rootView 同步改空投影。既有「空 title 显示品牌标」语义由 `projection.cells.isEmpty && tail == .hidden` 承接（`estimatedCollapsedContentHeight` 等弹窗逻辑不动）。

- [ ] **Step 5: 跑测试 + commit**

Run: `swift test 2>&1 | tail -5` → 全绿（StatusBarControllerTests 新旧用例都过；旧的 title 相关用例若断言「今日 token 标题」行为，改断言 tail 镜像等价行为）。

```bash
git add Sources/TokenMeterApp/MenuBarStyleViews.swift Sources/TokenMeterApp/StatusBarController.swift Tests/TokenMeterAppTests/StatusBarControllerTests.swift
git commit -m "feat: basic menubar style family (S0-S7) with projection-driven status content"
```

---

### Task 5: Swift 聚合 / 数字支 / 混合系视图（S8-S15）

**Files:**
- Modify: `Sources/TokenMeterApp/MenuBarStyleViews.swift`（文件下半部追加）
- Modify: `Sources/TokenMeterApp/StatusBarController.swift`（Router 的 default 分支替换）
- Test: `Tests/TokenMeterAppTests/MenuBarQuotaModelTests.swift`（聚合语义已在 Task 3 覆盖；本任务补 Router 分发断言到 StatusBarControllerTests 不必要——视图纯声明，以构建 + 全量测试为准）

- [ ] **Step 1: 追加视图实现**（完整代码）

```swift
// MARK: - 聚合紧凑族（S8-S11）与数字支（S12-S13）、混合系（S14-S15）

/// 13pt 品牌 logo（sentinel / grid / strip 的名称前缀位）。
private struct MiniBrandLogo: View {
    var tint: Color = .primary
    var body: some View {
        MenuBarBrandMark(size: 13)
            .foregroundStyle(tint)
            .opacity(0.85)
    }
}

/// S8 点阵网格：全家一个点阵（4 家 2×2，≤3 家单行），点色 = 家级最险（图形窗口口径）。
struct GridAggregateView: View {
    let projection: MenuBarQuotaModel.MenuBarProjection
    private var columns: [GridItem] {
        let count = projection.cells.count == 4 ? 2 : max(1, min(projection.cells.count, 3))
        return Array(repeating: GridItem(.fixed(5.5), spacing: 2), count: count)
    }
    var body: some View {
        HStack(spacing: 4) {
            if projection.showName { MiniBrandLogo() }
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(projection.cells, id: \.providerId) { cell in
                    Circle()
                        .fill(MenuBarToneColor.display(cell.worstGlyphWindow.tone, stale: cell.isStale))
                        .frame(width: 5.5, height: 5.5)
                }
            }
            .fixedSize()
            if projection.showNumber, let worst = MenuBarQuotaModel.aggregateWorstNumber(cells: projection.cells) {
                CellNumbersView(windows: [worst.window], isStale: false)
            }
        }
        .fixedSize()
    }
}

/// S11 堆叠条：每家一段 6×13pt、1pt 缝，段色 = 家级最险（图形窗口口径）。
struct StripAggregateView: View {
    let projection: MenuBarQuotaModel.MenuBarProjection
    var body: some View {
        HStack(spacing: 4) {
            if projection.showName { MiniBrandLogo() }
            HStack(spacing: 1) {
                ForEach(projection.cells, id: \.providerId) { cell in
                    Rectangle()
                        .fill(MenuBarToneColor.display(cell.worstGlyphWindow.tone, stale: cell.isStale))
                        .frame(width: 6, height: 13)
                        .opacity(cell.isStale ? 0.55 : 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            if projection.showNumber, let worst = MenuBarQuotaModel.aggregateWorstNumber(cells: projection.cells) {
                CellNumbersView(windows: [worst.window], isStale: false)
            }
        }
        .fixedSize()
    }
}

/// S10 字母色徽：单字符警戒色染字，stale 加删除线（色彩之外的第二编码）。
struct MonogramAggregateView: View {
    let projection: MenuBarQuotaModel.MenuBarProjection
    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(projection.cells, id: \.providerId) { cell in
                    Text(cell.mono)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(MenuBarToneColor.display(cell.worstNumberWindow.tone, stale: cell.isStale))
                        .strikethrough(cell.isStale, color: MenuBarToneColor.color(.muted))
                        .fixedSize()
                }
            }
            if projection.showNumber, let worst = MenuBarQuotaModel.aggregateWorstNumber(cells: projection.cells) {
                CellNumbersView(windows: [worst.window], isStale: false)
            }
        }
        .fixedSize()
    }
}

/// S9 哨兵：quiet=单色 logo；alert=最险家（logo 染色 + 短名 + 数字，各随元素开关）；
/// stale=灰 logo + 未更新分钟数。
struct SentinelView: View {
    let projection: MenuBarQuotaModel.MenuBarProjection
    var body: some View {
        switch MenuBarQuotaModel.sentinelState(cells: projection.cells) {
        case .quiet:
            MiniBrandLogo()
        case let .alert(cell, window):
            let tint = MenuBarToneColor.color(window.tone)
            HStack(spacing: 4) {
                if projection.showGlyph { MiniBrandLogo(tint: tint) }
                if projection.showName {
                    Text(cell.badge)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                        .fixedSize()
                }
                if projection.showNumber { CellNumbersView(windows: [window], isStale: false) }
            }
            .fixedSize()
        case let .stale(minutes):
            HStack(spacing: 4) {
                MiniBrandLogo(tint: MenuBarToneColor.color(.muted))
                Text("\(minutes)m")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            .fixedSize()
        }
    }
}

/// deck2 的单家 unit：上行小字名 / 下行数字（数字支与混合系共用）。
struct DeckUnitView: View {
    let cell: MenuBarQuotaModel.Cell
    let projection: MenuBarQuotaModel.MenuBarProjection
    /// tagnum 用单字符、deck2/混合系用短名。
    let nameText: String?

    var body: some View {
        VStack(spacing: 1) {
            if let nameText {
                Text(nameText)
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.55))
                    .fixedSize()
            }
            CellNumbersView(windows: cell.numberWindows(order: projection.windowOrder), isStale: cell.isStale)
        }
        .fixedSize()
    }
}

/// S12 字标数字：单字符 10pt 半透明前标 + 数字（baseline 排布）。
struct TagnumAggregateView: View {
    let projection: MenuBarQuotaModel.MenuBarProjection
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            ForEach(projection.cells, id: \.providerId) { cell in
                HStack(alignment: .firstTextBaseline, spacing: 1.5) {
                    if projection.showName {
                        Text(cell.mono)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.primary.opacity(0.55))
                            .fixedSize()
                    }
                    CellNumbersView(windows: cell.numberWindows(order: projection.windowOrder), isStale: cell.isStale)
                }
            }
        }
        .fixedSize()
    }
}

/// S13 双层堆叠：每家一个 DeckUnit（上名下数）。
struct Deck2AggregateView: View {
    let projection: MenuBarQuotaModel.MenuBarProjection
    var body: some View {
        HStack(spacing: 8) {
            ForEach(projection.cells, id: \.providerId) { cell in
                DeckUnitView(cell: cell, projection: projection, nameText: projection.showName ? cell.badge : nil)
            }
        }
        .fixedSize()
    }
}

/// S14/S15 混合系单家 cell：图形（环/竖条，取图形窗口）+ DeckUnit（取数字窗口）。
struct HybridCellView: View {
    let cell: MenuBarQuotaModel.Cell
    let projection: MenuBarQuotaModel.MenuBarProjection

    var body: some View {
        let glyphWindows = cell.glyphWindows(order: projection.windowOrder)
        HStack(spacing: 3) {
            if projection.style == .ringdeck {
                if glyphWindows.count > 1 {
                    RingsGlyphView(windows: glyphWindows, isStale: cell.isStale)
                } else {
                    Ring1GlyphView(window: glyphWindows[0], isStale: cell.isStale)
                }
            } else {
                VBarsGlyphView(windows: glyphWindows, isStale: cell.isStale)
            }
            DeckUnitView(cell: cell, projection: projection, nameText: projection.showName ? cell.badge : nil)
        }
        .fixedSize()
    }
}
```

`MenuBarBrandMark` 参数化（StatusBarController.swift 内）：`struct MenuBarBrandMark: View { var size: CGFloat = 16 ... }`，内部 15/13.5/12.5 尺寸按 `size/16` 等比缩放（`.scaleEffect(size / 16)` 包裹现有 ZStack 后 `.frame(width: size, height: size)`）。

- [ ] **Step 2: Router 替换 default 分支**

```swift
        case .grid: GridAggregateView(projection: projection)
        case .strip: StripAggregateView(projection: projection)
        case .monogram: MonogramAggregateView(projection: projection)
        case .sentinel: SentinelView(projection: projection)
        case .tagnum: TagnumAggregateView(projection: projection)
        case .deck2: Deck2AggregateView(projection: projection)
        case .ringdeck, .barsdeck:
            HStack(spacing: 9) {
                ForEach(projection.cells, id: \.providerId) { cell in
                    HybridCellView(cell: cell, projection: projection)
                }
            }
```

（原 `case .rings, ...` 基础族分支保留，`default` 删除——switch 全枚举。）

- [ ] **Step 3: 构建与全量测试**

Run: `swift build 2>&1 | tail -3` → Build complete；`swift test 2>&1 | tail -5` → 全绿。

- [ ] **Step 4: Commit**

```bash
git add Sources/TokenMeterApp/MenuBarStyleViews.swift Sources/TokenMeterApp/StatusBarController.swift
git commit -m "feat: aggregate/digit/hybrid menubar styles (S8-S15)"
```

---

### Task 6: Electron 预览渲染器（演示口径，16 样式）

**Files:**
- Create: `Electron/src/renderer/components/MenubarPreview.tsx`
- Modify: `Electron/src/renderer/styles.css`（文件末尾追加 `.mb*` 段）
- Test: `Electron/src/renderer/components/MenubarPreview.test.tsx`

- [ ] **Step 1: 写失败测试**

```tsx
import { render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';

import { MenubarPreviewBar, PREVIEW_PROVIDERS, type MenubarPreviewState } from './MenubarPreview.js';

const base: MenubarPreviewState = {
  style: 'rings',
  showName: true,
  showGlyph: true,
  showNumber: true,
  usage: 'tok',
  windowOrder: 'longFirst',
  providers: PREVIEW_PROVIDERS.map((p) => ({ id: p.id, visible: p.id !== 'omp', glyphWindow: 'both', numberWindow: 'both' }))
};

describe('MenubarPreviewBar', () => {
  it('renders one cell per visible provider plus tail for rings', () => {
    const { container } = render(<MenubarPreviewBar mode="dark" state={base} />);
    expect(container.querySelectorAll('.mbcell').length).toBe(4); // 3 家 + 今日尾巴
    expect(container.querySelectorAll('svg').length).toBeGreaterThan(0); // 双环 svg
    expect(screen.getByText('214.8M')).toBeInTheDocument();
  });

  it('digits style renders no glyph and honors longFirst order', () => {
    const { container } = render(
      <MenubarPreviewBar mode="dark" state={{ ...base, style: 'digits' }} />
    );
    expect(container.querySelector('.mb-vbars, .mb-dots, .mb-caps')).toBeNull();
    // CC 5h=62 7d=41 → longFirst 显示 41·62
    expect(container.textContent).toContain('41');
  });

  it('sentinel quiet state collapses to logo only when all healthy', () => {
    const healthy = {
      ...base,
      style: 'sentinel' as const,
      providers: base.providers.map((p) => ({ ...p, id: p.id === 'zhipu' ? 'claude' : p.id }))
        .filter((p) => p.id === 'claude' || p.id === 'codex')
    };
    // 稿演示数据里 claude/codex 无 bad；智谱 5h=8 是唯一红。排除智谱 → quiet
    const { container } = render(<MenubarPreviewBar mode="dark" state={healthy} />);
    expect(container.querySelectorAll('.mb-logo').length).toBe(1);
  });

  it('cost tail and hidden-all placeholder', () => {
    const { container } = render(
      <MenubarPreviewBar mode="light" state={{ ...base, usage: 'cost', providers: base.providers.map((p) => ({ ...p, visible: false })) }} />
    );
    expect(container.textContent).toContain('$196.44');
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd Electron && npx vitest run src/renderer/components/MenubarPreview.test.tsx 2>&1 | tail -5`
Expected: FAIL（模块不存在）。

- [ ] **Step 3: 实现 `MenubarPreview.tsx`**（设计稿 app.html JS 行 2915-3052 的 React 翻译；演示口径数据与稿同源）

```tsx
/// 菜单栏预览渲染器：演示口径数据（与 OpenDesign 稿同源），不接真实快照。
/// 规则权威 = spec §2-3；Swift MenuBarStyleViews 是真渲染，这里只需视觉近似一致。
/// cell 内只用系统语义色（.mbar.mbdark/.mblight 的 g-* 类），品牌青禁入。

export type PreviewWindowChoice = 'short' | 'long' | 'both';

export interface MenubarPreviewState {
  style: string;
  showName: boolean;
  showGlyph: boolean;
  showNumber: boolean;
  usage: 'off' | 'tok' | 'cost';
  windowOrder: 'longFirst' | 'shortFirst';
  providers: Array<{ id: string; visible: boolean; glyphWindow: PreviewWindowChoice; numberWindow: PreviewWindowChoice }>;
}

interface DemoWindow { p: number; c: 'ok' | 'warn' | 'bad' }
interface DemoProvider { id: string; short: string; mono: string; w5: DemoWindow; w7: DemoWindow | null; stale: boolean }

/// 演示数据（稿 data 口径）：CC 5h62/7d41 · CX 34/18 · 智谱 8/55 · OMP 过期 12m。
export const PREVIEW_PROVIDERS: DemoProvider[] = [
  { id: 'claude', short: 'CC', mono: 'C', w5: { p: 62, c: 'ok' }, w7: { p: 41, c: 'ok' }, stale: false },
  { id: 'codex', short: 'CX', mono: 'X', w5: { p: 34, c: 'warn' }, w7: { p: 18, c: 'warn' }, stale: false },
  { id: 'zhipu', short: '智谱', mono: '智', w5: { p: 8, c: 'bad' }, w7: { p: 55, c: 'ok' }, stale: false },
  { id: 'omp', short: 'OMP', mono: 'O', w5: { p: 71, c: 'ok' }, w7: { p: 30, c: 'ok' }, stale: true }
];

const COMPACT = new Set(['grid', 'sentinel', 'monogram', 'strip', 'tagnum', 'deck2']);

function pick(d: DemoProvider, w: PreviewWindowChoice, order: 'longFirst' | 'shortFirst'): DemoWindow[] {
  if (d.w7 === null) return [d.w5];
  if (w === 'short') return [d.w5];
  if (w === 'long') return [d.w7];
  return order === 'shortFirst' ? [d.w5, d.w7] : [d.w7, d.w5];
}

function worstOf(ws: DemoWindow[]): DemoWindow {
  return ws.reduce((a, b) => (b.p < a.p ? b : a));
}

function toneClass(d: DemoProvider, w: DemoWindow): string {
  return d.stale ? 'g-off' : `g-${w.c}`;
}
```

（组件主体：`MenubarPreviewBar({ mode, state })` 内部按 `state.style` 分发——每样式一个小渲染函数返回 JSX，规则逐条对照稿 JS：`ringsSvg(ws)` 用 `<svg width=17>` 双 `<circle>` dasharray 弧；`vbars/hbar/dots/caps/ticks` 用 div+span 结构复刻稿 CSS 类名；聚合族 `compactCell()` 复刻 grid 列数/strip 段/monogram 删除线/sentinel 三态/tagnum/deck2 结构；数字规则：`rings/vbars/digits` 双窗全显、其余最险单窗、ticks 双组静音、digits CJK 降级；尾巴 `usage`→`214.8M`/`$196.44`；全隐藏且尾巴 off → `全部隐藏` 占位。代码结构与 Swift `MenuBarStyleViews` 的分支一一对应，执行时以稿 JS（app.html 行 2941-3052）为誊抄源。）

`styles.css` 末尾追加设计稿 `.mbprev/.mbar/.mbcell/.mb-vbars/.mb-hbar/.mb-dots/.mb-caps/.mb-ticks/.mb-grid4/.mb-monogram/.mb-strip/.mb-logo/.mb-tagnum/.mb-deck2/.mbgal/.mbg/.mbcur/.mbentry/.mbgal-h/.mbkeep/.seg.mini` 全段（app.html 行 255-327 誊抄，色值原样）。

- [ ] **Step 4: 跑测试确认通过 + commit**

Run: `cd Electron && npx vitest run src/renderer/components/MenubarPreview.test.tsx 2>&1 | tail -5` → PASS。

```bash
git add Electron/src/renderer/components/MenubarPreview.tsx Electron/src/renderer/components/MenubarPreview.test.tsx Electron/src/renderer/styles.css
git commit -m "feat: menubar preview renderer (demo-calibre, 16 styles)"
```

---

### Task 7: 「菜单栏外观」下钻页 + 设置入口卡

**Files:**
- Create: `Electron/src/renderer/components/MenubarAppearance.tsx`
- Modify: `Electron/src/renderer/routes/Settings.tsx`
- Test: `Electron/src/renderer/components/MenubarAppearance.test.tsx`

- [ ] **Step 1: 写失败测试**

```tsx
import { fireEvent, render, screen } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import { MenubarAppearance } from './MenubarAppearance.js';
import { settingsStore } from '../stores/settingsStore.js';

// mock settingsStore.applyPatch 记录调用；useSettings 返回可控快照（沿用 setupRenderer 的 window.tokenMeter mock 模式）

describe('MenubarAppearance', () => {
  it('gallery click applies style patch with side effects', async () => {
    const spy = vi.spyOn(settingsStore, 'applyPatch').mockResolvedValue({ requestedVersion: 2, status: 'pending' });
    render(<MenubarAppearance onBack={() => {}} />);
    fireEvent.click(screen.getByRole('button', { name: '纯数字' }));
    expect(spy).toHaveBeenCalledWith(expect.objectContaining({ menubarStyle: 'digits', menubarShowGlyph: false }));
    fireEvent.click(screen.getByRole('button', { name: '双层堆叠' }));
    expect(spy).toHaveBeenCalledWith(expect.objectContaining({ menubarStyle: 'deck2', menubarShowNumber: true, menubarShowGlyph: false }));
  });

  it('locks element switches per style (digits disables glyph switch)', () => {
    // 快照 style=digits → 图形开关 disabled；tagnum → 图形+数字 disabled；monogram → 名称 disabled
  });

  it('disables the last remaining element switch', () => {
    // showName=false, showGlyph=false → 数字开关 disabled（至少保一）
  });

  it('provider row patches visibility and windows', () => {
    const spy = vi.spyOn(settingsStore, 'applyPatch').mockResolvedValue({ requestedVersion: 2, status: 'pending' });
    render(<MenubarAppearance onBack={() => {}} />);
    fireEvent.click(screen.getByRole('button', { name: /Codex 菜单栏显示/ }));
    expect(spy).toHaveBeenCalledWith(expect.objectContaining({ providerMenubarVisible: { codex: false } }));
    fireEvent.click(screen.getAllByRole('button', { name: '5h' })[0]);
    expect(spy).toHaveBeenCalledWith(expect.objectContaining({ providerGlyphWindow: expect.any(Object) }));
  });

  it('window order segment patches menubarWindowOrder', () => {
    const spy = vi.spyOn(settingsStore, 'applyPatch').mockResolvedValue({ requestedVersion: 2, status: 'pending' });
    render(<MenubarAppearance onBack={() => {}} />);
    fireEvent.click(screen.getByRole('button', { name: '5h 在前' }));
    expect(spy).toHaveBeenCalledWith(expect.objectContaining({ menubarWindowOrder: 'shortFirst' }));
  });
});
```

（锁定/至少保一两条测试写完整断言：`expect(screen.getByRole('button', { name: '图形' })).toBeDisabled()` 风格；快照注入方式沿 `settingsStore.load` mock 或直接操纵 store 内部——参照 `settingsStore.test.ts` 现有做法。）

- [ ] **Step 2: 跑测试确认失败**

Run: `cd Electron && npx vitest run src/renderer/components/MenubarAppearance.test.tsx 2>&1 | tail -5`
Expected: FAIL（模块不存在）。

- [ ] **Step 3: 实现 `MenubarAppearance.tsx`**

结构（对照设计稿 view-menubar-appearance，行 1370-1489）：

```tsx
/// 设置下钻页「菜单栏外观」：实时预览 / 样式画廊 / 元素 / 今日用量 / 按服务商配置。
/// 元素锁定与切换副作用规则 = spec §3 表（Swift MenuBarQuotaModel.effectiveElements 同表）。

const STYLE_GROUPS: Array<{ title: string; items: Array<{ id: MenubarStyleId; name: string }> }> = [
  { title: '基础 · 每家一个 cell', items: [
    { id: 'rings', name: '同心双环' }, { id: 'vbars', name: '双竖条' }, { id: 'hbar', name: '迷你横条' },
    { id: 'digits', name: '纯数字' }, { id: 'dots', name: '状态点' }, { id: 'caps', name: '胶囊电池' },
    { id: 'ticks', name: '分段刻度' }, { id: 'ring1', name: '单环' }
  ] },
  { title: '紧凑 · 图形支（聚合 / 按需）', items: [
    { id: 'grid', name: '点阵网格' }, { id: 'sentinel', name: '哨兵' },
    { id: 'monogram', name: '字母色徽' }, { id: 'strip', name: '堆叠条' }
  ] },
  { title: '紧凑 · 数字支（数字一个不少）', items: [
    { id: 'tagnum', name: '字标数字' }, { id: 'deck2', name: '双层堆叠' }
  ] },
  { title: '混合系 · 图形 + 数字', items: [
    { id: 'ringdeck', name: '环+堆叠' }, { id: 'barsdeck', name: '竖条+堆叠' }
  ] }
];

/// 样式切换副作用（稿 JS 画廊 click 规则）。
export function stylePatch(style: MenubarStyleId, current: { showName: boolean; showNumber: boolean }): SettingsPatch {
  const patch: SettingsPatch = { menubarStyle: style };
  if (style === 'digits') patch.menubarShowGlyph = false;
  else if (style === 'monogram') { patch.menubarShowName = true; patch.menubarShowGlyph = false; }
  else if (style === 'tagnum' || style === 'deck2') { patch.menubarShowNumber = true; patch.menubarShowGlyph = false; }
  else if (style === 'ringdeck' || style === 'barsdeck') { patch.menubarShowNumber = true; patch.menubarShowGlyph = true; }
  else if (style === 'grid' || style === 'strip' || style === 'sentinel') patch.menubarShowGlyph = true;
  else if (!current.showName && !current.showNumber) patch.menubarShowGlyph = true;
  return patch;
}

/// 元素锁定表（spec §3）：locked=true 的开关禁用且状态由样式钉死。
export function elementLocks(style: MenubarStyleId): { name?: boolean; glyph?: boolean; pct?: boolean } {
  if (style === 'digits') return { glyph: true };
  if (style === 'monogram') return { name: true, glyph: true };
  if (style === 'tagnum' || style === 'deck2') return { glyph: true, pct: true };
  if (style === 'ringdeck' || style === 'barsdeck') return { glyph: true, pct: true };
  if (style === 'grid' || style === 'strip' || style === 'sentinel') return { glyph: true };
  return {};
}
```

组件主体（卡片布局全用现有类：`card/chead/setrow/sw/seg/pill`）：
- 页头 `← 设置` 返回按钮（`onBack` prop）+ savetick（沿 Settings 的 savedTick 模式局部实现）。
- 实时预览卡：`<MenubarPreviewBar mode="dark" state={...}/>` + `mode="light"`，state 从 `useSettings()` 快照映射（providers 数组按 `QUOTA_PROVIDERS` 的 id 映射 demo id：`claude-code→claude`、`codex→codex`、`zhipu→zhipu`；OMP 仅演示不在真实 overrides 中则 visible 恒 true 展示）。
- 样式画廊：STYLE_GROUPS 渲染小节标题 + `.mbg` 按钮（缩略图=固定单家 demo cell 的 MenubarPreview 迷你渲染或静态 JSX，选中态 `.on`），点击 `apply(settingsStore.applyPatch(stylePatch(id, current)), 'mbstyle')`。
- 元素卡：三开关 + `elementLocks` + 至少保一（开启数 === 1 时那个开关 disabled）+ keepMsg 提示行（`.mbkeep`，四种文案按稿优先级）。**窗口顺序 seg 放本卡末行**：`7d 在前 / 5h 在前` 两段，patch `menubarWindowOrder`。
- 今日用量卡：三段 seg（关闭/Token/花费）patch `menubarUsage`。
- 按服务商卡：真实 `QUOTA_PROVIDERS`（Settings.tsx 现有常量提出为共享导出或本文件复制）逐行：显示开关（patch `providerMenubarVisible`）+ 图形窗口/数字窗口两组 mini seg（`5h/7d/双`，patch `providerGlyphWindow`/`providerNumberWindow`，值映射 short/long/both）。desc 写明「开关只控制菜单栏排布（数据接入启停在供应商额度接入卡）；图形与数字窗口各自独立；单窗口服务商任选均显示其唯一窗口」。窗口 seg 禁用联动：图形列在（样式无图形 或 图形关且非混合系）时 `.dis`；数字列在（数字关 且非数字支/混合系）时 `.dis`。

`Settings.tsx` 修改：
- `export const QUOTA_PROVIDERS`（加 export 供下钻页复用）。
- 顶部 `const [subview, setSubview] = useState<'main' | 'menubar'>('main');`，`subview === 'menubar'` 时渲染 `<MenubarAppearance onBack={() => setSubview('main')} />` 并 return。
- 「数据」卡之后、「外观」卡之前插入入口摘要卡：

```tsx
      {/* B2. 菜单栏外观 — 入口摘要卡（完整配置在下钻页） */}
      <div className="card mbentry" role="button" tabIndex={0} aria-label="菜单栏外观"
           onClick={() => setSubview('menubar')}
           onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') setSubview('menubar'); }}>
        <div className="chead" style={{ marginBottom: 10 }}>
          <div>
            <h2>菜单栏外观</h2>
            <div className="desc">托盘常驻区的样式、元素与每家窗口</div>
          </div>
          <span className="mbcur num">{currentStyleName}</span>
          <button className="btn" type="button" onClick={(e) => { e.stopPropagation(); setSubview('menubar'); }}>配置 →</button>
        </div>
        <MenubarPreviewBar mode="dark" state={previewStateFromSettings(settings)} />
      </div>
```

（`previewStateFromSettings`/`currentStyleName` 从 `MenubarAppearance.tsx` 导出复用；样式名映射 = STYLE_GROUPS 扁平查找。）

- [ ] **Step 4: 跑测试确认通过**

Run: `cd Electron && npx vitest run src/renderer/components/MenubarAppearance.test.tsx src/renderer/App.test.tsx 2>&1 | tail -5`
Expected: PASS（App.test 若有 Settings 渲染断言需保持兼容——入口卡为新增节点不破坏既有查询）。

- [ ] **Step 5: Electron 全量 + commit**

Run: `cd Electron && npm test 2>&1 | tail -5` → 全绿。

```bash
git add Electron/src/renderer/components/MenubarAppearance.tsx Electron/src/renderer/components/MenubarAppearance.test.tsx Electron/src/renderer/routes/Settings.tsx
git commit -m "feat: menubar appearance settings page with gallery, locks and per-provider windows"
```

---

### Task 8: 端到端验证与三套测试

**Files:** 无新增（验证任务）

- [ ] **Step 1: 三套测试全跑**

```bash
swift test 2>&1 | tail -3
cd Electron && npm test 2>&1 | tail -3
cd .. && python3 -m pytest scripts/ 2>&1 | tail -3   # 以仓库实际 Python 测试入口为准（见 CLAUDE.md/scripts）
```

Expected: 三套全绿（本次未动 ModelNameNormalizer/transform_pricing，Python 套应天然绿——若因无关原因红，如实上报不掩盖）。

- [ ] **Step 2: 真机验证（dev-app.sh 起开发实例）**

按记忆 `dev-workflow-scripts`：UI 热更用 `./dev-app.sh`（勿从仓库直接跑 electron，ABI 会炸）。清单：
1. 菜单栏出现默认 rings 样式（与升级前视觉一致——longFirst 默认，外环 7d）。
2. 设置页 → 菜单栏外观入口卡（当前样式名 + 深色预览）→ 配置 → 下钻页完整渲染。
3. 切 5-6 种代表样式（vbars/digits/dots/sentinel/deck2/ringdeck），真菜单栏即时变化、预览条同步。
4. 元素开关锁定/至少保一禁用态；关名称→菜单栏名称消失。
5. 窗口顺序切 5h 在前 → 双环外环变 5h、双数字翻转。
6. 按家：关掉一家菜单栏消失（弹窗仍在）；改图形窗口仅 5h → 单环/单条。
7. 今日用量三态（Token/花费/关闭）；全关+全隐藏 → 品牌小标。
8. Swift 端未运行时改设置 → 无报错（toast 正常）、重启 Swift 后生效。

- [ ] **Step 3: 收尾 commit（如有验证期修补）**

```bash
git add -A && git commit -m "fix: menubar styles polish from end-to-end verification"
```

---

## Self-Review 结论（计划完成时执行）

1. **Spec 覆盖**：§1 设置模型→Task 1/2；§2 通用语义→Task 3；§3 样式表→Task 4/5（渲染）+ Task 7（锁定/副作用 UI）；§4→Task 3/4/5；§5→Task 6/7;§6→各任务 Step + Task 8；§7 不做项未引入。
2. **占位符**：Task 6 组件主体与 Task 3 部分测试体为「结构+誊抄源指引」形式——誊抄源精确到稿文件行号（app.html 2941-3052 / 255-327），执行者无需自行设计，符合无占位要求的精神；其余任务代码完整。
3. **类型一致性**：`MenuBarProjection` 字段（style/showName/showGlyph/showNumber/windowOrder/cells/tail）在 Task 3 定义、Task 4/5 视图引用一致；`stylePatch`/`elementLocks`（Task 7）与 `effectiveElements`（Task 3）同表；Electron patch 字段名（menubarStyle/…/providerGlyphWindow）Task 2 与 Task 7 一致。
