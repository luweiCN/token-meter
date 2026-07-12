import XCTest
@testable import TokenMeterCore

final class ModelNameNormalizerTests: XCTestCase {
    func testKeepsAlreadyCanonicalName() {
        XCTAssertEqual(ModelNameNormalizer.canonical("claude-fable-5"), "claude-fable-5")
    }

    func testStripsEightDigitDateSuffix() {
        XCTAssertEqual(ModelNameNormalizer.canonical("claude-opus-4-8-20260101"), "claude-opus-4-8")
    }

    func testStripsProviderPrefix() {
        XCTAssertEqual(ModelNameNormalizer.canonical("vertex_ai/claude-sonnet-4"), "claude-sonnet-4")
        XCTAssertEqual(ModelNameNormalizer.canonical("bedrock/claude-haiku-4-5"), "claude-haiku-4-5")
    }

    func testStripsPrefixAndSuffixTogether() {
        XCTAssertEqual(ModelNameNormalizer.canonical("anthropic/claude-opus-4-8-20260101"), "claude-opus-4-8")
    }

    func testStripsZaiPrefix() {
        XCTAssertEqual(ModelNameNormalizer.canonical("zai/glm-4.6"), "glm-4.6")
    }

    func testStripsOmniRouteGatewayPrefixes() {
        XCTAssertEqual(ModelNameNormalizer.canonical("cx/gpt-5.5"), "gpt-5.5")
        XCTAssertEqual(ModelNameNormalizer.canonical("opencode-go/deepseek-v4-flash"), "deepseek-v4-flash")
        XCTAssertEqual(ModelNameNormalizer.canonical("ocg/deepseek-v4-flash"), "deepseek-v4-flash")
        XCTAssertEqual(ModelNameNormalizer.canonical("glm/glm-5.1"), "glm-5.1")
        XCTAssertEqual(ModelNameNormalizer.canonical("google-antigravity/gemini-3.5-flash"), "gemini-3.5-flash")
        XCTAssertEqual(ModelNameNormalizer.canonical("zhipu-coding-plan/glm-5.2"), "glm-5.2")
        XCTAssertEqual(ModelNameNormalizer.canonical("deepseek/deepseek-v4-flash"), "deepseek-v4-flash")
        XCTAssertEqual(ModelNameNormalizer.canonical("gemini/gemini-3.5-flash"), "gemini-3.5-flash")
    }

    func testStripsStackedGatewayPrefixes() {
        // OMP 里配置的模型名是「网关/渠道/模型」两层前缀
        XCTAssertEqual(ModelNameNormalizer.canonical("omniroute/cx/gpt-5.5"), "gpt-5.5")
        XCTAssertEqual(ModelNameNormalizer.canonical("9router/glm/glm-5.2"), "glm-5.2")
        XCTAssertEqual(ModelNameNormalizer.canonical("omniroute/opencode-go/deepseek-v4-flash"), "deepseek-v4-flash")
    }

    func testStripsEffortSuffixes() {
        XCTAssertEqual(ModelNameNormalizer.canonical("gpt-5.5-xhigh"), "gpt-5.5")
        XCTAssertEqual(ModelNameNormalizer.canonical("antigravity/gemini-3.5-flash-high"), "gemini-3.5-flash")
        // 前缀叠加 + 档位后缀同时出现
        XCTAssertEqual(ModelNameNormalizer.canonical("omniroute/cx/gpt-5.5-xhigh"), "gpt-5.5")
    }

    func testGlmCnPrefixIsNotShadowedByGlmPrefix() {
        // glm-cn/ 与 glm/ 是两个渠道；hasPrefix("glm/") 对 "glm-cn/…" 不成立，
        // 这里锁住该边界，防止有人把列表改写成更宽的匹配。
        XCTAssertEqual(ModelNameNormalizer.canonical("glm-cn/glm-5.2"), "glm-5.2")
    }

    func testLowercases() {
        XCTAssertEqual(ModelNameNormalizer.canonical("GPT-5.5"), "gpt-5.5")
    }

    func testDoesNotStripVersionThatIsNotEightDigits() {
        XCTAssertEqual(ModelNameNormalizer.canonical("glm-4.6"), "glm-4.6")
        XCTAssertEqual(ModelNameNormalizer.canonical("claude-opus-4-8"), "claude-opus-4-8")
    }

    func testNilAndEmptyBecomeUnknown() {
        XCTAssertEqual(ModelNameNormalizer.canonical(nil), "unknown")
        XCTAssertEqual(ModelNameNormalizer.canonical(""), "unknown")
    }

    func testStripsMixedCasePrefixAndDateSuffixTogether() {
        // 小写必须发生在前缀匹配之前，否则大写前缀匹配不上
        XCTAssertEqual(ModelNameNormalizer.canonical("ANTHROPIC/Claude-Opus-4-8-20260101"), "claude-opus-4-8")
    }

    func testPrefixOnlyInputBecomesUnknown() {
        // 剥掉前缀后为空串，必须回落到 unknown 而不是返回 ""
        XCTAssertEqual(ModelNameNormalizer.canonical("vertex_ai/"), ModelNameNormalizer.unknown)
    }

    func testDoesNotStripSevenOrNineDigitSuffix() {
        // 边界：只有恰好八位数字才是日期后缀
        XCTAssertEqual(ModelNameNormalizer.canonical("claude-opus-4-8-2026010"), "claude-opus-4-8-2026010")
        XCTAssertEqual(ModelNameNormalizer.canonical("claude-opus-4-8-202601011"), "claude-opus-4-8-202601011")
    }
}
