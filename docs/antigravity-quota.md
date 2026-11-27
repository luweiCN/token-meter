# Antigravity 订阅额度

先在官方 `agy` 登录，在 TokenMeter 设置中启用 Antigravity。账户额度卡显示 **AGY**，Agent 用量列表显示 **Antigravity CLI**。macOS、Linux 和 Windows 的 TokenMeter CLI 都从官方结构化状态栏读取额度。打开 Mac 菜单时直接显示后台的最近读数。[Google 状态栏协议](https://antigravity.google/docs/cli/statusline/)

## 刷新

常驻的 TokenMeter CLI 按账户刷新间隔采集。最近五分钟已有读数时会复用它。在额度卡点击刷新，或运行 `token-meter quota-refresh antigravity`，可以立即查询。正在使用的 Antigravity CLI 也会推送状态变化。暂停采集会暂停定时查询。

后台查询仅短暂启动 `agy`，在不可见终端读取额度，然后结束进程。查询复用当前用户已登录的会话，采用官方远程终端登录模式，并在 macOS 上限制系统浏览器启动。TokenMeter 不提供登录输入，也不发送模型请求。首次使用或 Google 已使登录失效时，需要自行在终端登录。地区、账号资格、网络续期与超时各有对应提示。[Google 登录及 SSH 说明](https://antigravity.google/docs/install?tab=cli)

查询失败时，额度卡保留仍有效的窗口和上次观测时间。没有已知重置时间的窗口会显示余量。超过已知重置时间的窗口会在新数据到达后重新显示。官方会话报告正在认证时会清空上一个会话的额度。

## 额度口径

标题的 `5h` 和 `7d` 表示 Gemini 的 5 小时与每周剩余额度，展开后可查看 Claude/GPT 共用窗口和模型专属窗口。各项窗口并行约束请求，百分比不能相加。官方仅给出剩余数量时，卡片显示该数量。[官方 /usage 说明](https://antigravity.google/docs/cli/commands/usage)

Token 用量单独从本地会话索引计算。模型和任务量影响订阅额度消耗，额外 Google AI 积分由 Google 账号的超额设置决定。`agy` 的 `/credits` 可查看上游提供的积分信息。[套餐规则](https://antigravity.google/docs/plans) · [积分查询](https://antigravity.google/docs/cli/commands/credits) · [本地数据源契约](data-source-contracts.md#antigravity-cli)

## 终端状态栏

TokenMeter 将采集入口写入 `~/.gemini/antigravity-cli/settings.json` 的 `statusLine`。默认状态栏继续显示。已有自定义命令会收到完整原始输入，终端显示它的输出。TokenMeter 的私有缓存仅保存额度窗口和观测时间。

关闭接入会恢复原状态栏并清除该账户的本机额度快照。如果用户自行替换状态栏命令，关闭接入时保留用户新命令。
