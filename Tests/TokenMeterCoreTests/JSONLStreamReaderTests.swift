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

    func testStreamingCallbackDoesNotAccumulateDeliveredLinesInResult() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("session.jsonl")
        try Data("{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n".utf8).write(to: file)

        var delivered: [JSONLLine] = []
        let result = try JSONLStreamReader.readLines(from: file, startingAt: 0) { line in
            delivered.append(line)
        }

        XCTAssertEqual(delivered.map(\.text), ["{\"a\":1}", "{\"b\":2}", "{\"c\":3}"])
        XCTAssertEqual(delivered.map(\.offset), [0, 8, 16])
        XCTAssertEqual(delivered.map(\.nextOffset), [8, 16, 24])
        XCTAssertEqual(result.nextOffset, 24)
        XCTAssertNil(result.residual)
        XCTAssertTrue(result.lines.isEmpty, "streaming reads must deliver complete lines through the callback without retaining them in JSONLReadResult.lines")
    }

    func testSkipsLinesWithoutAnyMarker() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("marker-\(UUID().uuidString).jsonl")
        let content = """
        {"type":"response_item","payload":{"type":"function_call"}}
        {"type":"event_msg","payload":{"type":"token_count"}}
        {"type":"response_item","payload":{"type":"function_call_output"}}
        {"type":"turn_context","payload":{"model":"gpt-5.5"}}

        """
        try content.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try JSONLStreamReader.readLines(from: url, startingAt: 0, markers: ["token_count", "turn_context"])

        XCTAssertEqual(result.lines.count, 2)
        XCTAssertTrue(result.lines[0].text.contains("token_count"))
        XCTAssertTrue(result.lines[1].text.contains("turn_context"))
    }

    func testMarkerFilteringPreservesTrueByteOffsets() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("offset-\(UUID().uuidString).jsonl")
        let first = #"{"skip":1}"#
        let second = #"{"keep":"token_count"}"#
        try "\(first)\n\(second)\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try JSONLStreamReader.readLines(from: url, startingAt: 0, markers: ["token_count"])

        XCTAssertEqual(result.lines.count, 1)
        // 被跳过的行仍要把 offset 推进，否则续读会错位
        XCTAssertEqual(result.lines[0].offset, Int64(first.utf8.count + 1))
    }

    func testNilMarkersKeepsEveryLine() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("all-\(UUID().uuidString).jsonl")
        try "{\"a\":1}\n{\"b\":2}\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(try JSONLStreamReader.readLines(from: url, startingAt: 0, markers: nil).lines.count, 2)
    }

    func testMarkerFilteringWorksWithOnLineCallback() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cb-\(UUID().uuidString).jsonl")
        try "{\"a\":1}\n{\"b\":\"token_count\"}\n{\"c\":3}\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        var seen: [String] = []
        _ = try JSONLStreamReader.readLines(from: url, startingAt: 0, markers: ["token_count"]) { line in
            seen.append(line.text)
        }

        XCTAssertEqual(seen.count, 1)
        XCTAssertTrue(seen[0].contains("token_count"))
    }

    func testResumingFromAnOffsetAfterSkippedLinesLandsOnTheRightLine() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("resume-\(UUID().uuidString).jsonl")
        let a = #"{"skip":"a"}"#
        let b = #"{"keep":"token_count","n":1}"#
        let c = #"{"skip":"c"}"#
        let d = #"{"keep":"token_count","n":2}"#
        try "\(a)\n\(b)\n\(c)\n\(d)\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try JSONLStreamReader.readLines(from: url, startingAt: 0, markers: ["token_count"])
        XCTAssertEqual(first.lines.count, 2)

        // 从第一条命中行的下一字节续读，必须只拿到第二条命中行
        let resumeFrom = first.lines[0].nextOffset
        let second = try JSONLStreamReader.readLines(from: url, startingAt: resumeFrom, markers: ["token_count"])
        XCTAssertEqual(second.lines.count, 1)
        XCTAssertTrue(second.lines[0].text.contains("\"n\":2"))
    }

    func testMarkerMatchesAcrossAChunkBoundary() throws {
        // 标记串跨越 chunk 边界时不能漏检
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chunk-\(UUID().uuidString).jsonl")
        let padding = String(repeating: "x", count: 300_000)
        try "{\"pad\":\"\(padding)\",\"k\":\"token_count\"}\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try JSONLStreamReader.readLines(from: url, startingAt: 0, markers: ["token_count"])
        XCTAssertEqual(result.lines.count, 1)
    }
}
