import XCTest
@testable import TokenMeterApp

final class MenuBarProviderNameTests: XCTestCase {
    func testGrokLabel() {
        XCTAssertEqual(MenuBarProviderName.label("grok"), "Grok Build")
    }
}
