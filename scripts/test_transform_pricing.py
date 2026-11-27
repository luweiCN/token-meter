#!/usr/bin/env python3
"""transform_pricing 的单元测试。

跑法: python3 -m unittest discover -s scripts -p 'test_*.py'

这些测试用合成数据，不依赖 LiteLLM 的真实内容。快照里的真实价格
由 Swift 侧的 PricingTests 负责断言。
"""
import json
import pathlib
import re
import subprocess
import sys
import unittest

from transform_pricing import (
    EFFORT_SUFFIXES,
    PROVIDER_PREFIXES,
    SNAPSHOT_SCHEMA_VERSION,
    add_fast_models,
    apply_overrides,
    canonical,
    convert_model,
    divergent_collisions,
    fast_model_name,
    rate,
    should_keep,
)


class CrossLanguageContractTests(unittest.TestCase):
    """Python 的 canonical 与 Swift 的 ModelNameNormalizer 是两份独立实现。

    职责已分化（用户裁定）：Swift 用量侧对任意 `provider/` 前缀一律取最后一段；
    Python 定价键侧保留白名单，防第三方托管价冒充官方价。跨语言约束因此是
    单向子集：白名单内每个前缀剥出的定价键，必须与 Swift 通用规则对同样输入
    的结果一致，否则用量键查不到官方价。档位后缀两边仍是同一张表，继续对账。
    """

    SWIFT_FILE = (
        pathlib.Path(__file__).resolve().parent.parent
        / "Sources" / "TokenMeterCore" / "ModelNameNormalizer.swift"
    )
    COST_CALCULATOR_FILE = (
        pathlib.Path(__file__).resolve().parent.parent
        / "Sources" / "TokenMeterCore" / "CostCalculator.swift"
    )

    def test_snapshot_schema_matches_swift(self):
        source = self.SWIFT_FILE.with_name("Pricing.swift").read_text(encoding="utf-8")
        version = re.search(r"currentSchemaVersion\s*=\s*(\d+)", source)
        self.assertIsNotNone(version)
        self.assertEqual(SNAPSHOT_SCHEMA_VERSION, int(version.group(1)))

    def test_swift_uses_generic_last_segment_rule(self):
        # 白名单前缀表已从 Swift 删除；若有人加回去（重回双表对齐时代），
        # 这里要求恢复原先的逐项对账。
        source = self.SWIFT_FILE.read_text(encoding="utf-8")
        self.assertNotIn(
            "providerPrefixes",
            source,
            "Swift 出现了前缀白名单：请恢复 Python/Swift 前缀表的逐项对账",
        )
        self.assertIn("lastIndex(of: \"/\")", source, "在 Swift 源码里找不到取最后一段的通用剥离")

    def test_whitelisted_prefixes_are_subset_of_swift_general_rule(self):
        # Swift 通用规则对 prefix/model 恒取最后一段；Python 白名单剥出的键
        # 必须与之一致（即剥干净、不残留斜杠），官方价才能被用量键命中。
        for prefix in PROVIDER_PREFIXES:
            self.assertEqual(
                canonical(prefix + "claude-x"),
                "claude-x",
                f"前缀 {prefix} 剥离后与 Swift 通用规则不一致",
            )

    def test_effort_suffixes_match_swift(self):
        source = self.SWIFT_FILE.read_text(encoding="utf-8")
        block = re.search(r"effortSuffixes\s*=\s*\[(.*?)\]", source, re.S)
        self.assertIsNotNone(block, "在 Swift 源码里找不到 effortSuffixes")
        swift_suffixes = tuple(re.findall(r'"([^"]+)"', block.group(1)))
        self.assertEqual(
            swift_suffixes,
            EFFORT_SUFFIXES,
            "Swift 与 Python 的档位后缀表已经漂移",
        )

    def test_pricing_key_prefixes_match_python(self):
        # 定价键侧（CostCalculator）重新引入了白名单，防第三方托管键冒充官方价。
        # 两份前缀表必须逐项一致，否则「白名单剥出的键」与 Python 侧漂移，
        # 官方价会被第三方价按字典序抢先覆盖（azure_ai/deepseek-v4-pro 的教训）。
        source = self.COST_CALCULATOR_FILE.read_text(encoding="utf-8")
        block = re.search(r"pricingKeyPrefixes\s*=\s*\[(.*?)\]", source, re.S)
        self.assertIsNotNone(block, "在 Swift 源码里找不到 pricingKeyPrefixes")
        swift_prefixes = tuple(re.findall(r'"([^"]+/)"', block.group(1)))
        self.assertEqual(
            sorted(swift_prefixes),
            sorted(PROVIDER_PREFIXES),
            "Swift CostCalculator 与 Python 的定价键前缀白名单已经漂移",
        )


