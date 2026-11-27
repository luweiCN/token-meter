#!/usr/bin/env python3
"""把 LiteLLM 的定价表转成 TokenMeter 的快照格式。

LiteLLM 的价格是「每 token 美元」，输出改成「每百万 token 美元」。
从 stdin 读 LiteLLM JSON，往 stdout 写快照 JSON。
上下文价格按阈值递增保存；缓存单价缺失保留为 null，显式 0 才表示免费。
"""
import hashlib
import json
import math
import re
import sys

# 刻意不做 provider 白名单：曾经的 KEEP_PROVIDERS 让新供应商的模型静默变成
# unknown（deepseek/gemini 都中过招），provider slug 改名也会翻车（zhipuai→zai
# 曾让 glm 全系丢价）。全量保留的代价只是快照变大（约 2000 条 / 350KB），而
# 匹配面由 PROVIDER_PREFIXES 控制：前缀不在剥离列表里的第三方托管键
# （cloudflare/、fireworks_ai/ 等）归一后保持原样，不会冒充官方价。
M = 1_000_000
SNAPSHOT_SCHEMA_VERSION = 2

# 定价键侧专用白名单。用量侧（Swift ModelNameNormalizer）已改为通用规则
# ——任意 `provider/` 前缀一律剥掉取最后一段（用户裁定）；这里不能跟：
# 白名单外的第三方托管键（cloudflare/、fireworks_ai/ 等）保留原样带斜杠，
# 用量侧永远不产带斜杠的键，于是那些价永远匹配不上，不会冒充官方价。
# 约束变成单向的子集关系：本表每个前缀剥出的键，必须与 Swift 通用规则的
# 结果一致（test_transform_pricing.py 对账）。
PROVIDER_PREFIXES = (
    "vertex_ai/", "bedrock/", "anthropic/", "openai/", "openai-codex/", "zai/",
    "deepseek/", "gemini/", "meta/", "xai/",
    "omniroute/", "9router/", "cx/", "opencode-go/", "ocg/",
    "glm-cn/", "glm/", "antigravity/", "google-antigravity/", "zhipu-coding-plan/",
)

# 与 Swift 的 ModelNameNormalizer.effortSuffixes 对齐：OmniRoute 网关层的档位别名，
# 计价按基础模型。-medium/-low 刻意不收（mistral-medium 的 medium 是尺寸不是档位）。
# -fast 也不收：Fast 改单价；grok-4-fast 是独立产品。
EFFORT_SUFFIXES = ("-xhigh", "-high")


def should_keep(name: str, spec: object) -> bool:
    if name == "sample_spec" or not isinstance(spec, dict):
        return False
    if spec.get("mode") != "chat":
        return False
    # 没有基础价格的条目无从计价；跳过它们，让成本落到 unknown 而不是 0
    return bool(spec.get("input_cost_per_token")) and bool(spec.get("output_cost_per_token"))


def rate(published: float | None) -> float | None:
    if published is None:
        return None
    if isinstance(published, bool) or not isinstance(published, (int, float)) or not math.isfinite(published) or published < 0:
        raise ValueError(f"非法单价: {published!r}")
    return round(published * M, 6)


def source_key(field: str, suffix: str, threshold_k: int | None = None) -> str:
    context = f"_above_{threshold_k}k_tokens" if threshold_k is not None else ""
    return f"{field}{context}{suffix}"


def convert_rate_card(spec: dict, suffix: str = "", threshold_k: int | None = None) -> dict:
    def price(field: str) -> float | None:
        return rate(spec.get(source_key(field, suffix, threshold_k)))

    input_m = price("input_cost_per_token")
    output_m = price("output_cost_per_token")
    for field, value in [("input_cost_per_token", input_m), ("output_cost_per_token", output_m)]:
        if value is None or value <= 0:
            raise ValueError(f"缺少有效基础价格 {source_key(field, suffix, threshold_k)}")
    cache_write = price("cache_creation_input_token_cost")
    cache_write_1h = price("cache_creation_input_token_cost_above_1hr")
    # OpenAI 的同一档明示 cache write 价不区分 TTL；其他供应商不能套这个规则。
    if cache_write_1h is None and spec.get("litellm_provider") == "openai":
        cache_write_1h = cache_write
    return {
        "inputPerMTok": input_m,
        "outputPerMTok": output_m,
        "cacheReadPerMTok": price("cache_read_input_token_cost"),
        "cacheWrite5mPerMTok": cache_write,
        "cacheWrite1hPerMTok": cache_write_1h,
    }


def convert_long_context(spec: dict, suffix: str = "") -> list:
    fields = "input_cost_per_token|output_cost_per_token|cache_read_input_token_cost|cache_creation_input_token_cost|cache_creation_input_token_cost_above_1hr"
    pattern = re.compile(rf"^(?:{fields})_above_(\d+)k_tokens{re.escape(suffix)}$")
    thresholds = sorted({int(match.group(1)) for key in spec for match in [pattern.match(key)] if match})
    if any(threshold <= 0 for threshold in thresholds):
        raise ValueError(f"非法长上下文阈值: {thresholds}")
    return [
        {"thresholdTokens": threshold * 1_000, "rate": convert_rate_card(spec, suffix, threshold)}
        for threshold in thresholds
    ]


def convert_model(spec: dict, suffix: str = "") -> dict:
    result = convert_rate_card(spec, suffix)
    long_context = convert_long_context(spec, suffix)
    if long_context:
        result["longContext"] = long_context
    return result


def fast_model_name(name: str) -> str:
    dated = re.search(r"-[0-9]{8}$", name)
    if dated:
        return f"{name[:dated.start()]}-fast{dated.group()}"
    return f"{name}-fast"


