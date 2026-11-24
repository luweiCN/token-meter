import Foundation
import XCTest
@testable import TokenMeterCore

final class QwenUsageSnapshotAdapterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenmeter-qwen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testSelectsExactlyOneProjectionPerSessionByPrecedence() throws {
        try write(
            #"{"type":"system","subtype":"ui_telemetry","sessionId":"s-transcript","cwd":"/repo","version":"0.24.0","timestamp":"2026-09-20T10:00:00Z","systemPayload":{"uiEvent":{"event.name":"qwen-code.api_response","event.timestamp":"2026-09-20T10:01:00Z","response_id":"response-1","model":"qwen3-coder","input_token_count":100,"output_token_count":20,"cached_content_token_count":30,"thoughts_token_count":5,"total_token_count":125}}}"# + "\n",
            relativePath: "projects/repo/chats/s-transcript.jsonl"
        )
        // 同一会话的低优先级投影故意放大：若被相加，断言会立即失败。
        try write(
            #"{"id":"ledger-ignored","sessionId":"s-transcript","timestamp":"2026-09-20T10:02:00Z","model":"qwen3-coder","inputTokens":9000,"outputTokens":9000,"cachedTokens":0,"thoughtsTokens":0,"totalTokens":18000}"# + "\n" +
            #"{"id":"ledger-kept","sessionId":"s-ledger","timestamp":"2026-09-20T11:00:00Z","model":"qwen3-coder","inputTokens":200,"outputTokens":30,"cachedTokens":50,"thoughtsTokens":10,"totalTokens":240}"# + "\n",
            relativePath: "usage/token-usage-2026-09.jsonl"
        )
        try write(
            #"{"sessionId":"s-transcript","project":"/ignored","startTime":1789898400000,"timestamp":1789898520000,"models":{"qwen3-coder":{"inputTokens":7000,"outputTokens":7000,"cachedTokens":0,"thoughtsTokens":0,"totalTokens":14000}}}"# + "\n" +
            #"{"sessionId":"s-ledger","project":"/ledger","startTime":1789902000000,"timestamp":1789902060000,"models":{"qwen3-coder":{"inputTokens":6000,"outputTokens":6000,"cachedTokens":0,"thoughtsTokens":0,"totalTokens":12000}}}"# + "\n" +
            #"{"sessionId":"s-aggregate","project":"/aggregate","startTime":1789905600000,"timestamp":1789905660000,"models":{"qwen3-max":{"inputTokens":50,"outputTokens":7,"cachedTokens":10,"thoughtsTokens":2,"totalTokens":59}}}"# + "\n",
            relativePath: "usage_record.jsonl"
        )

