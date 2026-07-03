import XCTest
@testable import TokenMeterCore

final class RefreshGateTests: XCTestCase {
    func testAllowsFirstRefreshAndSkipsRequestsInsideCooldown() {
        let start = Date(timeIntervalSince1970: 1_000)
        var gate = RefreshGate(minimumInterval: 60)

        XCTAssertTrue(gate.shouldRefresh(now: start))
        XCTAssertFalse(gate.shouldRefresh(now: start.addingTimeInterval(30)))
        XCTAssertTrue(gate.shouldRefresh(now: start.addingTimeInterval(61)))
    }
}