class RateTests(unittest.TestCase):
    def test_uses_published_value_when_present(self):
        self.assertEqual(rate(6e-6), 6.0)

    def test_explicit_zero_means_free_not_missing(self):
        # 这是让 glm 被错误收费的那个 bug
        self.assertEqual(rate(0), 0.0)

    def test_missing_price_stays_unknown(self):
        self.assertIsNone(rate(None))


class ShouldKeepTests(unittest.TestCase):
    def base(self, **overrides):
        spec = {
            "mode": "chat",
            "litellm_provider": "anthropic",
            "input_cost_per_token": 1e-5,
            "output_cost_per_token": 5e-5,
        }
        spec.update(overrides)
        return spec

    def test_keeps_chat_model_with_prices(self):
        self.assertTrue(should_keep("claude-x", self.base()))

    def test_keeps_any_provider(self):
        # 刻意没有 provider 白名单：新供应商不该静默丢价
        self.assertTrue(should_keep("m", self.base(litellm_provider="cohere")))

    def test_skips_sample_spec(self):
        self.assertFalse(should_keep("sample_spec", self.base()))

    def test_skips_non_chat_mode(self):
        self.assertFalse(should_keep("m", self.base(mode="embedding")))

    def test_skips_entry_without_base_prices(self):
        self.assertFalse(should_keep("m", self.base(input_cost_per_token=None)))
        self.assertFalse(should_keep("m", self.base(output_cost_per_token=0)))


class ConvertModelTests(unittest.TestCase):
    def test_converts_per_token_to_per_million(self):
        out = convert_model({"input_cost_per_token": 1.5e-5, "output_cost_per_token": 7.5e-5})
        self.assertEqual(out["inputPerMTok"], 15.0)
        self.assertEqual(out["outputPerMTok"], 75.0)

    def test_free_cache_write_stays_free(self):
        out = convert_model({
            "input_cost_per_token": 6e-7,
            "output_cost_per_token": 2.2e-6,
            "cache_creation_input_token_cost": 0,
        })
        self.assertEqual(out["cacheWrite5mPerMTok"], 0.0)

    def test_published_one_hour_rate_beats_the_double_multiplier(self):
        # claude-3-opus: input 15.0, 发布的 1h 价是 6.0，不是 30.0
        out = convert_model({
            "input_cost_per_token": 1.5e-5,
            "output_cost_per_token": 7.5e-5,
            "cache_creation_input_token_cost_above_1hr": 6e-6,
        })
        self.assertEqual(out["cacheWrite1hPerMTok"], 6.0)

    def test_absent_cache_fields_remain_unknown(self):
        out = convert_model({"input_cost_per_token": 1e-5, "output_cost_per_token": 5e-5})
        self.assertIsNone(out["cacheReadPerMTok"])
        self.assertIsNone(out["cacheWrite5mPerMTok"])
        self.assertIsNone(out["cacheWrite1hPerMTok"])

    def test_preserves_long_context_rates_and_strict_threshold(self):
        out = convert_model({
            "litellm_provider": "openai",
            "input_cost_per_token": 1e-5,
            "output_cost_per_token": 5e-5,
            "cache_read_input_token_cost": 1e-6,
            "cache_creation_input_token_cost": 1.25e-5,
            "input_cost_per_token_above_272k_tokens": 2e-5,
            "output_cost_per_token_above_272k_tokens": 7.5e-5,
            "cache_read_input_token_cost_above_272k_tokens": 2e-6,
            "cache_creation_input_token_cost_above_272k_tokens": 2.5e-5,
        })

        self.assertEqual(out["longContext"][0]["thresholdTokens"], 272_000)
        self.assertEqual(out["longContext"][0]["rate"], {
            "inputPerMTok": 20.0,
            "outputPerMTok": 75.0,
            "cacheReadPerMTok": 2.0,
            "cacheWrite5mPerMTok": 25.0,
            "cacheWrite1hPerMTok": 25.0,
        })

    def test_preserves_multiple_long_context_thresholds_in_order(self):
        out = convert_model({
            "input_cost_per_token": 1e-5,
            "output_cost_per_token": 5e-5,
            "cache_read_input_token_cost": 1e-6,
            "input_cost_per_token_above_256k_tokens": 4e-5,
            "output_cost_per_token_above_256k_tokens": 1e-4,
            "cache_read_input_token_cost_above_256k_tokens": 0,
            "input_cost_per_token_above_32k_tokens": 2e-5,
            "output_cost_per_token_above_32k_tokens": 7.5e-5,
        })
        self.assertEqual([tier["thresholdTokens"] for tier in out["longContext"]], [32_000, 256_000])
        self.assertEqual(out["longContext"][0]["rate"]["outputPerMTok"], 75)
        self.assertIsNone(out["longContext"][0]["rate"]["cacheReadPerMTok"])
        self.assertEqual(out["longContext"][1]["rate"]["cacheReadPerMTok"], 0)

    def test_rejects_incomplete_context_rate_instead_of_using_base_price(self):
        with self.assertRaisesRegex(ValueError, "output_cost_per_token_above_32k_tokens"):
            convert_model({
                "input_cost_per_token": 1e-5,
                "output_cost_per_token": 5e-5,
                "input_cost_per_token_above_32k_tokens": 2e-5,
            })


