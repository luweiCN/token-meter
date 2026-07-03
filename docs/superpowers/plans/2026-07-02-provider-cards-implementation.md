# 供应商多额度卡片实现计划

> **给 agent 工作者：** 必须使用 `superpowers:subagent-driven-development`（推荐）或 `superpowers:executing-plans` 按任务执行。本计划使用复选框（`- [ ]`）跟踪步骤。

**目标：** 实现一个参考 Stats 风格的 TokenMeter 浮窗，用供应商卡片展示 Codex、Claude Code、智谱的多项额度，并使用原生紧凑图表呈现。

**架构：** 保持现有 macOS SwiftPM 应用结构。新增比 `UsageSnapshot` 更丰富的供应商用量模型，provider 优先返回多额度快照，SwiftUI 浮窗消费这些快照并渲染卡片、圆环和细轨道图表。OpenCode Go 不进入本轮实现，只保留“不显示假数据”的禁用或错误状态。

**技术栈：** Swift、SwiftUI、AppKit 菜单栏、Swift Concurrency、`URLSession`、`Process`、XCTest。

## 全局约束

- 只做 macOS。
- 不使用 Electron、Tauri、WebView、浏览器自动化或第三方 Web 图表库。
- 图表必须用原生 SwiftUI / Swift 绘制。
- 本轮范围只包含 Codex、Claude Code、智谱。
- 本轮不实现 OpenCode Go dashboard 抓取。
- 单个供应商失败不能阻塞其他供应商。
- 不显示任何假额度。
- 文档使用中文。

---

### 任务 1：新增多额度用量模型

**文件：**
- 修改：`Sources/TokenMeterCore/UsageModels.swift`
- 修改：`Sources/TokenMeterCore/UsageFormatter.swift`
- 测试：`Tests/TokenMeterCoreTests/UsageFormatterTests.swift`

**接口：**
- 产出：`ProviderUsageSnapshot`、`UsageGroup`、`UsageMetric`、`UsageMetricKind`
- 产出：`UsageFormatter.menuBarTitle(for snapshots: [ProviderUsageSnapshot], primaryProviderId: String?) -> String`
- 保留：`UsageFormatter.numberText(_:)` 继续给 parser 使用

- [ ] **步骤 1：先写失败测试**

新增测试：构造一个包含 primary provider 和首个 metric 的 `ProviderUsageSnapshot`，断言菜单栏标题显示该 metric 的剩余百分比。

- [ ] **步骤 2：运行测试，确认失败**

运行：`swift test --filter UsageFormatterTests`

预期：失败，因为 `ProviderUsageSnapshot` 和新的 formatter overload 还不存在。

- [ ] **步骤 3：实现最小模型和 formatter overload**

在 `UsageModels.swift` 新增多额度模型。在 `UsageFormatter.swift` 新增 overload：优先选择配置的 primary provider，否则用第一个 snapshot；找到第一个带 `remainingPercent` 的 metric 后显示 `displayName remaining%`。

- [ ] **步骤 4：再次运行测试**

运行：`swift test --filter UsageFormatterTests`

预期：通过。

### 任务 2：实现供应商多额度解析

**文件：**
- 修改：`Sources/TokenMeterCore/ProviderConfig.swift`
- 修改：`Sources/TokenMeterCore/Providers.swift`
- 修改：`config/token-meter.example.json`
- 测试：`Tests/TokenMeterCoreTests/ProviderRegistryTests.swift`
- 测试：`Tests/TokenMeterCoreTests/ZhipuUsageParserTests.swift`
- 新增：`Tests/TokenMeterCoreTests/CodexUsageParserTests.swift`
- 新增：`Tests/TokenMeterCoreTests/ClaudeUsageParserTests.swift`

