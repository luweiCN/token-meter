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
