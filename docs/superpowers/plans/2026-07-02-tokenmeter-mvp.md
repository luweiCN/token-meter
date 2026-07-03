# TokenMeter MVP 实现计划

> **给 agent 工作者：** 必须使用 `superpowers:subagent-driven-development`（推荐）或 `superpowers:executing-plans` 按任务执行。本计划使用复选框（`- [ ]`）跟踪步骤。

**目标：** 初始化一个 macOS 原生菜单栏 MVP，通过本地配置显示 Codex、Claude Code、OpenCode Go、智谱的用量/额度状态，并为智谱预留真实 HTTP 查询适配器。

**架构：** 使用 Swift Package 管理项目，拆分为 `TokenMeterCore` 核心库和 `TokenMeterApp` 菜单栏可执行程序。核心库负责配置、模型、provider 适配和格式化；App 只负责状态栏、浮窗、刷新调度。

**技术栈：** Swift Package Manager、Swift、AppKit、SwiftUI、Foundation、URLSession、XCTest。

## 全局约束

- 第一版只支持 macOS。
- 常驻层必须是原生 AppKit / Swift，不引入 Electron、Tauri 或 WKWebView。
- MVP 不做复杂设置页，通过本地配置文件描述供应商。
- Codex、Claude Code、OpenCode Go 第一版先作为配置驱动的本地用量项。
- 智谱第一版提供 HTTP provider 结构，密钥先通过环境变量或配置引用读取，不把真实密钥写进仓库。
- 项目名为 `TokenMeter`，目录名为 `token-meter`，Bundle ID 预留为 `com.luwei.tokenmeter`。

---

## 文件结构

- `Package.swift`：SwiftPM 项目定义。
- `Sources/TokenMeterCore/UsageModels.swift`：通用用量模型。
- `Sources/TokenMeterCore/ProviderConfig.swift`：配置文件结构。
- `Sources/TokenMeterCore/ProviderConfigLoader.swift`：配置加载与默认配置。
- `Sources/TokenMeterCore/UsageFormatter.swift`：菜单栏和浮窗展示格式化。
- `Sources/TokenMeterCore/Providers.swift`：provider 协议、静态 provider、智谱 provider、registry。
- `Sources/TokenMeterApp/main.swift`：macOS App 启动入口。
- `Sources/TokenMeterApp/AppDelegate.swift`：应用生命周期。
- `Sources/TokenMeterApp/ProviderStore.swift`：刷新状态和数据绑定。
- `Sources/TokenMeterApp/StatusBarController.swift`：`NSStatusItem` 和 popover 控制。
- `Sources/TokenMeterApp/PopoverView.swift`：原生 SwiftUI 浮窗。
- `Tests/TokenMeterCoreTests/*`：核心逻辑测试。
- `config/token-meter.example.json`：示例配置。

## 任务

### 任务 1：初始化项目骨架

**文件：**
- 创建：`Package.swift`
- 创建：`Sources/TokenMeterCore/`
- 创建：`Sources/TokenMeterApp/`
- 创建：`Tests/TokenMeterCoreTests/`
- 创建：`config/token-meter.example.json`

**验证：**
- `swift test` 能发现测试 target。
- `swift build` 能编译空的 app target。

### 任务 2：核心模型和配置解析

**文件：**
- 创建：`Sources/TokenMeterCore/UsageModels.swift`
- 创建：`Sources/TokenMeterCore/ProviderConfig.swift`
- 创建：`Sources/TokenMeterCore/ProviderConfigLoader.swift`
- 创建：`Tests/TokenMeterCoreTests/ProviderConfigLoaderTests.swift`

**接口：**
- `ProviderConfigLoader.decode(_ data: Data) throws -> TokenMeterConfig`
- `ProviderConfigLoader.defaultConfig() -> TokenMeterConfig`
- `UsageSnapshot`
- `ProviderConfig`
- `TokenMeterConfig`

**验证：**
- 配置能解析 4 个默认 provider。
- 示例配置中包含 `codex`、`claude-code`、`opencode-go`、`zhipu`。

### 任务 3：用量格式化

**文件：**
- 创建：`Sources/TokenMeterCore/UsageFormatter.swift`
- 创建：`Tests/TokenMeterCoreTests/UsageFormatterTests.swift`

**接口：**
- `UsageFormatter.menuBarTitle(for snapshots: [UsageSnapshot], primaryProviderId: String?) -> String`
- `UsageFormatter.detailLine(for snapshot: UsageSnapshot) -> String`

**验证：**
- 有正常数据时，菜单栏显示主要 provider 的紧凑信息。
- 没有数据时，菜单栏显示 `TokenMeter`。
- provider 异常时，菜单栏显示异常状态。

### 任务 4：Provider 适配器

**文件：**
- 创建：`Sources/TokenMeterCore/Providers.swift`
- 创建：`Tests/TokenMeterCoreTests/ProviderRegistryTests.swift`
- 创建：`Tests/TokenMeterCoreTests/ZhipuUsageParserTests.swift`

**接口：**
- `UsageProvider.fetchUsage() async -> UsageSnapshot`
- `ProviderRegistry.makeProviders(from config: TokenMeterConfig) -> [UsageProvider]`
- `ZhipuUsageParser.parse(data: Data, providerId: String, displayName: String) throws -> UsageSnapshot`

**验证：**
- manual provider 从配置返回本地用量。
- registry 能为 4 个默认 provider 创建 provider。
- 智谱 parser 能从常见 quota JSON 字段中提取 remaining / used / total。

### 任务 5：macOS 菜单栏 App

**文件：**
- 创建：`Sources/TokenMeterApp/main.swift`
- 创建：`Sources/TokenMeterApp/AppDelegate.swift`
- 创建：`Sources/TokenMeterApp/ProviderStore.swift`
- 创建：`Sources/TokenMeterApp/StatusBarController.swift`
- 创建：`Sources/TokenMeterApp/PopoverView.swift`

**接口：**
- `ProviderStore.refresh() async`
- `StatusBarController.updateTitle(_ title: String)`

**验证：**
- `swift build` 编译通过。
- `swift run TokenMeterApp` 能启动菜单栏应用。

### 任务 6：最终验证

**命令：**
- `swift test`
- `swift build`

**验收：**
- 测试通过。
- 构建通过。
- 文档和示例配置存在。
