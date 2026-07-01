# TokenMeter 多额度卡片浮窗设计

## 背景

当前 TokenMeter 已经能读取 Codex、Claude Code 和智谱的部分真实数据，但 UI 和数据模型都过于扁平：每个供应商只能返回一条 `UsageSnapshot`。这会把多个额度窗口压成一段字符串，无法表达不同供应商的真实结构。

本轮目标是把菜单栏浮窗升级为一个更精致的信息面板，并把数据模型从“一家供应商一条摘要”扩展为“一家供应商多个额度项”。

OpenCode Go 暂不进入本轮实现。它只在界面里保留可禁用或弱提示状态，不再作为本轮质量目标。

## 范围

本轮只做好三个供应商：

- Codex
- Claude Code
- 智谱

本轮需要展示的额度维度：

- Codex：主 Codex 额度，以及 `rateLimitsByLimitId` 里返回的独立子额度，例如 `GPT-5.3-Codex-Spark`。
- Claude Code：`five_hour`、`seven_day`，以及接口返回时可用的模型专属额度，例如 `seven_day_sonnet`。
- 智谱：5 小时额度、7 天额度、MCP / 工具额度。

本轮不做：

- OpenCode Go dashboard 抓取。
- 供应商管理设置页。
- 历史趋势数据库。
- WebView 控制台。
- 长周期统计报表。

## 数据模型

新增一个面向 UI 的多额度模型，保留旧 `UsageSnapshot` 的兼容能力。

建议结构：

```swift
public struct ProviderUsageSnapshot: Equatable {
    public let providerId: String
    public let displayName: String
    public let status: UsageStatus
    public let fetchedAt: Date
    public let summary: String?
    public let message: String?
    public let groups: [UsageGroup]
}

public struct UsageGroup: Equatable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let items: [UsageMetric]
}

public struct UsageMetric: Equatable {
    public let id: String
    public let label: String
    public let kind: UsageMetricKind
    public let usedPercent: Double?
    public let remainingPercent: Double?
    public let resetText: String?
    public let status: UsageStatus
    public let detail: String?
}
```

`UsageMetric` 以百分比为主，因为三家当前最稳定的展示口径都是额度百分比。后续余额、token 数、金额可以通过 `kind` 扩展。

`UsageSnapshot` 可以继续存在，用于菜单栏标题和旧测试兼容；新的 provider 优先返回 `ProviderUsageSnapshot`。实现时可以先给 `UsageProvider` 增加默认适配方法，避免一次性重写所有 provider。

## Provider 解析

### Codex

从 `codex app-server --stdio` 的 `account/rateLimits/read` 读取：

- `rateLimitsByLimitId.codex`
- 其他 `rateLimitsByLimitId.*`

每个 limit bucket 形成一个 `UsageGroup`：

- `codex` 显示为 `Codex`
- 有 `limitName` 的 bucket 使用 `limitName`，例如 `GPT-5.3-Codex-Spark`
- 没有 `limitName` 的 bucket 使用 limit id 的可读化名称

每个 group 里展示：

- `5h`：primary window
- `7d`：secondary window

百分比统一显示剩余额度：`remaining = 100 - usedPercent`。

### Claude Code

从 `https://api.anthropic.com/api/oauth/usage` 读取，继续使用 Claude Code Keychain 里的 OAuth token。

基础 group 展示：

- `5h`
- `7d`

如果响应里出现非空模型专属字段，则追加对应 group 或 metric：

- `seven_day_sonnet` 显示为 `Sonnet`
- `seven_day_opus` 显示为 `Opus`
- 其他已知字段按可读名称展示

百分比同样统一显示剩余额度：`remaining = 100 - utilization`。

### 智谱

继续使用 `https://bigmodel.cn/api/monitor/usage/quota/limit` 和 `ZHIPU_API_KEY` 环境变量。

从 `data.limits` 中映射：

- `TOKENS_LIMIT` + `unit == 3`：`5h`
- `TOKENS_LIMIT` + `unit == 6`：`7d`
- `TIME_LIMIT` + `unit == 5`：`MCP`

智谱只有一个 provider group，group 标题为 `智谱 Coding Plan`。每个 limit 是一个 `UsageMetric`。

## 菜单栏标题

菜单栏仍然保持克制，不展示太多内容。

第一版规则：

- 使用配置里的 primary provider。
- 如果 primary provider 正常，显示最重要额度的剩余百分比。
- Codex 默认使用 `Codex / 5h`。
- Claude Code 默认使用 `5h`。
- 智谱默认使用 `5h`。
- 如果 primary provider 异常，显示供应商名 + 异常状态。

示例：

```text
Codex 48%
Claude 100%
智谱 72%
```

## 浮窗 UI

浮窗继续使用原生 SwiftUI，不引入 WebView。

视觉参考采用 Stats 的方向：原生菜单栏工具、轻量弹窗、小尺度图表、细描边容器、克制的颜色状态，而不是后台式大屏仪表盘。

整体尺寸建议：

- 宽度：420 到 460 px
- 高度：根据内容自适应，最大约 560 px
- 内容超出时使用滚动

视觉结构：

- 顶部标题栏：`TokenMeter`、整体状态、刷新按钮、刷新中状态。
- 供应商卡片列表：每个供应商一张卡片。
- 卡片内先显示供应商名称、更新时间和状态。
- 卡片内按 group 展示多额度项。
- 每个额度项使用精致的 compact meter 作为图表。
- 重点供应商卡片顶部可以增加一个小型 summary ring，用来突出最重要额度。