        let snapshot = try QwenUsageSnapshotAdapter(rootURL: root).snapshot()
        let sessions = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.sessionKey, $0) })

        let transcript = try XCTUnwrap(sessions["s-transcript"])
        XCTAssertEqual(transcript.rawMeta["usageProjection"], "transcript")
        XCTAssertEqual(transcript.providerId, "qwen-code")
        XCTAssertEqual(transcript.projectPath, "/repo")
        XCTAssertEqual(transcript.cliVersion, "0.24.0")
        XCTAssertEqual(transcript.events.count, 1)
        XCTAssertEqual(transcript.events[0].inputTokens, 70)
        XCTAssertEqual(transcript.events[0].cacheReadTokens, 30)
        XCTAssertEqual(transcript.events[0].outputTokens, 25)
        XCTAssertEqual(transcript.events[0].reasoningTokens, 5)

        let ledger = try XCTUnwrap(sessions["s-ledger"])
        XCTAssertEqual(ledger.rawMeta["usageProjection"], "monthly-ledger")
        XCTAssertEqual(ledger.events.count, 1)
        XCTAssertEqual(ledger.events[0].inputTokens, 150)
        XCTAssertEqual(ledger.events[0].cacheReadTokens, 50)
        XCTAssertEqual(ledger.events[0].outputTokens, 40)

        let aggregate = try XCTUnwrap(sessions["s-aggregate"])
        XCTAssertEqual(aggregate.rawMeta["usageProjection"], "session-aggregate")
        XCTAssertEqual(aggregate.events.count, 1)
        XCTAssertEqual(aggregate.events[0].inputTokens, 40)
        XCTAssertEqual(aggregate.events[0].cacheReadTokens, 10)
        XCTAssertEqual(aggregate.events[0].outputTokens, 9)
        XCTAssertEqual(snapshot.sourceFiles.count, 3)
        XCTAssertFalse(snapshot.storageRevision.isEmpty)
    }

    func testDuplicateResponseKeepsMostCompleteFrame() throws {
        let first = #"{"type":"system","subtype":"ui_telemetry","sessionId":"s1","systemPayload":{"uiEvent":{"event.name":"qwen-code.api_response","event.timestamp":"2026-09-20T10:00:00Z","response_id":"same","input_token_count":10,"output_token_count":1,"total_token_count":11}}}"#
        let final = #"{"type":"system","subtype":"ui_telemetry","sessionId":"s1","systemPayload":{"uiEvent":{"event.name":"qwen-code.api_response","event.timestamp":"2026-09-20T10:00:01Z","response_id":"same","input_token_count":10,"output_token_count":9,"total_token_count":19}}}"#
        try write(first + "\n" + final + "\n", relativePath: "projects/repo/chats/s1.jsonl")

        let session = try XCTUnwrap(QwenUsageSnapshotAdapter(rootURL: root).snapshot().sessions.first)
        XCTAssertEqual(session.events.count, 1)
        XCTAssertEqual(session.events[0].totalTokens, 19)
    }

    func testTranscriptFallbackDoesNotDoubleCountOAuthThoughts() throws {
        try write(
            #"{"type":"system","subtype":"ui_telemetry","sessionId":"s-oauth","systemPayload":{"uiEvent":{"event.name":"qwen-code.api_response","event.timestamp":"2026-09-20T10:00:00Z","response_id":"oauth","auth_type":"qwen-oauth","input_token_count":10,"output_token_count":8,"thoughts_token_count":3,"total_token_count":0}}}"# + "\n" +
            #"{"type":"system","subtype":"ui_telemetry","sessionId":"s-oauth","systemPayload":{"uiEvent":{"event.name":"qwen-code.api_response","event.timestamp":"2026-09-20T10:01:00Z","response_id":"native","auth_type":"api-key","input_token_count":10,"output_token_count":8,"thoughts_token_count":3,"total_token_count":0}}}"# + "\n",
            relativePath: "projects/repo/chats/s-oauth.jsonl"
        )

        let events = try XCTUnwrap(QwenUsageSnapshotAdapter(rootURL: root).snapshot().sessions.first).events
        XCTAssertEqual(events.map(\.outputTokens), [8, 11])
        XCTAssertEqual(events.map(\.reasoningTokens), [3, 3])
        XCTAssertEqual(events.map(\.totalTokens), [18, 21])
    }

    func testStorageRevisionDetectsSameSizeRewriteWithPreservedModificationDate() throws {
        let relativePath = "usage/token-usage-2026-09.jsonl"
        let url = root.appendingPathComponent(relativePath)
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try write(
            #"{"id":"same","sessionId":"s","timestamp":1789898400000,"inputTokens":1}"# + "\n",
            relativePath: relativePath
        )
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: url.path)
        let first = try QwenUsageSnapshotAdapter(rootURL: root).snapshot().storageRevision

        try write(
            #"{"id":"same","sessionId":"s","timestamp":1789898400000,"inputTokens":2}"# + "\n",
            relativePath: relativePath
        )
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: url.path)
        let second = try QwenUsageSnapshotAdapter(rootURL: root).snapshot().storageRevision

        XCTAssertNotEqual(first, second)
    }

    func testReadsRuntimeLedgersAndHomeUsageHistoryFromSeparateRoots() throws {
        let homeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenmeter-qwen-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: homeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: homeRoot) }

        try write(
            #"{"id":"runtime","sessionId":"runtime-session","timestamp":1789898400000,"model":"qwen3-coder","inputTokens":10,"outputTokens":2,"totalTokens":12}"# + "\n",
            relativePath: "usage/token-usage-2026-09.jsonl"
        )
        try Data(
            (#"{"sessionId":"history-session","project":"/history","startTime":1789898400000,"timestamp":1789898460000,"models":{"qwen3-max":{"inputTokens":7,"outputTokens":3,"totalTokens":10}}}"# + "\n").utf8
        ).write(to: homeRoot.appendingPathComponent("usage_record.jsonl"))

        let snapshot = try QwenUsageSnapshotAdapter(
            rootURL: root,
            usageHistoryRootURL: homeRoot
        ).snapshot()

        XCTAssertEqual(Set(snapshot.sessions.map(\.sessionKey)), ["runtime-session", "history-session"])
        XCTAssertEqual(snapshot.sourceFiles.count, 2)
    }
}
