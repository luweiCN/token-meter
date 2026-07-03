import XCTest
@testable import TokenMeterCore

final class JSONLStreamReaderTests: XCTestCase {
    func testReadsCompleteLinesAndReturnsResidualIncompleteLine() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("session.jsonl")
        try Data("{\"a\":1}\n{\"b\":2}".utf8).write(to: file)

        let result = try JSONLStreamReader.readLines(from: file, startingAt: 0)

        XCTAssertEqual(result.lines.map(\.text), ["{\"a\":1}"])
        XCTAssertEqual(result.lines.map(\.offset), [0])
        XCTAssertEqual(result.lines.map(\.nextOffset), [8])
        XCTAssertEqual(result.nextOffset, 8)
        XCTAssertEqual(result.residual, "{\"b\":2}")
    }

    func testReadsFromIncrementalOffsetAfterResidualBecomesComplete() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("session.jsonl")
        try Data("{\"a\":1}\n{\"b\":2}".utf8).write(to: file)

        let firstRead = try JSONLStreamReader.readLines(from: file, startingAt: 0)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n{\"c\":3}\n".utf8))

        let secondRead = try JSONLStreamReader.readLines(from: file, startingAt: firstRead.nextOffset)

        XCTAssertEqual(secondRead.lines.map(\.text), ["{\"b\":2}", "{\"c\":3}"])
        XCTAssertEqual(secondRead.lines.map(\.offset), [8, 16])
        XCTAssertEqual(secondRead.lines.map(\.nextOffset), [16, 24])
        XCTAssertEqual(secondRead.nextOffset, 24)
        XCTAssertNil(secondRead.residual)
    }
}
