import XCTest
@testable import TokenMeterCore

final class ProviderErrorMessageTests: XCTestCase {
    func testSanitizesCommandFailureMessage() {
        let message = ProviderErrorMessage.sanitized(
            providerName: "Codex",
            errorMessage: #"命令退出 1：node -e const { spawn } = require("child_process");"#
        )

        XCTAssertEqual(message, "Codex 暂时无法读取额度")
    }

    func testKeepsHumanReadableProviderMessage() {
        let message = ProviderErrorMessage.sanitized(
            providerName: "Claude",
            errorMessage: "Claude 接口限流，60 秒后重试"
        )

        XCTAssertEqual(message, "Claude 接口限流，60 秒后重试")
    }
}
