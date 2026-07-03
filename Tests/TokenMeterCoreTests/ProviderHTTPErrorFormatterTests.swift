import XCTest
@testable import TokenMeterCore

final class ProviderHTTPErrorFormatterTests: XCTestCase {
    func testFormatsRateLimitWithRetryAfterAndBodyMessage() {
        let json = """
        {
          "error": {
            "message": "Too many requests"
          }
        }
        """

        let message = ProviderHTTPErrorFormatter.message(
            providerName: "Claude",
            statusCode: 429,
            data: Data(json.utf8),
            retryAfter: "60"
        )

        XCTAssertEqual(message, "Claude 接口限流：Too many requests")
    }
}
