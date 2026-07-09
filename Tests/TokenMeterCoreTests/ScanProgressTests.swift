import XCTest
@testable import TokenMeterCore

final class ScanProgressTests: XCTestCase {
    func testEmitsOnCrossingHalfPercent() {
        var throttle = ScanProgressThrottle()
        XCTAssertTrue(throttle.shouldEmit(bytesDone: 0, bytesTotal: 1000, isFinal: false))
        XCTAssertFalse(throttle.shouldEmit(bytesDone: 1, bytesTotal: 1000, isFinal: false))
        XCTAssertTrue(throttle.shouldEmit(bytesDone: 5, bytesTotal: 1000, isFinal: false))
    }

    func testAlwaysEmitsFinal() {
        var throttle = ScanProgressThrottle()
        _ = throttle.shouldEmit(bytesDone: 0, bytesTotal: 1000, isFinal: false)
        XCTAssertTrue(throttle.shouldEmit(bytesDone: 1, bytesTotal: 1000, isFinal: true),
                      "最后一条必须发出，否则 UI 永远停在 99.6%")
    }

    func testZeroTotalDoesNotDivideByZero() {
        var throttle = ScanProgressThrottle()
        XCTAssertTrue(throttle.shouldEmit(bytesDone: 0, bytesTotal: 0, isFinal: true))
    }

    func testBoundedEventCount() {
        // 10 万次调用最多发出约 201 条：0.5% 一档，共 200 档，加末尾一条。
        var throttle = ScanProgressThrottle()
        let emitted = (0...100_000).filter {
            throttle.shouldEmit(bytesDone: Int64($0), bytesTotal: 100_000, isFinal: false)
        }.count
        XCTAssertLessThanOrEqual(emitted, 205, "进度事件必须有界，否则 5,492 个文件会刷屏")
        XCTAssertGreaterThanOrEqual(emitted, 195)
    }
}
