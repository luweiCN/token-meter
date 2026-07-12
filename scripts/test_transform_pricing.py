#!/usr/bin/env python3
"""transform_pricing 的单元测试。

跑法: python3 -m unittest discover -s scripts -p 'test_*.py'

这些测试用合成数据，不依赖 LiteLLM 的真实内容。快照里的真实价格
由 Swift 侧的 PricingTests 负责断言。
"""
import pathlib
import re
import unittest

from transform_pricing import (
    PROVIDER_PREFIXES,
    canonical,
    convert_model,
    divergent_collisions,
    rate,
    should_keep,
)


class CrossLanguageContractTests(unittest.TestCase):
    """Python 的 canonical 与 Swift 的 ModelNameNormalizer 是两份独立实现。

    没有共享真相源：给 Swift 加一个前缀而忘了 Python，撞名检测会静默漏报，
    而运行时的计价以 Swift 为准。这个测试直接从 Swift 源码里把列表抠出来对账。
    """

    def test_provider_prefixes_match_swift(self):
        swift_file = (
            pathlib.Path(__file__).resolve().parent.parent
            / "Sources" / "TokenMeterCore" / "ModelNameNormalizer.swift"
        )
        source = swift_file.read_text(encoding="utf-8")

        block = re.search(r"providerPrefixes\s*=\s*\[(.*?)\]", source, re.S)
        self.assertIsNotNone(block, "在 Swift 源码里找不到 providerPrefixes")

        # 只取每行开头的字符串字面量，避开行尾注释里可能出现的引号
        swift_prefixes = tuple(re.findall(r'^\s*"([^"]+)"', block.group(1), re.M))

        self.assertEqual(
            swift_prefixes,
            PROVIDER_PREFIXES,
            "Swift 与 Python 的 provider 前缀表已经漂移",
        )


class RateTests(unittest.TestCase):
    def test_uses_published_value_when_present(self):
        self.assertEqual(rate(6e-6, fallback=999.0), 6.0)

    def test_explicit_zero_means_free_not_missing(self):
        # 这是让 glm 被错误收费的那个 bug
        self.assertEqual(rate(0, fallback=0.75), 0.0)

    def test_none_falls_back_to_derived(self):
        self.assertEqual(rate(None, fallback=0.75), 0.75)


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

    def test_absent_cache_fields_derive_fallbacks(self):
        out = convert_model({"input_cost_per_token": 1e-5, "output_cost_per_token": 5e-5})
        self.assertEqual(out["cacheReadPerMTok"], 1.0)      # input * 0.1
        self.assertEqual(out["cacheWrite5mPerMTok"], 12.5)  # input * 1.25
        self.assertEqual(out["cacheWrite1hPerMTok"], 20.0)  # input * 2.0


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