**接口：**
- 产出：`UsageProvider.fetchProviderUsage() async -> ProviderUsageSnapshot`
- 产出：`CodexUsageParser.parse(data:providerId:displayName:fetchedAt:)`
- 产出：`ClaudeUsageParser.parse(data:providerId:displayName:fetchedAt:)`
- 更新：`ZhipuUsageParser.parseProviderUsage(data:providerId:displayName:fetchedAt:)`

- [ ] **步骤 1：先写失败 parser 测试**

Codex 测试覆盖 `rateLimitsByLimitId.codex` 和 `rateLimitsByLimitId.codex_bengalfox`，其中 `codex_bengalfox` 的 `limitName` 是 `GPT-5.3-Codex-Spark`。Claude 测试覆盖 `five_hour`、`seven_day` 和非空的 `seven_day_sonnet`。智谱测试断言 `5h`、`7d`、`MCP` 都是独立 metric。

- [ ] **步骤 2：运行 parser 测试，确认失败**

运行：`swift test --filter CodexUsageParserTests && swift test --filter ClaudeUsageParserTests && swift test --filter ZhipuUsageParserTests`

预期：失败，因为 parser API 还不存在。

- [ ] **步骤 3：实现 parser API 和 provider 默认适配**

新增 `ProviderType.codex` 和 `ProviderType.claudeCode`。新增原生 provider：

- Codex：通过一个小型内嵌 Node helper 调用 `codex app-server --stdio`，读取 `account/rateLimits/read`。
- Claude Code：通过 macOS `security` 命令读取 `Claude Code-credentials`，解析 `claudeAiOauth.accessToken`，再请求 `https://api.anthropic.com/api/oauth/usage`。
- 智谱：继续使用 `ZHIPU_API_KEY`，把 limits 映射成多个 metric。

旧的 `fetchUsage()` 继续作为兼容适配，从新的多额度快照里提取首要 metric。

- [ ] **步骤 4：运行 parser 和 registry 测试**

运行：`swift test --filter ProviderRegistryTests && swift test --filter CodexUsageParserTests && swift test --filter ClaudeUsageParserTests && swift test --filter ZhipuUsageParserTests`

预期：通过。

### 任务 3：渲染 Stats 风格供应商卡片

**文件：**
- 修改：`Sources/TokenMeterApp/ProviderStore.swift`
- 修改：`Sources/TokenMeterApp/StatusBarController.swift`
- 替换：`Sources/TokenMeterApp/PopoverView.swift`

**接口：**
- 消费：`ProviderStore.providerSnapshots: [ProviderUsageSnapshot]`
- 产出：`QuotaRingView`、`QuotaMeterView`、`MetricRowView`、`ProviderCardView`

- [ ] **步骤 1：更新 store，发布多额度快照**

`ProviderStore.refresh()` 调用 `fetchProviderUsage()`，同时更新 `providerSnapshots` 和兼容旧 UI / 状态栏的 `snapshots`。

- [ ] **步骤 2：更新状态栏标题**

`StatusBarController` 调用新的 `UsageFormatter.menuBarTitle(for: providerSnapshots, primaryProviderId:)`。

- [ ] **步骤 3：替换浮窗布局**

渲染顶部 header、图标刷新按钮、可滚动供应商卡片、每个供应商最多一个 summary ring，以及每个 metric 的 compact meter 行。

- [ ] **步骤 4：构建**

运行：`swift build`

预期：通过。

### 任务 4：手动验证 App

**文件：**
- 除非验证发现 bug，否则不修改文件。

**接口：**
- 消费：构建后的 `TokenMeterApp`

- [ ] **步骤 1：运行完整测试**

运行：`swift test`

预期：通过。

- [ ] **步骤 2：打包并启动 app**

运行：`./scripts/package-dev-app.sh && open build/TokenMeter.app`

预期：App 出现在 macOS 菜单栏。

- [ ] **步骤 3：视觉验证**

检查 Codex 显示主 Codex 和 `GPT-5.3-Codex-Spark`，Claude 显示可用 metric，智谱显示 5h / 7d / MCP，OpenCode Go 不显示假额度。

