# TokenMeter

TokenMeter 是一个 macOS 菜单栏小工具，用来查看 AI 工具或供应商的 token 用量、额度、余额等状态。

第一版是原生 macOS MVP：

- 使用 AppKit 创建菜单栏入口。
- 使用 SwiftUI 创建点击后的原生浮窗。
- 不使用 Electron、Tauri 或 WKWebView。
- 通过本地配置文件描述供应商。
- Codex、Claude Code、OpenCode Go 第一版先作为手写配置项。
- 智谱第一版提供 HTTP 查询 provider，API Key 通过环境变量读取。

## 运行

```bash
swift run TokenMeterApp
```

运行后，TokenMeter 会出现在 macOS 菜单栏。左键点击菜单栏文字可以打开浮窗并手动刷新；右键点击会显示菜单，可打开 Electron 主界面或退出应用。

也可以打包一个开发版 `.app` 后打开：

```bash
scripts/package-dev-app.sh
open build/TokenMeter.app
```

## 配置

默认会按下面顺序读取配置：

1. `TOKENMETER_CONFIG` 环境变量指向的 JSON 文件。
2. `~/.token-meter/config.json`。
3. 内置默认配置。

示例配置见：

```text
config/token-meter.example.json
```

智谱 API Key 使用环境变量：

```bash
export ZHIPU_API_KEY="你的智谱 API Key"
```

智谱只读取这个环境变量，不会从其他文件位置读取 API Key。

OpenCode Go 套餐额度来自 OpenCode Go dashboard，不是 OpenCode 本地 session 数据。TokenMeter 支持两种配置方式：

```bash
export OPENCODE_GO_WORKSPACE_ID="你的 workspace id"
export OPENCODE_GO_AUTH_COOKIE="你的 dashboard auth cookie"
```

或者写入文件：

```text
~/.config/opencode/opencode-quota/opencode-go.json
```

格式：

```json
{
  "workspaceId": "你的 workspace id",
  "authCookie": "你的 dashboard auth cookie"
}
```

本地调试时可以复制示例配置到本地文件：

```bash
mkdir -p ~/.token-meter
cp config/token-meter.example.json ~/.token-meter/config.json
```

不要把真实 API Key 写进仓库。

## 开发验证

```bash
swift test
swift build
```

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
