# 模型定价与成本计算

TokenMeter 保留来源上报的 Token 和 USD 成本；需要本地换算时，由 `CostCalculator` 使用当前生效价格。计算结果是对应模型牌价下的 Token 成本，不等同于订阅费、Credits、工具调用费或账户实际付款。

## 价格来源与规则

`scripts/update-pricing.sh` 从 [LiteLLM 价格数据](https://github.com/BerriAI/litellm/blob/main/model_prices_and_context_window.json)生成快照，`scripts/pricing-overrides.json` 保存有出处的人工补充。生成与读取契约由 `scripts/test_transform_pricing.py` 和 Swift 定价测试共同验证。

- 基础输入、输出价必须完整；缓存读、5 分钟写、1 小时写各自保存单价。`null` 或缺失表示未知，`0` 表示免费。不能套用其他模型的缓存折扣，也不把缺失价当成零。
- `longContext` 是按 `thresholdTokens` 严格递增的列表，每档拥有独立费率。按单次请求的普通输入、缓存读取、缓存写入之和选档，不包含输出或 reasoning 的重复计数。严格超过阈值后切档，并将该档费率用于整次请求。`K` 使用 1,000 Token。
- Standard 与 Fast 的费率分别保存，Fast 档位取对应 Priority 字段；缺失的 Fast 缓存价不借用 Standard 缓存价。
- `tiered` 表达已有的生效时间、工作日、节假日及峰谷时段规则。上下文档位与峰谷规则同时存在但没有组合费率表时拒绝该配置，不猜测优先级或倍率。
- 单价缺失仅在请求实际消耗该类 Token 时使成本变为未知；零用量不需要该项价格。已上报成本的采信、峰谷价优先及 `ignoreReported` 语义由现有计价器统一处理。

上下文选档依据见[阿里云分档规则](https://www.alibabacloud.com/help/en/model-studio/model-pricing#tiered-pricing-rules)。缓存费用应分别核对[阿里云缓存规则](https://www.alibabacloud.com/help/en/model-studio/context-cache)及 [Claude 价卡](https://platform.claude.com/docs/en/about-claude/pricing)，不能使用跨厂商统一比例。上游明确给出的 OpenAI 同档缓存写入价复用于两种 TTL，已有独立 1 小时价时仍优先使用独立价。

定价键的供应商前缀与用量模型名使用不同归一规则：第三方托管价不能冒充同名官方价。匹配规则以 `CostCalculator.pricingKeyCanonical` 为准；保留在上游快照中的键不代表它一定参与官方模型的本地计价。

## 快照与兼容

当前格式由 `PricingSnapshot.currentSchemaVersion` 定义。`schemaVersion` 描述格式，`snapshotVersion` 是模型价格内容哈希。客户端拒绝未知格式版本及非法费率、重复或乱序阈值。

```json
{
  "schemaVersion": 2,
  "snapshotVersion": "内容哈希",
  "source": "litellm",
  "models": {
    "example-model": {
      "inputPerMTok": 1,
      "outputPerMTok": 2,
      "cacheReadPerMTok": 0.2,
      "cacheWrite5mPerMTok": null,
      "cacheWrite1hPerMTok": null,
      "longContext": [
        {"thresholdTokens": 32000, "rate": {"inputPerMTok": 2, "outputPerMTok": 4, "cacheReadPerMTok": 0.4}},
        {"thresholdTokens": 256000, "rate": {"inputPerMTok": 4, "outputPerMTok": 8, "cacheReadPerMTok": 0.8}}
      ]
    }
  }
}
```

读取旧缓存和用户配置时，旧 `longContext` 单对象转换为单元素列表；内部计算和新写入只有列表格式。未知缓存单价保持可空，不补造历史价格。

CI 按快照格式发布 `litellm-pricing-v2.json` 与对应 SHA-256 文件；应用运行时每小时核对相应格式的校验和，缓存缺失或内容变化时下载并验证完整快照，失败后 15 分钟重试。本地缓存和下载检查时间也按格式隔离。升级时优先使用新版随包快照，旧缓存不覆盖新版价格。旧的无版本资产保留最后一份兼容快照，不覆盖为新格式，旧客户端需要升级才能获取后续价格。旧资产和单对象解码只服务旧客户端及旧配置迁移；结束其兼容支持并迁移旧缓存、用户配置后可一并移除。

## 自定义价格与历史统计

`~/.token-meter/custom-pricing.json` 的条目继承当前快照中省略的字段；显式给出的 `longContext` 替换整份档位列表，`[]` 关闭上下文分档。无基础输入/输出价或规则非法的覆盖不生效，免费的自定义模型可以明确使用全零单价。

价格文件变化后，扫描器通过包含全部档位的逐模型指纹识别变化，只对实际使用且价格变化的模型重算成本，再重建汇总。Token 原始事实与供应商原始上报金额保留。历史本地成本按当前生效价重算；快照没有记录全部厂商历史牌价，不能据此还原历史账单。

`model_pricing` 是派生目录，未知缓存价格保存为 SQL `NULL`。格式升级沿用 `TokenMeterDatabaseMigrator` 的派生表重建契约，配置与不可重建记录保留；安装新版后首次启动需要完成一次重新扫描。正常每日价格更新走模型指纹对账，不触发数据库格式重建。
