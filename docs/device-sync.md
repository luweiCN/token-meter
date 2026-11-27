# TokenMeter 设备与命令行

macOS、Windows 和 Linux 上的 `token-meter` 都能采集、保存、转发和查询用量。每个节点都有自己的 SQLite 和 Ed25519 设备身份，可以在其他节点离线时提供已同步的数据。macOS 弹窗按当天列出各机器、Agent 和模型的 Token、花费和缓存命中率。至少两台有消耗才显示「机器」。「模型」合并所有已同步设备的同名模型，「合计」包含当天的全部模型。悬停在未计价提示上可查看涉及的模型及条数。缓存命中率按已记录的输入 Token 加权。主界面的「设备」页可查各机器的累计和历史明细。原有总览、项目与会话页展示本机明细。

macOS 菜单栏的今日数字、弹窗头部的今日用量、总计、本月、本周和月历都按本机保存的全部设备用量统计。本月和本周算至今天，本周从周一开始。今日或月历日期的会话数仅在来源覆盖完整时显示。

弹窗的 Agent 和模型各默认显示前五项。超过五项时，点相应表头即可展开或收起。两个列表可以同时展开，各自记住选择。点弹窗底部的齿轮可直接打开主窗口的设置页。在「菜单栏外观 → 峰/谷标识」可分别控制顶部菜单栏的标识和菜单栏弹窗中的峰谷时段。

## 安装和启动

使用当前系统与 CPU 对应的 `token-meter-<darwin|linux|windows>-<amd64|arm64>` 可执行文件，Windows 文件带 `.exe`。将它命名为 `token-meter` 或 `token-meter.exe` 并放进 PATH。源码构建使用 `go build -trimpath -o token-meter ./CLI`，Go 版本见仓库根目录的 `go.mod`。Mac 应用包内的入口是 `Contents/MacOS/token-meter`。

```sh
token-meter scan
token-meter usage
token-meter service install
token-meter service status
```

在运行 Agent 的账户下安装，采集根默认随该账户的主目录。`--home` 和 `--state` 是全局参数，写在子命令之前。自定义来源可执行 `token-meter config openclaw /path/to/state` 或 `token-meter config hermes /path/to/profile`。OpenClaw 也支持 `OPENCLAW_STATE_DIR`，Hermes 支持 `HERMES_HOME`。容器部署可将来源目录只读挂载给运行 CLI 的账户。

| 系统 | 常驻方式 |
| --- | --- |
| Linux | root 安装为 systemd 系统服务。普通用户安装为用户服务，同时用 `loginctl enable-linger` 设置退出登录后运行和下次开机启动。 |
| macOS | 默认安装为用户 LaunchAgent，登录后启动。若需在登录前提供查询，先由该用户执行 `service install`，再以管理员权限运行下方命令，将任务切换为以原用户运行的 LaunchDaemon。 |
| Windows | 使用任务计划程序的启动触发器，以安装用户的 S4U 身份运行，仅使用本机文件权限。注册开机触发器需要相应的管理员权限。 |

```sh
sudo /Applications/TokenMeter.app/Contents/MacOS/token-meter \
  --home "$HOME" --state "$HOME/.token-meter/node" service install-boot "$(id -un)"
```

系统级 Mac 任务可用同样的用户参数执行 `service status-boot USER` 或 `service uninstall-boot USER`。

常驻进程启动时和每六小时检查官方 GitHub 稳定发行版。发现较新版本后，它核对当前平台、GitHub 发行资产 SHA-256 和候选程序自检结果，再原子切换活动版本。监督进程启动新版本并保留前一版供启动失败时回退。`token-meter update` 可立即检查。`token-meter config auto-update false` 可关闭自动检查。`service uninstall` 停止并注销本用户的常驻任务，数据保存在原设备上。

## 连接两台设备

1. 一台设备打开「设备 → 添加设备 → 创建邀请」，或在终端运行 `token-meter pair`。邀请提供可复制的链接和 12 位配对码，桌面同时显示二维码。临时邀请有效期为十分钟。
2. 在另一台设备选择「输入配对码」并粘贴链接或配对码。命令行运行 `token-meter pair --join`，按提示粘贴配对码或链接。实现同一协议的手机可以扫描二维码。
3. 两边核对设备名、权限和校验码。双向同步需要两端同意。只读邀请（CLI 用 `token-meter pair --role viewer`）由可共享用量的设备授权。成功后设备身份保存在本机，后续自动重连。

即使双方都处在路由器后面，也可以通过各自的出站 HTTPS 连接配对。普通用户无需填写网关、端口、公钥或 IP。已有可达的私网地址时优先直连，直连不可用时通过公网中继转发端到端加密的连接。中继只保存临时会合信息，能看到连接的地址、时间和流量大小。用量副本保存在已授权的设备。[公网中继协议与部署](relay.md)

「设备」可解除本机的配对授权。命令行用 `token-meter peer list` 或 `token-meter peer list --json` 查看已授权设备，`token-meter peer remove ID` 撤销一台设备。撤销会阻止后续访问，对方已经收到的历史副本仍保存在其设备上。

`token-meter usage --via any` 向可读取的在线节点查询，当前端点不可达时尝试下一台。普通 `usage` 直接读本机副本。`usage --host ID --from YYYY-MM-DD --to YYYY-MM-DD --json` 可查询某台机器的日期范围。`local` 指实际响应请求的机器。

