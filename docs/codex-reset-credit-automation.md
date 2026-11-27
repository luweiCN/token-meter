# Codex 重置卡到期前自动使用

在「设置 → 供应商额度接入 → Codex」可以开启「重置卡到期前自动使用」。默认关闭。开启后，该设备的 TokenMeter 后台服务会尝试使用一小时内到期的卡。是否存在可以重置的额度窗口，由 Codex 决定。[官方重置卡接口](https://learn.chatgpt.com/docs/app-server#8-earned-rate-limit-resets-chatgpt)

## 何时执行

常驻的 `token-meter` 在启动后和每分钟检查一次。关闭 Mac 菜单栏窗口或退出图形应用后，只要后台服务仍在运行，它就会继续检查。后台服务停止、设备关机或断网时，要等到服务和网络恢复才能重新检查。已过期的卡会跳过。

后台服务读取这台设备的 Codex 接入开关、扫描暂停状态和自动使用开关。检查时和请求发出前均核对授权。关闭开关会阻止后续兑换，已发出的请求可能由服务端完成。设置页显示该设备后台服务最近一次的检查结果。

## 选择和使用一张卡

CLI 通过本机 Codex 的标准输入输出连接 `app-server`。`account/read` 使用 `refreshToken: false`。`account/rateLimits/read` 同时返回额度、账户积分及可用卡数。卡片列表有时只含部分明细，显示数量以 `availableCount` 为准。[官方账户额度接口](https://learn.chatgpt.com/docs/app-server#6-rate-limits-chatgpt)

1. 用本机登录状态确定账户身份，只依据本轮读取的卡片明细选择目标。有效卡必须有 ID、类型为 `codexRateLimits`、状态为 `available`，并满足 `0 < expiresAt - now <= 3600` 秒。每次选到期最早的一张。
2. 在本机 SQLite 的 `codex_reset_redemptions` 表中原子登记此次尝试。记录包含账户与卡片指纹、幂等键和处理状态。已完成的尝试跨服务重启保留，原始卡号仅在内存中使用。
3. 核对本机 Codex 生成的接口定义是否支持 `creditId` 和 `idempotencyKey`，再读取账户和卡的最新状态。账户一致、卡仍符合条件且自动使用仍已开启时，才向 `account/rateLimitResetCredit/consume` 发送这张卡的 ID 和已登记的幂等键。
4. 先保存服务端返回的兑换结果。成功后，CLI 重新读取服务端的卡数和额度，菜单栏从最新快照显示。

| 结果 | 后续处理 |
| --- | --- |
| `reset` 或 `alreadyRedeemed` | 记为成功并刷新额度。即使刷新失败，此次兑换也已完成。 |
| `nothingToReset` | 等额度状态发生变化后，在卡仍符合条件时重新评估。 |
| `noCredit` | 记为该卡不可用。 |
| 超时、断线或未确认 | 保留原卡和幂等键，等待下次核对，避免重复消费。 |

兑换逻辑测试使用模拟 Codex 服务和隔离账本，覆盖时间边界、登录账户变化、旧版 CLI、取消、并发领取和不确定结果重试。[实现与回归测试](../internal/account/codex_test.go)