class FastModelTests(unittest.TestCase):
    def test_priority_rates_generate_fast_model_and_long_context(self):
        spec = {
            "mode": "chat",
            "litellm_provider": "openai",
            "input_cost_per_token": 1e-5,
            "output_cost_per_token": 5e-5,
            "input_cost_per_token_priority": 2e-5,
            "output_cost_per_token_priority": 1e-4,
            "cache_read_input_token_cost_priority": 2e-6,
            "cache_creation_input_token_cost_priority": 2.5e-5,
            "input_cost_per_token_above_272k_tokens_priority": 4e-5,
            "output_cost_per_token_above_272k_tokens_priority": 1.5e-4,
            "cache_read_input_token_cost_above_272k_tokens_priority": 4e-6,
            "cache_creation_input_token_cost_above_272k_tokens_priority": 5e-5,
        }

        models = add_fast_models({}, {"gpt-6-astra": spec})

        fast = models["gpt-6-astra-fast"]
        self.assertEqual(fast["inputPerMTok"], 20.0)
        self.assertEqual(fast["outputPerMTok"], 100.0)
        self.assertEqual(fast["cacheReadPerMTok"], 2.0)
        self.assertEqual(fast["cacheWrite5mPerMTok"], 25.0)
        self.assertEqual(fast["cacheWrite1hPerMTok"], 25.0)
        self.assertEqual(fast["longContext"][0]["thresholdTokens"], 272_000)
        self.assertEqual(fast["longContext"][0]["rate"]["outputPerMTok"], 150.0)

    def test_dated_snapshot_puts_fast_before_date(self):
        self.assertEqual(fast_model_name("gpt-6-astra-20260907"), "gpt-6-astra-fast-20260907")

    def test_does_not_generate_fast_without_complete_priority_price(self):
        spec = {
            "mode": "chat",
            "input_cost_per_token": 1e-5,
            "output_cost_per_token": 5e-5,
            "input_cost_per_token_priority": 2e-5,
        }
        self.assertEqual(add_fast_models({}, {"gpt-6-astra": spec}), {})

    def test_does_not_treat_other_providers_priority_tier_as_openai_fast(self):
        spec = {
            "mode": "chat",
            "litellm_provider": "gemini",
            "input_cost_per_token": 1e-5,
            "output_cost_per_token": 5e-5,
            "input_cost_per_token_priority": 2e-5,
            "output_cost_per_token_priority": 1e-4,
        }

        self.assertEqual(add_fast_models({}, {"gemini/gemini-x": spec}), {})


