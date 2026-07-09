#!/usr/bin/env python3
"""把 LiteLLM 的定价表转成 TokenMeter 的快照格式。

LiteLLM 的价格是「每 token 美元」，输出改成「每百万 token 美元」。
从 stdin 读 LiteLLM JSON，往 stdout 写快照 JSON。
"""
import hashlib
import json
import sys

# 注意：LiteLLM 已把智谱的 provider slug 从 zhipuai 改成 zai。
# 写成 zhipuai 会让 glm-4.6 等模型一条定价都拿不到，成本静默变成 unknown。
KEEP_PROVIDERS = {"anthropic", "openai", "vertex_ai-anthropic_models", "bedrock", "zai"}
M = 1_000_000


def should_keep(name: str, spec: object) -> bool:
    if name == "sample_spec" or not isinstance(spec, dict):
        return False
    if spec.get("mode") != "chat":
        return False
    if spec.get("litellm_provider") not in KEEP_PROVIDERS:
        return False
    # 没有基础价格的条目无从计价；跳过它们，让成本落到 unknown 而不是 0
    return bool(spec.get("input_cost_per_token")) and bool(spec.get("output_cost_per_token"))


def rate(published: float | None, fallback: float) -> float:
    """published 为 None 表示 LiteLLM 没说，回落到派生值。

    必须用 `is not None` 而不是真值判断：LiteLLM 把「免费」显式写成 0
    （glm 全系列的 cache_creation 都是 0）。把那个 0 当成「缺失」会给免费的
    东西按派生公式收费。「免费」和「不知道」是两件事。
    """
    return round(published * M if published is not None else fallback, 6)


def convert_model(spec: dict) -> dict:
    input_m = spec["input_cost_per_token"] * M
    output_m = spec["output_cost_per_token"] * M
    return {
        "inputPerMTok": round(input_m, 6),
        "outputPerMTok": round(output_m, 6),
        "cacheReadPerMTok": rate(spec.get("cache_read_input_token_cost"), input_m * 0.1),
        "cacheWrite5mPerMTok": rate(spec.get("cache_creation_input_token_cost"), input_m * 1.25),
        # LiteLLM 给了真实的 1h 缓存写入价就用它。别硬编码 input*2：
        # claude-3-opus 的实际比值是 0.40，claude-3-haiku 是 24.00。
        "cacheWrite1hPerMTok": rate(spec.get("cache_creation_input_token_cost_above_1hr"), input_m * 2.0),
    }


def main() -> None:
    raw = json.load(sys.stdin)
    models = {name: convert_model(spec) for name, spec in raw.items() if should_keep(name, spec)}

    # 版本号取内容哈希，不取日期：价格没变时重新抓取应当产生空 diff，
    # 这样 `git status` 就能直接回答「价格到底动没动」。
    payload = json.dumps(models, sort_keys=True, separators=(",", ":"))
    version = hashlib.sha256(payload.encode()).hexdigest()[:12]

    json.dump(
        {"snapshotVersion": version, "source": "litellm", "models": models},
        sys.stdout,
        indent=2,
        sort_keys=True,
    )
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