def add_fast_models(models: dict, raw: dict) -> dict:
    """LiteLLM 的 Priority 就是 OpenAI Fast；为用量侧 `{base}-fast` 合成同名价格键。"""
    for name, spec in raw.items():
        if (
            not should_keep(name, spec)
            or spec.get("litellm_provider") != "openai"
            or canonical(name).endswith("-fast")
        ):
            continue
        if not spec.get("input_cost_per_token_priority") or not spec.get("output_cost_per_token_priority"):
            continue
        name = fast_model_name(name)
        models.setdefault(name, convert_model(spec, suffix="_priority"))
    return models


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


def normalize_rate_card(name: str, spec: object) -> dict:
    if not isinstance(spec, dict):
        sys.exit(f"error: override {name} 的价格必须是对象")
    result = {field: spec.get(field) for field in PRICE_FIELDS}
    for field, value in result.items():
        is_base = field in PRICE_FIELDS[:2]
        if value is None and not is_base:
            continue
        if (isinstance(value, bool) or not isinstance(value, (int, float))
                or not math.isfinite(value) or value < 0 or (is_base and value == 0)):
            sys.exit(f"error: override {name} 缺少有效价格 {field}")
    return result


def normalize_context_tiers(name: str, tiers: object) -> list:
    if isinstance(tiers, dict):
        tiers = [tiers]
    if not isinstance(tiers, list):
        sys.exit(f"error: override {name} 的 longContext 必须是列表")
    result = []
    previous = 0
    for tier in tiers:
        threshold = tier.get("thresholdTokens") if isinstance(tier, dict) else None
        if isinstance(threshold, bool) or not isinstance(threshold, int) or threshold <= previous:
            sys.exit(f"error: override {name} 的上下文阈值必须为正且严格递增")
        result.append({"thresholdTokens": threshold, "rate": normalize_rate_card(f"{name}.longContext", tier.get("rate"))})
        previous = threshold
    return result


def normalize_tiered(name: str, tiered: object) -> dict:
    """校验 override 的 tiered 字段并去掉说明性字段。

    LiteLLM 只有 flat 价，表达不了峰谷定价（如 DeepSeek 2026-08-17 起），
    所以 tiered 只能经 override 进快照：基础价是生效前的旧价，peak/offPeak
    是生效后的两档价，effectiveAfter 是切换时刻，peakHoursUTC 是高峰小时。
    weekdaysOnly 与 holidays 可选：打开后高峰只在工作日（周六/周日整天平峰），
    holidays 是整天空闲的法定节假日（北京日历日）。
    """
    if not isinstance(tiered, dict):
        sys.exit(f"error: override {name} 的 tiered 必须是对象")
    missing = [k for k in ("effectiveAfter", "peakHoursUTC", "peak", "offPeak") if k not in tiered]
    if missing:
        sys.exit(f"error: override {name} 的 tiered 缺字段 {missing}")
    hours = tiered["peakHoursUTC"]
    if not isinstance(hours, list) or not all(isinstance(h, int) and 0 <= h <= 23 for h in hours):
        sys.exit(f"error: override {name} 的 tiered.peakHoursUTC 必须是 0–23 的整数列表")
    weekdays_only = tiered.get("weekdaysOnly", False)
    if not isinstance(weekdays_only, bool):
        sys.exit(f"error: override {name} 的 tiered.weekdaysOnly 必须是布尔值")
    holidays = tiered.get("holidays", [])
    if not isinstance(holidays, list):
        sys.exit(f"error: override {name} 的 tiered.holidays 必须是列表")
    for day in holidays:
        if not (
            isinstance(day, dict)
            and all(isinstance(day.get(k), int) for k in ("year", "month", "day"))
            and 1 <= day["month"] <= 12
            and 1 <= day["day"] <= 31
        ):
            sys.exit(f"error: override {name} 的 tiered.holidays 含非法日期 {day}")
    result = {k: tiered[k] for k in ("effectiveAfter", "peakHoursUTC")}
    for which in ("peak", "offPeak"):
        result[which] = normalize_rate_card(f"{name}.tiered.{which}", tiered[which])
    result["weekdaysOnly"] = weekdays_only
    result["holidays"] = holidays
    return result


def apply_overrides(models: dict, overrides: dict) -> dict:
    """手动登记价合并进快照，override 无条件优先。

    litellm 缺谁补谁（glm-5.2 发布数月上游仍未收录）。上游后来收录时这里
    会告警，提醒删掉过时的 override 改用上游价。note 等说明字段不进快照。
    带 tiered 的 override 不告警：上游即使收录同名模型也只有 flat 价，
    表达不了峰谷价，这类 override 无条件优先是刻意的。
    """
    for name, spec in overrides.items():
        entry = normalize_rate_card(name, spec)
        if spec.get("longContext") is not None:
            entry["longContext"] = normalize_context_tiers(name, spec["longContext"])
        tiered = spec.get("tiered")
        if tiered is not None:
            if entry.get("longContext"):
                sys.exit(f"error: override {name} 同时含上下文和峰谷价，缺少组合费率")
            entry["tiered"] = normalize_tiered(name, tiered)
        upstream = [k for k in models if canonical(k) == canonical(name)]
        if upstream and tiered is None:
            print(
                f"warning: 上游已收录与 override {name} 同名的模型 {upstream}，"
                "考虑删除这条 override 改用上游价",
                file=sys.stderr,
            )
        models[name] = entry
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
    try:
        models = {name: convert_model(spec) for name, spec in raw.items() if should_keep(name, spec)}
        add_fast_models(models, raw)
    except ValueError as error:
        sys.exit(f"error: {error}")

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
        {"schemaVersion": SNAPSHOT_SCHEMA_VERSION, "snapshotVersion": version, "source": "litellm", "models": models},
        sys.stdout,
        indent=2,
        sort_keys=True,
    )
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
