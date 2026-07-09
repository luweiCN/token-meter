#!/usr/bin/env python3
"""把 LiteLLM 的定价表转成 TokenMeter 的快照格式。

LiteLLM 的价格是「每 token 美元」，输出改成「每百万 token 美元」。
LiteLLM 未显式给出 cache 费率时按 ccgauge 已验证的默认值派生。
从 stdin 读 LiteLLM JSON，往 stdout 写快照 JSON。
"""
import json
import sys
from datetime import date

# 注意：LiteLLM 已把智谱的 provider slug 从 zhipuai 改成 zai。
# 写成 zhipuai 会让 glm-4.6 等模型一条定价都拿不到，成本静默变成 unknown。
KEEP_PROVIDERS = {"anthropic", "openai", "vertex_ai-anthropic_models", "bedrock", "zai"}
M = 1_000_000


def main() -> None:
    raw = json.load(sys.stdin)
    models = {}

    for name, spec in raw.items():
        if name == "sample_spec" or not isinstance(spec, dict):
            continue
        if spec.get("mode") != "chat":
            continue
        if spec.get("litellm_provider") not in KEEP_PROVIDERS:
            continue

        input_cost = spec.get("input_cost_per_token")
        output_cost = spec.get("output_cost_per_token")
        if not input_cost or not output_cost:
            continue

        input_m = input_cost * M
        output_m = output_cost * M
        cache_read = spec.get("cache_read_input_token_cost")
        cache_write = spec.get("cache_creation_input_token_cost")
        # LiteLLM 有 113 个模型给出了真实的 1h 缓存写入价，用它。
        # 别硬编码 input*2：claude-3-opus 的实际比值是 0.40，claude-3-haiku 是 24.00。
        cache_write_1h = spec.get("cache_creation_input_token_cost_above_1hr")

        # 必须用 `is not None` 而不是真值判断。
        # LiteLLM 把「免费」显式写成 0（glm 全系列的 cache_creation 都是 0），
        # `if cache_write` 会把这个 0 当成「字段缺失」，进而按 input*1.25 给免费的东西收费。
        # 「免费」和「不知道」是两件事，正如 cost_usd_micros 用 NULL 而不是 0。
        models[name] = {
            "inputPerMTok": round(input_m, 6),
            "outputPerMTok": round(output_m, 6),
            "cacheReadPerMTok": round(cache_read * M if cache_read is not None else input_m * 0.1, 6),
            "cacheWrite5mPerMTok": round(cache_write * M if cache_write is not None else input_m * 1.25, 6),
            "cacheWrite1hPerMTok": round(cache_write_1h * M if cache_write_1h is not None else input_m * 2.0, 6),
        }

    json.dump(
        {"snapshotVersion": date.today().isoformat(), "source": "litellm", "models": models},
        sys.stdout,
        indent=2,
        sort_keys=True,
    )
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