## 数据口径

- **OpenClaw** 读取 `agents/*/sessions/` 的活动会话、重置和删除归档（支持 Zstandard），以及 2.0 的 `agents/*/agent/openclaw-agent.sqlite`。迁移到 SQLite 后，`agents/*/session-sqlite-import-archive/` 保留的原会话可补齐历史。正式的会话压缩检查点也会保留主记录已经移除的请求。按供应商响应 ID 或原会话内的记录去重，同一请求优先使用 SQLite，其次是常规会话及其归档，最后采用检查点。计入未缓存输入、输出、缓存读写。优先采用来源记录的正数费用，否则尝试 TokenMeter 的模型价格，无法定价的请求单独计数。活动日志增量读取，归档在文件大小、修改时间或定价表变化时重新核算。[OpenClaw 会话存储](https://docs.openclaw.ai/reference/session-management-compaction/schema)
- **OpenClaw 历史保留** 已采集的请求保存在设备账本中。退役 Agent、轮转日志或压缩会话后，既有用量继续计入原来的日期。再次读到同一请求时按请求标识去重，来源对 Token 或费用的修订仍可上调或下调账目。
- **OpenClaw 消息投递** `delivery-mirror` 是写回会话的消息投递副本，用量统计排除这类事件。[OpenClaw 源码](https://github.com/openclaw/openclaw/blob/main/apps/android/app/src/main/java/ai/openclaw/app/chat/ChatModels.kt)
- **OpenClaw 调用 Codex 时**，一轮对话可以包含多次模型请求。设备服务从各 Agent 专属的 `agent/codex-home/sessions` 和 `archived_sessions` 读取逐次用量，按请求发生的日期、模型和上下文大小计价。缓存读取从总输入中拆出，推理 Token 已包含在输出中。同一请求出现在多份日志时只计一次。OpenClaw 的运行记录和聊天记录可能只保存该轮某一次请求的用量；逐次记录缺失时，只计能够核实的部分。轮次之间通过线程和轮次标识关联。同步到其他设备的仍是按日汇总。
- **Hermes Agent** 读取 `state.db` 以及 `profiles/*/state.db` 的 `session_model_usage`，按模型消耗计入并补足会话总账中尚未分配的差额。重扫覆盖已采集的累计值。Hermes 的这些计数按会话聚合，跨日会话归在开始日。已记录的实际费用优先于估算。[Hermes 官方统计实现](https://github.com/NousResearch/hermes-agent/blob/v0.23.4/agent/insights.py)
- **Linux 上的 Codex** 读取 `~/.codex/sessions/` 和 `~/.codex/archived_sessions/` 的独立 Codex 运行记录，包括 T3 Code 使用 Codex 时写入的记录。按实际请求日期与模型汇总，去重常规记录与归档副本。
- **Mac 已有 Agent** 由随应用分发的 `TokenMeterIndex` 使用原有采集器、开关和价格库写入本机账本。设备服务复用按日汇总。Windows 独立 CLI 可直接采集 OpenClaw 和 Hermes Agent。
- **账户额度** 来自供应商读数。OpenClaw 提供窗口时通过 `openclaw status --usage --json` 获取。各系统由 CLI 按本机配置查询账户并发布额度快照，退出菜单栏后继续运行。主动查询使用 `token-meter quota-refresh`，也可在命令后指定供应商 ID。桌面从后台快照显示读取时间、查询失败原因、剩余窗口及已报告的余额。没有上游窗口时仍可查看推理 Token、缓存及已知费用。多台机器使用同一个订阅时，在各机执行 `token-meter account PROVIDER SAME_ALIAS`，该账户显示最后一次读数。按设备区分未经关联的账户，积分按提供单位的供应商分开统计。
- **历史和隐私** 每台采集设备签署自己的完整日汇总与额度快照。对端只接受较新的有效签名版本，同一主机经多条路径抵达只计一次。同步字段包括来源设备、当地记账日、Agent、模型、Token、已知费用、缺失项和额度窗口。原始对话、文件路径、API Key、登录态保存在来源设备。每份原始 Agent 数据应指定一台采集设备，避免把同一个网络挂载当作两台机器各自的消耗。
- **同步时间** 「设备」页的「数据更新」是来源设备生成当前统计快照的时间。「最近联系」来自本机与直接配对设备最近一次成功同步或查询。用量未变化时，同一份快照可以在多次联系中复用。尚未复制的用量在恢复连接后补齐。为同一台机器恢复备份时保留整个 `~/.token-meter/node` 目录和正确的私有权限。克隆虚拟机时应给新机器生成自己的身份。

## 只读客户端

使用只读邀请授予查询权限。在 TLS 1.3 双向认证中以对端 Ed25519 公钥确认身份。`GET /v1/status` 返回响应节点身份与程序版本。`GET /v1/usage` 接受 `host`、`from`、`to` 参数。只有完整配对的 peer 可以访问 `/v1/versions` 和 `/v1/snapshots/<origin>` 做转发。只读客户端可以查看授权节点保存的全网汇总。要在多台主机之间自动切换，需要分别获得各主机的读取授权。

手机等新客户端可按[设备配对协议](device-pairing.md)实现同一套邀请与权限确认。