不用复杂大图表，避免状态栏工具显得重。图表采用 Stats 风格的小型原生图形组合：

- Summary ring：小圆环，显示 provider 的首要剩余额度。
- Compact meter：细轨道横向条，显示每个额度项的剩余百分比。
- Micro sparkline 预留：后续如果有历史缓存，再在卡片顶部加入很小的趋势线。

第一版界面示意：

```text
Codex
  ◔ 48% remaining
  Codex
    5h  48%  ━━━━━━━────  3h12m
    7d  67%  ━━━━━━━━━──  5d4h
  GPT-5.3-Codex-Spark
    5h 100%  ━━━━━━━━━━━  5h
    7d 100%  ━━━━━━━━━━━  7d
```

颜色语义：

- 绿色：剩余充足。
- 黄色：剩余偏低或使用节奏偏快。
- 红色：剩余很低或已经异常。
- 灰色：未知、不可用、暂不支持。

卡片风格：

- 8px 以内圆角。
- 使用系统背景和轻描边，不做厚重阴影。
- 避免大面积单色主题。
- 按钮使用图标按钮，刷新按钮使用系统或 SF Symbol 图标。
- 文字层级要清楚，供应商名醒目，额度项紧凑。
- 图表控件保持固定高度，避免不同 provider 刷新后布局跳动。
- 图表颜色可以有轻微透明和细腻渐变，但不能依赖大面积装饰色块。
- 数字使用等宽数字排版，百分比和倒计时右对齐，便于快速扫描。

## 图表规则

本轮图表只做即时额度图，不做历史趋势图。

Stats 参考点：

- Stats 的菜单栏和弹窗图表都很小，但通过细线、圆角容器、颜色语义和数字排版保持精致。
- Stats 的弹窗常用顶部 dashboard 图形 + 中部小图表 + 下方详情行的层级。本轮 TokenMeter 采用简化版：provider card 顶部 summary ring + 下面多行 compact meter。
- Stats 的图表控件是原生绘制。TokenMeter 也保持原生 SwiftUI/Swift 绘制，不引入 WebView 或第三方 Web 图表库。

TokenMeter 第一版图表组件：

- `QuotaRingView`：小型圆环，默认 44 到 56 px，显示首要额度剩余百分比。
- `QuotaMeterView`：横向细轨道，默认高度 6 到 8 px，圆角填充。
- `MetricRowView`：label、百分比、meter、reset/detail 的固定布局行。

每个 `UsageMetric` 显示：

- label：例如 `5h`、`7d`、`MCP`、`Sonnet`
- 剩余百分比
- 水平进度条
- resetText 或详情文本

进度条表达“剩余额度”，不是“已用额度”。这和当前 tmux 脚本保持一致，更符合用户关注“还剩多少”的心智。

颜色规则：

- 剩余 >= 50%：绿色或系统 accent 的安全状态。
- 20% <= 剩余 < 50%：黄色。
- 剩余 < 20%：红色。
- 未知或暂不可用：灰色。

视觉要求：

- ring 和 meter 的背景轨道使用低透明度灰色。
- 填充色允许轻微渐变，但不能做发光、厚阴影或大面积彩色背景。
- 同一张卡片内最多只有一个 summary ring，避免视觉噪音。
- 多额度 provider 使用紧凑分组，不把每个 metric 做成独立卡片。

如果后续要表达历史趋势，再单独引入 SQLite 和折线/柱状图，不放进本轮。

## 参考资料

- Stats GitHub 仓库：https://github.com/exelban/stats
- Stats README 截图展示了菜单栏小组件和弹窗图表组合。
- Stats 的 `BarChart.swift`、`PieChart.swift`、`LineChart.swift` 展示了小尺度原生图表的实现方向。本项目只参考设计原则，不复制代码。

## 错误与空状态

错误不能只显示“未知”。

状态文案要求：

- 缺少凭据：显示“缺少登录凭据”或“缺少 API Key”。
- 认证失败：显示“认证失败，需要重新登录”。
- 接口结构变化：显示“响应结构无法解析”。
- OpenCode Go：显示“暂未启用额度读取”，不要显示假数据。

错误卡片仍保留供应商位置，避免用户误以为供应商消失。

## 刷新与性能

刷新逻辑保持顺序或有限并发均可，但 UI 必须避免卡顿。

要求：

- 点击刷新后立刻显示刷新中状态。
- 单个供应商失败不影响其他供应商。
- 不启动浏览器。
- 不引入 WebView。
- 不保存额外敏感数据。

Codex 和 Claude Code 的外部调用需要超时保护，避免浮窗长期卡住。

## 测试

需要补充单元测试：

- Codex 多 bucket 解析：包含 `codex` 和 `codex_bengalfox`。
- Claude usage 解析：基础 `five_hour` / `seven_day`，以及非空 `seven_day_sonnet`。
- 智谱 limits 解析：5h、7d、MCP 都出现在 `UsageMetric`。
- 菜单栏标题选择 primary provider 的首要 metric。
- 错误 snapshot 能保留供应商身份和错误文案。

UI 不做复杂快照测试，但实现后需要人工打开 app 验证：

- 菜单栏标题正常。
- 浮窗内容不重叠。
- 多 group 的 Codex 卡片能正常滚动或自适应。
- 智谱 MCP 额度可见。
- OpenCode Go 不显示假数据。