class TransformCommandTests(unittest.TestCase):
    SCRIPT = pathlib.Path(__file__).with_name("transform_pricing.py")
    BASE = {
        "mode": "chat",
        "litellm_provider": "openai",
        "input_cost_per_token": 1e-5,
        "output_cost_per_token": 5e-5,
    }

    def transform(self, raw):
        return subprocess.run(
            [sys.executable, str(self.SCRIPT)],
            input=json.dumps(raw), text=True, capture_output=True, check=False,
        )

    def test_multi_tier_model_is_published_alongside_other_prices(self):
        multiple_tiers = {
            **self.BASE,
            "litellm_provider": "kyma",
            "input_cost_per_token_above_32k_tokens": 1.35e-7,
            "output_cost_per_token_above_32k_tokens": 5.4e-7,
            "input_cost_per_token_above_256k_tokens": 2.7e-7,
            "output_cost_per_token_above_256k_tokens": 1.08e-6,
        }
        supported = {
            **self.BASE,
            "input_cost_per_token_above_272k_tokens": 2e-5,
            "output_cost_per_token_above_272k_tokens": 7.5e-5,
            "input_cost_per_token_priority": 2e-5,
            "output_cost_per_token_priority": 1e-4,
        }
        for raw in [
            {"kyma/qwen3.7-flash": multiple_tiers, "gpt-x": supported},
            {"gpt-x": supported, "kyma/qwen3.7-flash": multiple_tiers},
        ]:
            with self.subTest(order=list(raw)):
                result = self.transform(raw)
                self.assertEqual(result.returncode, 0, result.stderr)
                snapshot = json.loads(result.stdout)
                self.assertEqual(snapshot["schemaVersion"], 2)
                models = snapshot["models"]
                self.assertEqual(set(models), {"gpt-x", "gpt-x-fast", "kyma/qwen3.7-flash"})
                self.assertEqual(models["gpt-x"]["inputPerMTok"], 10)
                self.assertEqual(models["gpt-x"]["longContext"][0]["thresholdTokens"], 272_000)
                self.assertEqual(models["gpt-x"]["longContext"][0]["rate"]["outputPerMTok"], 75)
                self.assertEqual(models["gpt-x-fast"]["inputPerMTok"], 20)
                self.assertEqual([tier["thresholdTokens"] for tier in models["kyma/qwen3.7-flash"]["longContext"]], [32_000, 256_000])
                self.assertEqual(result.stderr, "")

    def test_priority_prices_keep_all_context_tiers_separate_from_standard(self):
        result = self.transform({"gpt-x": {
            **self.BASE,
            "input_cost_per_token_priority": 2e-5,
            "output_cost_per_token_priority": 1e-4,
            "input_cost_per_token_above_32k_tokens_priority": 4e-5,
            "output_cost_per_token_above_32k_tokens_priority": 2e-4,
            "input_cost_per_token_above_256k_tokens_priority": 8e-5,
            "output_cost_per_token_above_256k_tokens_priority": 4e-4,
        }})
        self.assertEqual(result.returncode, 0, result.stderr)
        models = json.loads(result.stdout)["models"]
        self.assertEqual(set(models), {"gpt-x", "gpt-x-fast"})
        self.assertEqual(models["gpt-x"]["inputPerMTok"], 10)
        self.assertNotIn("longContext", models["gpt-x"])
        self.assertEqual([tier["thresholdTokens"] for tier in models["gpt-x-fast"]["longContext"]], [32_000, 256_000])
        self.assertEqual(models["gpt-x-fast"]["longContext"][1]["rate"]["outputPerMTok"], 400)
        self.assertEqual(result.stderr, "")

    def test_unexpected_invalid_data_still_fails_generation(self):
        result = self.transform({"gpt-x": {**self.BASE, "cache_read_input_token_cost": {"invalid": 1}}})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")


