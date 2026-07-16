# 菜单栏样式族 + 定制化设置 · 实现 Spec

来源设计稿（用户已批准，规则以稿内 JS 为权威、本文为实现映射）：
- `~/Library/Application Support/Open Design/.../menubar-styles.html`（16 样式画板）
- `~/Library/Application Support/Open Design/.../app.html`（设置入口卡 + 「菜单栏外观」下钻页，交互 JS 行 2900-3140）

## 1. 设置模型

### 全局（settings 表 kv，Electron 写入、Swift 只读）

| key | 类型 | 取值 | 默认 |
|---|---|---|---|
| `menubar.style` | string | rings / vbars / hbar / digits / dots / caps / ticks / ring1 / grid / sentinel / monogram / strip / tagnum / deck2 / ringdeck / barsdeck | rings |
| `menubar.showName` | int | 0/1 | 1 |
| `menubar.showGlyph` | int | 0/1 | 1 |
| `menubar.showNumber` | int | 0/1 | 1 |
| `menubar.usage` | string | off / tok / cost | tok |
| `menubar.windowOrder` | string | longFirst / shortFirst | **longFirst**（保持现状 S0 视觉：7d 在前；用户裁定做成设置项） |

### 按家（provider_config_overrides 表）

- `show_in_menu_bar`（已有列）：菜单栏显示开关，NULL=默认显示。独立于 `enabled`（那个停数据刷新）。
- `menubar_glyph_window` TEXT（'short'/'long'/'both'，NULL=both）【新列】
- `menubar_number_window` TEXT（同上）【新列】

窗口身份用 short/long 语义（5h=short、7d=long）。单窗口家（如 Codex 仅 7d）：渲染端任何配置恒取唯一窗口；设置页不感知快照（overrides 无窗口信息），seg 不禁用、表格说明文案注明该退化规则。

### 迁移

- Swift `TokenMeterDatabaseSchema` 的 CREATE TABLE 加两列；`TokenMeterDatabaseMigrator.migrate` 增加幂等 additive 步骤（pragma table_info 检查缺列则 ALTER TABLE ADD COLUMN），置于版本重建逻辑之前、对配置表生效。
- Electron `SettingsRepository` 构造时执行同款幂等 ensure（防止 Swift 未跑过新版时 Electron 先行查询炸列）。

## 2. 通用渲染语义（全样式共享）

- **数据源**：`displayProviderSnapshots` → `QuotaDisplayModel.rings`（label + 剩余% + pace tone），本次沿用 tone 语义（**不改**警戒算法；稿内 ≥40/15/40 阈值是演示口径）。
- **窗口 pick**：short/long/both 按家配置各自作用于图形与数字；both 的呈现顺序由 `menubar.windowOrder` 决定（图形双元素顺序 + 双数字先后一致翻转）。
- **worst（最险窗）**：数字窗口集合中剩余%最小者；聚合样式的家级状态 = 该家最险窗。
- **stale**：`staleMinutes != nil`（快照超 10 分钟）→ 整 cell 灰（g-off 语义），数字显示 `—`，图形保形降透明；sentinel 灰态显示 `Xm` 分钟数。
- **数字**：剩余%取整、无 % 号、等宽、tabular；双数字 `A·B` 分隔点弱化。**双数字各自跟随所属窗口 tone 染色**（沿用 S0 用户裁定的打磨，覆盖设计稿 JS 的「统一最险色」简化；数字色=窗口 tone，与图形画不画该窗无关）。单数字=最险窗值、染最险窗色。
- **超宽降级**（digits 等文字样式）：数字窗口 both 且名称开启且短名含 CJK → 数字降为最险单窗（稿 S3 规则）。
- **警戒色**：现有 toneColor 映射（systemGreen/Yellow/Red/tertiaryLabel）不变。
- **今日尾巴**：组件级最右 cell；tok=`UsageFormatter.compactTokens`、cost=`$` + 今日花费（`MenuBarTodaySummary` costUsdMicros 汇总）、off=隐藏。次级视觉（opacity ~0.75），保留 numericText 滚动。
- **全空**（无可见 cell 且尾巴关/无数据）：显示现有 15×15 品牌小标（MenuBarBrandMark）。

