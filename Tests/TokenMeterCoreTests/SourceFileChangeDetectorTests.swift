import XCTest
@testable import TokenMeterCore

final class SourceFileChangeDetectorTests: XCTestCase {
    func testClassifiesUnchangedAppendAndRewrite() {
        let previous = SourceFileFingerprint(
            dev: 1,
            inode: 10,
            sizeBytes: 100,
            mtimeNanoseconds: 1_000,
            tailHash: "old"
        )

        XCTAssertEqual(
            SourceFileChangeDetector.change(previous: previous, current: previous),
            .unchanged
        )
        XCTAssertEqual(
            SourceFileChangeDetector.change(
                previous: previous,
                current: SourceFileFingerprint(
                    dev: 1,
                    inode: 10,
                    sizeBytes: 150,
                    mtimeNanoseconds: 2_000,
                    tailHash: "old"
                )
            ),
            .appended
        )
        XCTAssertEqual(
            SourceFileChangeDetector.change(
                previous: previous,
                current: SourceFileFingerprint(
                    dev: 1,
                    inode: 10,
                    sizeBytes: 80,
                    mtimeNanoseconds: 2_000,
                    tailHash: "new"
                )
            ),
            .rewritten
        )
    }

    func testTreatsGrowthWithoutTailHashAsRewrite() {
        let previous = SourceFileFingerprint(
            dev: 1,
            inode: 10,
            sizeBytes: 100,
            mtimeNanoseconds: 1_000,
            tailHash: nil
        )
        let current = SourceFileFingerprint(
            dev: 1,
            inode: 10,
            sizeBytes: 150,
            mtimeNanoseconds: 2_000,
            tailHash: nil
        )

        XCTAssertEqual(SourceFileChangeDetector.change(previous: previous, current: current), .rewritten)
    }

    func testClassifiesMovedWhenIdentityChangesButTailMatches() {
        let previous = SourceFileFingerprint(
            dev: 1,
            inode: 10,
            sizeBytes: 100,
            mtimeNanoseconds: 1_000,
            tailHash: "same-tail"
        )
        let current = SourceFileFingerprint(
            dev: 2,
            inode: 20,
            sizeBytes: 100,
            mtimeNanoseconds: 2_000,
            tailHash: "same-tail"
        )

        XCTAssertEqual(SourceFileChangeDetector.change(previous: previous, current: current), .moved)
    }
}
