# Antigravity 订阅额度

登录官方 `agy` 后，在 TokenMeter 设置中开启 Antigravity。菜单栏的「Agent」列表显示 **Antigravity CLI**，账户额度卡使用简称 **AGY**。TokenMeter 在后台短暂启动官方 CLI，从它的结构化状态栏读取本次返回的额度，读完即退出。刷新不打开窗口、创建对话或发送模型请求。你正在使用 CLI 时，其状态栏也会主动推送额度。[官方状态栏协议](https://antigravity.google/docs/cli/statusline/)

开启、定时检查和 Mac 唤醒时都会检查快照，距离成功观测满 5 分钟才发起后台查询。自动尝试至少间隔 5 分钟。暂停扫描会暂停查询。

右键 AGY 标题可立即刷新。失败时，展开卡片可看到具体原因以及「重试」按钮。Google 只返回余量时，窗口显示百分比，倒计时留空。已知重置时间确实过去的窗口，等下一次成功查询再显示。

手动刷新和定时刷新都由官方 CLI 复用 macOS 钥匙串中的登录。访问令牌到期时，CLI 会自动续期。如果连接 Google 续期服务失败，TokenMeter 会等待重试。后台查询禁止打开浏览器。只有 Google 授权失效或首次使用时，才需要你在终端打开 `agy` 并完成登录。[官方登录说明](https://antigravity.google/docs/cli/install/)

菜单内的「刷新额度」和「重试」均在后台执行。查询失败时保留有效期内的读数。收到新的额度数据后，卡片会立即清除之前的刷新错误。

标题的 `5h` 和 `7d` 显示 Gemini 的 5 小时及每周剩余百分比。展开后的横条分别显示 Claude/GPT 共用的 5 小时及每周额度，以及 Google 单独返回的模型窗口（例如 Argon WTU 周额度）。不同窗口可能同时约束一次请求，各项余量不能相加。[官方 /usage 说明](https://antigravity.google/docs/cli/commands/usage)

模型和任务工作量会影响额度消耗。套餐基础额度用完后，能否使用额外 Google AI 积分取决于账号的超额设置。积分余额可在 `agy` 输入 `/credits` 查看。账户额度卡显示窗口、余量、重置时间和观测时间。CLI 模型用量由本地扫描器采集，可在菜单栏的「AGENT」和主窗口查看。[套餐规则](https://antigravity.google/docs/plans) · [积分查询](https://antigravity.google/docs/cli/commands/credits)

TokenMeter 将采集命令接入 `~/.gemini/antigravity-cli/settings.json` 的 `statusLine`。默认终端状态栏仍然显示。已有自定义命令会收到原始输入并继续输出。关闭接入后，TokenMeter 会还原原配置并清除本地额度快照。

CLI 的计数、去重与估价规则见[本地数据源契约](data-source-contracts.md#antigravity-cli)。