## 3. 样式规则表（glyph/数字/锁定/切换副作用，源自稿 JS）

**每家一 cell（S0-S7）**：cell 语法 `[name][glyph][pct]`。

| id | glyph | 备注 |
|---|---|---|
| rings | 17pt 同心双环（both）/ 单环；**保留现状实现**：butt 端点、底环 0.28、overlay 同心 | S0 不重画；窗口顺序按 windowOrder |
| vbars | 3×13pt 竖条底向上填充，双窗两根间距 2 | 双数字允许 |
| hbar | 22×3pt 横条上下叠，单窗加粗 4pt | 数字=最险单窗 |
| digits | 无图形（glyph 锁死关） | 双数字允许；CJK 超宽降级 |
| dots | 6pt 圆点每窗一点 | 数字默认关（切样式时不强制，pct 状态保留但初始建议关——按稿：切 dots 无副作用，数字随全局开关） |
| caps | 14×8pt 胶囊，内缩 1pt 填充 | 数字=最险单窗 |
| ticks | 5 格 2.5×10pt 刻度，亮格=round(p/20) 至少 1；双窗=两组 | 双组刻度时数字自动隐藏（稿定） |
| ring1 | 15pt 单环，弧=剩余（round 端点可用，单弧无对称问题） | 只画一个窗口：图形窗口=short/long 取所选；both 时取 windowOrder 首位（稿定单环「只留最要紧那个」语义） |

**聚合紧凑族（S8-S11）**：全家一个 cell。家级最险窗来源（稿 JS 权威）：grid/strip 取该家**图形窗口**集合的最险；monogram/sentinel 取该家**数字窗口**集合的最险；聚合追加数字（grid/strip/monogram 的 px、sentinel 的报警数字）一律取数字窗口最险。

| id | 形态 | 名称开关语义 | 数字开关语义 |
|---|---|---|---|
| grid | 2×2（4家）/单行（≤3家）5.5pt 点阵，固定序=menuRank | 开=品牌 logo 前缀 | 开=全家最险单数字 |
| strip | 13pt 高分段条每家 6pt 段、1pt 缝 | 同上 | 同上 |
| monogram | 单字符×N 警戒色染字、stale=删除线（第二编码） | 锁死开（字符即名称） | 开=追加全家最险数字 |
| sentinel | 全正常=灰 logo；有 warn/bad=最险家（logo染色+短名+数字，各随元素开关）；全绿有 stale=灰 logo+`Xm` | 可关（关=logo+数字） | 可关 |

- monogram/tagnum 单字符规则：依 menuRank 序取短名第 1 字符，与已占用重复则依次后移（CC→C、CX→X、智谱→智、OMP→O，与稿一致）。

**数字支（S12-S13）**：全家一个 cell、每家一个 unit、按家窗口全语义支持；glyph+pct 锁死（无图形、数字为本体），名称可关（裸数字位序）。

| id | unit 形态 |
|---|---|
| tagnum | 单字符 10pt 半透明前标 + 数字（baseline 排） |
| deck2 | 上行 7.5pt 短名 / 下行 10.5pt 数字（纵向两层，双窗数字仍单行 `A·B`） |

**混合系（S14-S15）**：每家一 cell；glyph+pct 锁死开，名称可关。

| id | 组成 |
|---|---|
| ringdeck | 图形窗口 both→17pt 双环、单→15pt 单环 + deck2 unit |
| barsdeck | 竖条（both 双条/单条）+ deck2 unit |

**元素锁定汇总**（设置 UI 与渲染共同遵守）：
- glyph 锁死关：digits、monogram、tagnum、deck2
- glyph 锁死开：grid、strip、sentinel（图形为本体）、ringdeck、barsdeck
- pct 锁死开：tagnum、deck2、ringdeck、barsdeck
- name 锁死开：monogram
- 通用：三元素只剩一个开时该开关禁用；提示文案三种（至少保一 / 数字支说明 / 混合系说明 / 紧凑 logo 说明，按稿 keepMsg 优先级）

