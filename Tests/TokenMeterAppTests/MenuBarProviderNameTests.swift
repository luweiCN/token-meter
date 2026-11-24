import XCTest
@testable import TokenMeterApp

final class MenuBarProviderNameTests: XCTestCase {
    func testAntigravityAgentUsesFullProductName() {
        XCTAssertEqual(MenuBarProviderName.label("antigravity-cli"), "Antigravity CLI")
    }

    func testGrokLabel() {
        XCTAssertEqual(MenuBarProviderName.label("grok"), "Grok Build")
    }
}
