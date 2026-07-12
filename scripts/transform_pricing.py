#!/usr/bin/env python3
"""把 LiteLLM 的定价表转成 TokenMeter 的快照格式。

LiteLLM 的价格是「每 token 美元」，输出改成「每百万 token 美元」。
从 stdin 读 LiteLLM JSON，往 stdout 写快照 JSON。
"""
import hashlib
import json
import re
import sys

# 刻意不做 provider 白名单：曾经的 KEEP_PROVIDERS 让新供应商的模型静默变成
# unknown（deepseek/gemini 都中过招），provider slug 改名也会翻车（zhipuai→zai
# 曾让 glm 全系丢价）。全量保留的代价只是快照变大（约 2000 条 / 350KB），而
# 匹配面由 PROVIDER_PREFIXES 控制：前缀不在剥离列表里的第三方托管键
# （cloudflare/、fireworks_ai/ 等）归一后保持原样，不会冒充官方价。
M = 1_000_000

# 必须与 Swift 的 ModelNameNormalizer.providerPrefixes 逐项对齐，顺序也一样
# （顺序决定每轮剥掉的是哪个前缀）。两边是各自独立的实现，没有共享真相源，
# 只改一边就会静默漂移。test_transform_pricing.py 会从 Swift 源码里把这个列表
# 抠出来对账。
PROVIDER_PREFIXES = (
    "vertex_ai/", "bedrock/", "anthropic/", "openai/", "openai-codex/", "zai/",
    "deepseek/", "gemini/",
    "omniroute/", "9router/", "cx/", "opencode-go/", "ocg/",
    "glm-cn/", "glm/", "antigravity/", "google-antigravity/", "zhipu-coding-plan/",
)

# 与 Swift 的 ModelNameNormalizer.effortSuffixes 对齐：OmniRoute 网关层的档位别名，
# 计价按基础模型。-medium/-low 刻意不收（mistral-medium 的 medium 是尺寸不是档位）。
EFFORT_SUFFIXES = ("-xhigh", "-high")


def should_keep(name: str, spec: object) -> bool:
    if name == "sample_spec" or not isinstance(spec, dict):
        return False
    if spec.get("mode") != "chat":
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


def canonical(name: str) -> str:
    """必须与 Swift 的 ModelNameNormalizer.canonical 保持一致。"""
    name = name.lower()
    # 循环剥离：网关前缀会叠加（omniroute/cx/gpt-5.5）
    stripped = True
    while stripped:
        stripped = False
        for prefix in PROVIDER_PREFIXES:
            if name.startswith(prefix):
                name = name[len(prefix):]
                stripped = True
                break
    name = re.sub(r"-[0-9]{8}$", "", name)
    for suffix in EFFORT_SUFFIXES:
        if name.endswith(suffix):
            name = name[: -len(suffix)]
            break
    return name or "unknown"


PRICE_FIELDS = ("inputPerMTok", "outputPerMTok", "cacheReadPerMTok", "cacheWrite5mPerMTok", "cacheWrite1hPerMTok")


def apply_overrides(models: dict, overrides: dict) -> dict:
    """手动登记价合并进快照，override 无条件优先。

    litellm 缺谁补谁（glm-5.2 发布数月上游仍未收录）。上游后来收录时这里
    会告警，提醒删掉过时的 override 改用上游价。note 等说明字段不进快照。
    """
    for name, spec in overrides.items():
        missing = [f for f in PRICE_FIELDS if f not in spec]
        if missing:
            sys.exit(f"error: override {name} 缺价格字段 {missing}")
        upstream = [k for k in models if canonical(k) == canonical(name)]
        if upstream:
            print(
                f"warning: 上游已收录与 override {name} 同名的模型 {upstream}，"
                "考虑删除这条 override 改用上游价",
                file=sys.stderr,
            )
        models[name] = {f: spec[f] for f in PRICE_FIELDS}
    return models


def divergent_collisions(models: dict) -> list:
    """归一后撞名、但价格不一致的组。

    CostCalculator 只保留字典序最小的原始 key，其余 key 的用户会被按
    胜出者的价格计费。这不是猜测：claude-3-opus 与 vertex_ai/claude-3-opus
    的 1h 缓存价相差 5 倍。
    """
    groups = {}
    for key in sorted(models):
        groups.setdefault(canonical(key), []).append(key)
    return [
        (name, keys)
        for name, keys in sorted(groups.items())
        if len(keys) > 1 and len({json.dumps(models[k], sort_keys=True) for k in keys}) > 1
    ]


def main() -> None:
    raw = json.load(sys.stdin)
    models = {name: convert_model(spec) for name, spec in raw.items() if should_keep(name, spec)}

    # argv[1]: 手动登记价文件（scripts/pricing-overrides.json），在撞名审计前合并
    if len(sys.argv) > 1:
        with open(sys.argv[1]) as f:
            apply_overrides(models, json.load(f)["models"])

    for name, keys in divergent_collisions(models):
        print(f"warning: {name} 撞名且价格不一致，将按 {keys[0]} 计价", file=sys.stderr)
        for key in keys:
            print(f"  {key}: {json.dumps(models[key], sort_keys=True)}", file=sys.stderr)

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
