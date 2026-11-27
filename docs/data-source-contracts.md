# 本地数据源契约与验证边界

本文是 TokenMeter 对本地 agent 数据的权威口径。实现只消费这里列出的、已能说明语义与去重关系的字段；文件或字段不存在时不猜测。详细供应商文案仍以产品官方文档为准。

OpenClaw 和 Hermes Agent 由跨平台设备服务采集，来源及记账口径见[设备与命令行](device-sync.md#数据口径)。

## 共同口径

- TokenMeter 只读来源文件和来源 SQLite；`~/.token-meter/tokenmeter.sqlite` 是可删除重建的派生库。
- `tokens_reported` 区分“明确上报 0”和“未提供 Token”。后者在 UI 显示 `—` 或带 `†` 的不完整合计，成本也保持未知。
- Credits 以整数 `credits_picos`（`1 Credit = 10^12 picos`）保存，跨 Swift/SQLite/Electron 时以整数或十进制文本传递，避免 JavaScript `Number` 精度损失。
- Credits 是供应商自己的资源单位，不等同 USD；只按 `provider_id` 汇总，禁止跨供应商相加或换算成美元。
- 同一请求同时出现“逐请求值”和“会话累计值”时只采用逐请求值。累计值不能再次求和。

## 支持与验证状态

| 产品 | 会话 / Token | 成本 | Credits / 额度 | 验证边界 |
|---|---|---|---|---|
| Antigravity CLI | 按本机会话库逐次生成统计 | 匹配模型价格后估算 | AGY 订阅窗口单独查询 | 已与本机有用量的 CLI 会话明细核对 |
| Gemini CLI | 读取旧版 JSON 及新版 JSONL 会话 | 匹配模型价格后估算 | 此来源只记录会话用量 | 已与本机两种格式的历史记录核对 |
| 千问 Code | 支持 | 有 Token 和模型时按本地价格表计算；无供应商上报 USD | 未发现可靠额度接口 | 已核对本机 `@qwen-code/qwen-code` 0.24.0 的实现与本地目录；本机现有会话没有非零 Token 事件 |
| Qoder CLI | 来源上报时支持；当前 Qwen3.8-Max 实测未提供可用 Token | 有 Token 和模型时按本地价格表计算；Token 未上报时成本未知 | 支持逐请求 Credits 与账户套餐/加购额度 | 已用本机 CLI 1.1.58、真实会话和官方 SDK 契约核对 |
| Qoder Desktop | 与 CLI 共用会话文件，Token 边界相同 | 同 Qoder CLI | 支持逐请求 Credits；账户额度由 Qoder CLI 官方控制接口读取 | 已核对桌面端 SQLite 的会话归属关系 |
| 腾讯云 WorkBuddy | 按官方 macOS 包内契约实现 | 有 Token 和模型时按本地价格表计算 | 支持已实际发生的逐请求 Credits | 仅核对腾讯官方签名包 5.5.6；当前机器没有安装、登录和真实会话，仍需首次使用后的运行时复核 |
| 豆包工作 | **未实现** | **未实现** | **未实现** | 当前机器没有安装和真实会话；官方包中未找到可证明为 LLM 请求 Token/成本的稳定本地账本或个人用量导出接口 |

## Antigravity CLI

TokenMeter 只读 `~/.gemini/antigravity-cli/conversations/<会话 ID>.db` 及其已提交的 WAL。每个 `gen_metadata` 条目是一轮生成，按响应 ID 去重。没有响应 ID 的记录按会话内的生成序号区分。步骤元数据提供响应时间，旧格式可提供生成时间。订阅额度刷新和初始化留下的无用量记录会被跳过。CLI 可以在编辑器关闭时采集，聊天正文不写入 TokenMeter。[Tokscale 的会话库解析](https://github.com/junhoyeo/tokscale/blob/b265e836c58f085f50a836525aa60b8d45bd8d57/crates/tokscale-core/src/sessions/antigravity_cli.rs)

菜单栏的会话数只计当天有用量、用户可见的主会话。TokenMeter 按扫描来源读取该配置目录的 `cache/conversation_metadata.json`，用 `is_internal` 识别内部会话，再用 `conversation_summaries.db` 的父会话和嵌套深度识别子会话。已有账本可以直接使用这两份索引。当天存在无法分类的会话时，菜单隐藏会话数。Token、费用和缓存命中率仍包含所有已采集的生成记录。

生成元数据分别提供未缓存输入、缓存读取、缓存写入和总输出。推理是总输出的一部分。缺少缓存写入期限时，沿用账本的默认缓存写入项。内部路由 ID 与 Google 返回的模型展示名吻合时，可用公开模型价格估算；无法匹配时费用保持未知。套餐的实际积分消耗由 Google 决定。[Google API 价格](https://aistudio.google.com/docs/pricing)

## Gemini CLI

从 `~/.gemini/tmp/<项目>/chats/` 读取旧版 JSON 和新版 JSONL 会话。子代理日志位于完整父会话 ID 对应的子目录。同一消息可在生成、补写用量和工具完成时多次出现。按会话与消息 ID 采用最后一次有用量的记录。历史重放、聊天快照以及缺少用量的登录提示都不会增加 Token。[官方会话说明](https://geminicli.com/docs/cli/session-management/) · [Google 的记录格式](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingTypes.ts)

`cached` 包含在 `input` 中，`thoughts` 与 `output` 分开上报。TokenMeter 将缓存从输入拆出，把思考计入输出一次，并按 `total` 对齐工具提示所用的输入 Token。设置中的两个 CLI 开关分别控制其本地采集。

## 千问 Code

来源（`QWEN_HOME` 默认 `~/.qwen`；`QWEN_RUNTIME_DIR` 未设置时等于 `QWEN_HOME`）：

- 会话：`$QWEN_RUNTIME_DIR/projects/<encoded-project>/chats/<session-id>.jsonl`
- 月度逐请求账本：`$QWEN_RUNTIME_DIR/usage/token-usage-YYYY-MM.jsonl`
- 会话汇总：`$QWEN_HOME/usage_record.jsonl`

同一用量会投影到三处，固定优先级为“会话 telemetry → 月度逐请求账本 → 会话汇总”。一旦某个会话在更高优先级来源中有请求级事件，就不再叠加较低优先级投影。

- 会话事件只读 `systemPayload.uiEvent` 中 `event.name = qwen-code.api_response` 的记录；使用 `response_id`，其次 `prompt_id + timestamp`，最后稳定字段指纹去重。
- 月度账本按记录 `id` 去重。
- 汇总只在没有请求级记录时按“会话 × 模型”产生兜底事件。
- `cached_content_token_count` 从输入中拆为缓存读取；`thoughts_token_count` 保留为推理明细，但不在 TokenMeter 总量中重复相加。优先服从来源的 `total_token_count / totalTokens`；该值缺失时，按 Qwen 0.24.0 自身规则处理 `openai`、`qwen-oauth`（思考已含在输出中）与其他认证类型（思考另计）。
- 整个来源集合的内容版本参与增量判定；任一投影变化时重新合成，避免只更新账本却漏扫。
- 默认根同时保存 runtime 与 home 两个位置；因此显式设置 `QWEN_RUNTIME_DIR` 时也不会漏掉仍写在 `QWEN_HOME` 的会话汇总。

Qwen Code 官方也说明跨会话统计会写入 `~/.qwen/usage_record.jsonl`：[Qwen Code `/stats` 更新说明](https://qwenlm.github.io/qwen-code-docs/en/blog/updates/weekly-update-2026-06-11/)。该文件是汇总兜底，不是逐请求真相源。
`QWEN_HOME` 与 `QWEN_RUNTIME_DIR` 的覆盖语义见官方[配置文档](https://qwenlm.github.io/qwen-code-docs/en/users/configuration/settings/)；TokenMeter 在扫描根中分别保存两者，不假定它们必然相同。

## Qoder CLI 与 Qoder Desktop

来源：

- 共享会话：`~/.qoder-cn/projects/**/*.jsonl`
- Desktop 归属：`~/Library/Application Support/com.qodercn.app.stable/main.sqlite` 的 `chat_sessions.session_id`

CLI 与 Desktop 不复制两套日志。若会话 ID 出现在 Desktop 的 `chat_sessions`，供应商记为 `qoder-desktop`；否则记为 `qoder-cli`。归属集合有独立内容版本，因此即使 JSONL 没变，Desktop 后续接管会话也会触发重新归属。

请求事件来自 assistant message 的 `usage`：

- Token：`input_tokens`、`output_tokens`、`cache_read_input_tokens`、`cache_creation_input_tokens` 或 `cache_creation` 分层字段。
- Credits：`credits` 是优惠后的逐请求实际值；`original_credits` 是优惠前值；`billable` 表示是否计入额度。
- 身份：优先 `usage.request_id`，其次 message ID。字段缺失与数值 0 严格区分。
- `result.total_credits` 和按模型累计值是同一会话的累计投影，不能与逐请求 `credits` 相加，因此不进入事件表。
- 本机 CLI 1.1.58 的真实 Qwen3.8-Max 语料在 assistant message、内部 `model.response.completed` 事件和会话诊断分段三处都保留 Token 字段但全部写 0，同一请求同时给出正数 `credits / original_credits`。这表示当前来源没有提供可用 Token，而不是实际消耗为 0：`tokens_reported = 0`，界面显示未上报，USD 成本保持未知。Credits 与 Token 没有官方固定换算率，禁止反推、估算或把该请求显示为“免费”。
- 模型日志里的 `message.model` 是稳定原始身份，原样归一后写入 `usage_events`。展示名来自 Qoder CLI `initialize` 控制响应的服务端模型目录（与 SDK `getAvailableModels()` 的 `value / modelId / displayName` 同源），按 `provider_id + model_canonical` 缓存到 `model_catalog`；模型页、会话栏等展示入口都从该目录投影。目录缺失、冲突或读取失败时回退原始 ID，不硬编码、不猜名称，也不改写历史聚合键。
- 模型页同时展示 Token、供应商内 Credits 与 USD 成本：Credits 按供应商分行，绝不跨供应商求和；全零 Token 仍显示来源上报的 `0`，正数 Credits 单独显示；全部事件价格未知时成本显示“未知”，不再显示成零元。

以上字段含义和去重关系与 Qoder 官方说明一致：[Cost and usage](https://docs.qoder.com/cli/sdk/cost-usage)。

账户额度通过 Qoder CLI 官方控制协议读取：启动无持久化的 `stream-json` 会话，依次发送 `initialize` 和 `get_usage_info`。展示 `userQuota`（套餐）、`addOnQuota`（加购）及可选 `orgResourcePackage`（组织共享包）的 `total / cap / used / remaining / percentage / unit`，并读取 `isQuotaExceeded`。响应中的毫秒 Unix 时间戳 `expiresAt` 按官方定义是当前套餐/额度的到期时间，不是 Credits 刷新时间，因此不放进额度环的重置倒计时；接口未提供可靠刷新时刻时保持为空。比例优先由 `used / total`（组织包为 `used / cap`）计算，以免瞬时不一致的冗余字段影响展示。对应官方接口见 [Qoder SDK usage reference](https://docs.qoder.com/cli/sdk/references-python) 和 [CLI Usage Panel](https://docs.qoder.com/cli/usage)。

`status = warning` 可以是一次成功的业务响应（例如 `isQuotaExceeded = true`），不能据此判定刷新失败。缓存只在本轮没有有效额度数字且状态非 `ok` 时回退旧快照；成功返回的用尽额度保留本轮 `fetchedAt`。弹窗把套餐与加购作为两个主额度圆环展示；圆环已表达剩余百分比，卡内文字只显示“已用 / 总额”，空间足够时保持单行、不足时才换行。第三项及次要组仍使用条形；没有官方刷新时间窗的额度不会伪造成菜单栏时间窗或倒计时。

额度查询不会发送用户 prompt，并带 `--no-session-persistence --tools ''`；但 Qoder 初始化本身仍可能执行用户配置的 `SessionStart` hooks，也会使用登录态请求 Qoder 服务。禁用 Qoder 额度供应商即可完全停止该查询。

Desktop 数据库优先通过 SQLite 只读连接读取，包含已提交但尚未 checkpoint 的 WAL。桌面端关闭后只剩已 checkpoint 的主库时，可从它的临时只读快照取得归属。Desktop 数据库不存在时按“没有可见 Desktop 归属”处理；路径已存在但数据库无法读取时，本轮 Qoder 扫描失败并保留旧派生数据，不把未知归属猜成 CLI。

## 腾讯云 WorkBuddy

来源契约来自腾讯官网下载、Apple 签名有效的 macOS 包（5.5.6，Team ID `FN2V63AD2J`）：

- 会话：`~/.workbuddy/projects/**/*.jsonl`
- 数据库：`~/.workbuddy/workbuddy.db`
- Credit 兜底表：`session_usage(session_id, used, size, updated_at, credit_json)`

`session_usage.used / size` 与 ACP `usage_update.used / size` 表示当前上下文占用快照，不是历史请求消耗，不能跨事件相加。可加总的 Token 只来自请求级 `_meta.usage`、`providerData.usage.details` 或 `providerData.rawUsage` 明细。

- 请求身份优先读取 `_meta["codebuddy.ai/requestId"]`，并兼容已持久化投影中的 `conversationRequestId`、扁平或嵌套 `requestId`；record/message ID 只用于同一请求内的 Credit 阶段去重。
- 同一请求的最后一份 Token 快照胜出；缓存 Token 从 prompt 中扣除，推理 Token 视为输出子集。
- Credit 只读已实际发生的 `cost.amount` 或 `providerData.rawUsage.credit`；`estimatedCost` 不入账。
- 同一请求的 Credit 阶段按 record/message ID 去重后相加。数据库 `credit_json` 是“请求 ID → 已累计实际 Credit”，只补 JSONL 尚无实际 Credit 的请求，不与 JSONL 重复相加。
- 形如 `req-<纯数字>` 的 UI 乐观占位 ID 不作为数据库 Credit 事实。
- `credit_json` 内容与行级 `updated_at` 参与增量判定；数据库单独更新时也会重放对应 JSONL。只有数据库里存在的 Credit 请求以该行更新时间作为“已观察到”时间，不能把它解释成供应商提供的精确请求时间。
- `workbuddy.db` 不存在时仍可消费 JSONL；路径已存在但数据库无法读取时，本轮扫描失败，不静默漏掉可能只存在于 `credit_json` 的实际 Credits。

腾讯官方产品入口为 [Tencent WorkBuddy](https://cloud.tencent.com/product/workbuddy)。由于当前开发机没有安装、登录或生成真实 WorkBuddy 会话，上述支持属于“官方包契约已实现、真实运行数据待复核”；UI 不会把缺失 Token 显示成 0。

## 豆包工作：当前阻塞

已核对 [豆包工作官方入口](https://www.doubao.com/work) 提供的 macOS ARM64 2.30.3 包；应用签名主体为 Beijing Chuntian Zhiyun Technology Co., Ltd.，Team ID `96L78H6LMH`。包内能找到 `Application Support/DoubaoWork`、`~/.doubaowork/agent_mode/workspace` 和若干会话 API 线索，但这些只能证明候选存储位置，不能证明真实运行时会写入什么。

目前缺少以下至少一项可交叉验证的事实：

1. 登录并完成真实任务后的本地会话样本；
2. 带明确字段语义的官方个人用量 / 导出接口；
3. 能稳定关联到请求 ID 的 Token、模型、成本或实际额度字段。

网页和包内出现的 commerce credits 用于图片、视频等内容权益，不能据此冒充 LLM Token 或会话成本。因此 TokenMeter 不注册豆包 provider、不创建猜测扫描根，也不拿 CodeBuddy、Zaly 等其他产品替代。获得真实样本后，应先验证路径、schema、请求级/累计级关系与删除/重试行为，再接入同一事件架构。

## 验收不变量

- 同一原始请求最多生成一条 Token 事件；累计投影不与请求事件叠加。
- 来源明确上报 0 时保留 0；来源没字段时标记未上报。
- 来源数据库均用 SQLite read-only 模式打开，不创建 WAL、不修改用户数据。
- 供应商归属、外部 Credit 表或重叠账本变化时，增量扫描必须失效并重新合成。
- 任一新字段只有在真实样本与字段语义同时成立后才能进入生产解析器。