class CanonicalTests(unittest.TestCase):
    def test_matches_swift_normalizer(self):
        self.assertEqual(canonical("vertex_ai/claude-3-opus"), "claude-3-opus")
        self.assertEqual(canonical("claude-3-opus-20240229"), "claude-3-opus")
        self.assertEqual(canonical("zai/glm-4.6"), "glm-4.6")
        self.assertEqual(canonical("glm-4.6"), "glm-4.6")          # 非八位数字后缀不剥离
        self.assertEqual(canonical("GPT-5.5"), "gpt-5.5")
        self.assertEqual(canonical("omniroute/cx/gpt-5.5"), "gpt-5.5")   # 叠加前缀循环剥离
        self.assertEqual(canonical("gpt-5.5-xhigh"), "gpt-5.5")          # 网关档位别名归一到基础模型
        self.assertEqual(canonical("mistral-medium"), "mistral-medium")  # medium 是尺寸不是档位，不剥
        self.assertEqual(canonical("gpt-5.6-sol-fast"), "gpt-5.6-sol-fast")  # Fast 不是 effort，不剥
        self.assertEqual(canonical("grok-4-fast"), "grok-4-fast")
        self.assertEqual(canonical("xai/grok-4.7"), "grok-4.7")
        self.assertEqual(canonical("vertex_ai/xai/grok-4.7"), "grok-4.7")
        self.assertEqual(canonical("grok-4.7-build"), "grok-4.7-build")
        self.assertEqual(canonical("grok-4.7-build-fast"), "grok-4.7-build-fast")


