# Command Code 订阅额度接入

## 目标与边界

TokenMeter 直接使用 Command Code Studio 生成的 API Key 读取订阅额度，不要求安装或登录 Command Code CLI。只接入订阅额度，不新增本地会话扫描、模型计费或 CLI 生命周期管理。

## 鉴权

凭证只允许进入 Swift 进程，优先级固定为：

1. TokenMeter 设置页写入的 macOS 钥匙串项（account = `command-code`）。
2. `COMMAND_CODE_API_KEY`；菜单栏 App 未继承环境时，沿用登录 shell 回退读取。
3. `~/.commandcode/auth.json` 的 `apiKey`，仅作为已安装 CLI 用户的兼容入口。

请求使用 `Authorization: Bearer <key>`。Electron renderer 不持久化、不回读、不记录明文 Key。

## 接口与数据模型

基址固定为 `https://api.commandcode.ai`。先请求 `/alpha/whoami` 取得组织 ID，再读取：

- `/alpha/billing/credits?orgId=…`：服务端直接返回 5 小时与 7 天窗口的 `used`、`cap`、`resetAt`。
- `/alpha/billing/subscriptions?orgId=…`：返回套餐 ID、状态和当前月周期结束时间。

5h/7d 百分比只用服务端的 `used / cap` 计算。月窗口的响应只给余额，因此月上限以 `CommandCodeUsageParser` 的套餐映射为唯一真相源；只有已知且 active 的套餐才显示 30d。未知套餐继续显示 5h/7d，不猜测月额度。

订阅请求失败不应拖掉仍可用的 5h/7d；credits 请求或解析失败则返回 provider 错误。ProviderStore 继续保留最近一次成功快照，因此一次临时失败只在弹窗展示错误与数据年龄，菜单栏保持原值。

## 用户界面

- 设置页提供 Command Code API Key 密码输入框与钥匙串保存/清除操作，并明确标注“不依赖 Command Code CLI”；写入成功后异步触发一次立即刷新，不阻塞保存反馈。
- 菜单栏外观页提供 Command Code 的 5h、7d、30d 独立窗口选择。
- 无有效 Key 时给出设置页与 `COMMAND_CODE_API_KEY` 两种可操作提示。

## 安全与兼容性

- endpoint 必须是 HTTPS；网络请求 10 秒超时。
- 401/403 只显示 Key 无效或过期，不回显响应体或凭证。
- `/alpha/billing/*` 是当前 Command Code CLI 使用的额度接口，并非公开稳定契约；字段或套餐变化时必须先更新解析测试和套餐映射，不能静默推断。

## 参考

- [Command Code Studio](https://commandcode.ai/docs/studio)：API Key 的生成与复用。
- [Provider API](https://commandcode.ai/docs/provider)：Bearer API Key 鉴权。
- [Usage & Limits](https://commandcode.ai/docs/resources/usage-limits)：5 小时、周、月额度口径。