**切换样式副作用**（稿 JS click 规则）：digits→glyph=off；monogram→name=on,glyph=off；tagnum/deck2→pct=on,glyph=off；ringdeck/barsdeck→pct=on,glyph=on；grid/strip/sentinel→glyph=on；其他样式若 name/pct 全关→glyph=on。

**窗口 seg 联动禁用**：图形窗口列禁用当（样式无图形 或 glyph 关且非混合系）；数字窗口列禁用当（pct 关 且非数字支 且非混合系）。

## 4. Swift 端实现映射

- `MenuBarQuotaModel` 重构为承载完整投影：输入 snapshots + settingsSnapshot（新字段），输出 `MenuBarRenderModel`（样式 id、cell 列表或聚合模型、今日尾巴态）。窗口识别：rings 数组第一个=short、最后=long（单窗口家 short=long=唯一窗口，但标记 isSingleWindow 供 seg 禁用）。
- `StatusBarContentView` 按样式分发到子 view；每样式一个小 SwiftUI view（文件 `MenuBarStyleViews.swift` 统一放置，rings 复用现有 `MenuBarQuotaCellView` 改造）。
- 品牌 logo（sentinel/grid/strip 前缀）复用 `MenuBarBrandMark` 缩至 13pt。
- 动画：数字仍 numericText；图形值变化 smooth（沿用现有 reduceMotion 尊重）。
- `SettingsSnapshot`（Swift）加全局 6 字段 + `ProviderConfigOverride` 加 2 字段；`SettingsStore.snapshot()` 读取；`importConfigIfNeeded` 不动（新键靠默认值兜底）。

## 5. Electron 端实现映射

- `Settings.tsx`：新增「菜单栏外观」入口摘要卡（当前样式名 + 深色 mini 预览 + 配置→），点击进入子页；子页为 Settings 内部状态切换（不动 App.tsx 路由），返回按钮回设置主列表。
- 新组件 `MenubarAppearance.tsx`：实时预览（深/浅双条）、样式画廊（4 分组小节标题 + 16 项缩略）、元素卡（3 开关 + keep 提示）、今日用量卡（3 段）、按家表格（显示开关 + 图形窗口/数字窗口 seg + 单窗家禁用）+ 全局窗口顺序段（7d 在前 / 5h 在前——设计稿未画，按既有 seg 组件语言放「元素」卡内）。
- 预览渲染器 `menubarPreview.tsx`：设计稿 JS 的 React 翻译，演示口径数据（与稿同源），CSS 移植稿内 `.mb*` 规则（品牌青禁入 cell）。
- `settingsStore` / `api.ts` / `settingsRepository.ts` / `preload.ts`：SettingsPatch 加 `menubarStyle`、`menubarShowName/Glyph/Number`、`menubarUsage`、`menubarWindowOrder`、`providerMenubarVisible`、`providerGlyphWindow`、`providerNumberWindow`（Record<providerId, …>）；Snapshot 同步扩展；validate 按各自枚举。
- 保存后走既有 `notifySwift('settingsChanged')` 链路，菜单栏即时生效。

## 6. 测试

- Swift：投影单测（样式×开关×窗口×stale 组合的 RenderModel 断言；聚合最险/哨兵升级链/超宽降级/窗口顺序翻转）；StatusBar 更新链路现有测试扩展。
- Electron：settingsRepository 新字段读写/校验、ensure 列幂等；settingsStore patch；MenubarAppearance 组件交互（锁定/联动禁用/切换副作用）。
- 收尾三套全跑（swift test / vitest / python 对账）。

## 7. 明确不做

- 不改 tone/pace 算法；不做供应商拖拽排序（menuRank 已有序）；预览用演示数据不接真实快照；S0 变体不重画；OMP 额度供应商不新增（预览演示 4 家、真实端按实际供应商渲染）。