class OverrideTests(unittest.TestCase):
    PRICE = {
        "inputPerMTok": 1.4,
        "outputPerMTok": 4.4,
        "cacheReadPerMTok": 0.26,
        "cacheWrite5mPerMTok": 0.0,
        "cacheWrite1hPerMTok": 0.0,
    }
    TIERED = {
        "effectiveAfter": "2026-08-16T16:00:00Z",
        "peakHoursUTC": [1, 2, 3, 6, 7, 8, 9],
        "weekdaysOnly": True,
        "holidays": [{"year": 2026, "month": 10, "day": 1}],
        "peak": {
            "inputPerMTok": 0.44,
            "outputPerMTok": 1.32,
            "cacheReadPerMTok": 0.014,
            "cacheWrite5mPerMTok": 0.0,
            "cacheWrite1hPerMTok": 0.28,
        },
        "offPeak": {
            "inputPerMTok": 0.22,
            "outputPerMTok": 0.66,
            "cacheReadPerMTok": 0.007,
            "cacheWrite5mPerMTok": 0.0,
            "cacheWrite1hPerMTok": 0.28,
        },
    }

    def test_fills_model_missing_upstream(self):
        models = apply_overrides({}, {"glm-5.2": {**self.PRICE, "note": "出处备忘"}})
        self.assertEqual(models["glm-5.2"], self.PRICE)  # note 不进快照

    def test_override_keeps_all_context_tiers_and_unknown_cache_prices(self):
        context = [
            {"thresholdTokens": 32_000, "rate": {"inputPerMTok": 2, "outputPerMTok": 4}},
            {"thresholdTokens": 256_000, "rate": {**self.PRICE, "cacheReadPerMTok": 0}},
        ]
        models = apply_overrides({}, {"m": {**self.PRICE, "longContext": context}})
        self.assertEqual([tier["thresholdTokens"] for tier in models["m"]["longContext"]], [32_000, 256_000])
        self.assertIsNone(models["m"]["longContext"][0]["rate"]["cacheReadPerMTok"])
        self.assertEqual(models["m"]["longContext"][1]["rate"]["cacheReadPerMTok"], 0)

    def test_override_normalizes_legacy_context_object(self):
        context = {"thresholdTokens": 32_000, "rate": self.PRICE}
        models = apply_overrides({}, {"m": {**self.PRICE, "longContext": context}})
        self.assertEqual(models["m"]["longContext"], [context])

    def test_override_rejects_unordered_context_or_ambiguous_time_and_context_rules(self):
        context = [{"thresholdTokens": 256_000, "rate": self.PRICE}, {"thresholdTokens": 32_000, "rate": self.PRICE}]
        with self.assertRaises(SystemExit):
            apply_overrides({}, {"m": {**self.PRICE, "longContext": context}})
        with self.assertRaises(SystemExit):
            apply_overrides({}, {"m": {**self.PRICE, "longContext": context[:1], "tiered": self.TIERED}})

    def test_override_wins_and_warns_when_upstream_has_it(self):
        upstream = {"zai/glm-5.2": {**self.PRICE, "inputPerMTok": 9.9}}
        import contextlib, io
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            models = apply_overrides(upstream, {"glm-5.2": dict(self.PRICE)})
        # override 与上游归一后同名：override 键胜出（字典序也保证 glm-5.2 < zai/glm-5.2）
        self.assertEqual(models["glm-5.2"], self.PRICE)
        self.assertIn("考虑删除这条 override", stderr.getvalue())

    def test_dies_on_missing_price_field(self):
        with self.assertRaises(SystemExit):
            apply_overrides({}, {"glm-5.2": {"inputPerMTok": 1.4}})

    def test_tiered_passes_through_and_suppresses_upstream_warning(self):
        # 上游收录同名模型也只有 flat 价，表达不了峰谷价；tiered override
        # 无条件优先是刻意的，不该再催人删掉它改用上游价。
        import contextlib, io
        upstream = {"deepseek/deepseek-v4-flash": {**self.PRICE, "inputPerMTok": 0.5}}
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            models = apply_overrides(upstream, {"deepseek-v4-flash": {**self.PRICE, "tiered": self.TIERED}})
        self.assertEqual(models["deepseek-v4-flash"]["tiered"], self.TIERED)
        self.assertNotIn("考虑删除这条 override", stderr.getvalue())

    def test_tiered_dies_on_missing_key(self):
        bad = {**self.PRICE, "tiered": {"peakHoursUTC": [1], "peak": self.PRICE, "offPeak": self.PRICE}}
        with self.assertRaises(SystemExit):
            apply_overrides({}, {"m": bad})

    def test_tiered_dies_on_hour_out_of_range(self):
        tiered = {**self.TIERED, "peakHoursUTC": [1, 24]}
        with self.assertRaises(SystemExit):
            apply_overrides({}, {"m": {**self.PRICE, "tiered": tiered}})

    def test_tiered_dies_on_missing_price_field(self):
        tiered = {**self.TIERED, "peak": {"inputPerMTok": 0.44}}
        with self.assertRaises(SystemExit):
            apply_overrides({}, {"m": {**self.PRICE, "tiered": tiered}})

    def test_tiered_defaults_weekdays_only_off_when_absent(self):
        # 老式 override 没写 weekdaysOnly/holidays：按每天切价、无节假日豁免，
        # 输出补齐两个键，旧快照语义不变。
        tiered = {k: v for k, v in self.TIERED.items() if k not in ("weekdaysOnly", "holidays")}
        models = apply_overrides({}, {"m": {**self.PRICE, "tiered": tiered}})
        self.assertEqual(models["m"]["tiered"]["weekdaysOnly"], False)
        self.assertEqual(models["m"]["tiered"]["holidays"], [])

    def test_tiered_dies_on_bad_holiday(self):
        tiered = {**self.TIERED, "holidays": [{"year": 2026, "month": 13, "day": 1}]}
        with self.assertRaises(SystemExit):
            apply_overrides({}, {"m": {**self.PRICE, "tiered": tiered}})


class DivergentCollisionTests(unittest.TestCase):
    def test_flags_collision_with_different_prices(self):
        models = {
            "claude-3-opus-20240229": {"inputPerMTok": 15.0, "cacheWrite1hPerMTok": 6.0},
            "vertex_ai/claude-3-opus": {"inputPerMTok": 15.0, "cacheWrite1hPerMTok": 30.0},
        }
        found = divergent_collisions(models)
        self.assertEqual(len(found), 1)
        name, keys = found[0]
        self.assertEqual(name, "claude-3-opus")
        self.assertEqual(keys[0], "claude-3-opus-20240229", "字典序最小者胜出")

    def test_ignores_collision_with_identical_prices(self):
        models = {
            "claude-fable-5": {"inputPerMTok": 10.0},
            "vertex_ai/claude-fable-5": {"inputPerMTok": 10.0},
        }
        self.assertEqual(divergent_collisions(models), [])

    def test_ignores_non_colliding_names(self):
        models = {"a": {"inputPerMTok": 1.0}, "b": {"inputPerMTok": 2.0}}
        self.assertEqual(divergent_collisions(models), [])


if __name__ == "__main__":
    unittest.main()
