import XCTest
@testable import TokenMeterCore
import Foundation

final class DshIntegrationTests: XCTestCase {
    func testPricingCoversPreviouslyUnknownModels() throws {
        let snapshot = try PricingSnapshot.loadBundled()
        let calc = CostCalculator(snapshot: snapshot)
        let cases: [(model: String, input: Int64, output: Int64)] = [
            ("muse-spark-1.2-contributor", 1000, 500),
            ("gpt-5.3-codex-spark", 1000, 500),
            ("minimax-m2.7", 1000, 500),
            ("mimo-v2.5-pro", 1000, 500),
            ("k2p5", 1000, 500),
            ("codex-auto-review", 1000, 500),
        ]
        for (model, input, output) in cases {
            let event = UsageEvent(
                eventSeq: 1,
                observedAt: Date(),
                modelName: model,
                messageId: nil,
                dedupeKey: "test-\(model)",
                inputTokens: input,
                outputTokens: output,
                reasoningTokens: 0,
                cacheReadTokens: 0,
                cacheWrite5mTokens: 0,
                cacheWrite1hTokens: 0,
                reportedCostUSDMicros: nil,
                sourceOffset: 0,
                isSidechain: false
            )
            let (micros, source) = calc.cost(for: event)
            XCTAssertNotNil(micros, "\(model) should be priced, got unknown")
            XCTAssertEqual(source, .computed, "\(model) should be computed")
        }
    }

    func testDshScannerParsesPlainJsonl() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Create a fake DSH session: --Users-test--/session-abc/session.jsonl (plain, no zstd)
        let encodedCwd = "--Users-test--"
        let sessionId = "session-abc-123"
        let sessionDir = tmp.appendingPathComponent(encodedCwd).appendingPathComponent(sessionId)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let file = sessionDir.appendingPathComponent("session.jsonl")

        // Minimal DSH transcript with one assistant message containing usage
        let lines = [
            #"{"type":"session","id":"\#(sessionId)","createdAt":1787244321846,"cwd":"/Users/test","seedLength":0}"#,
            #"{"type":"request/header","seq":1,"time":1787244321848,"data":{"header":{"config":{"provider":"opencode-go","model":"muse-spark-1.2-contributor"}}}}"#,
            #"{"type":"assistant/message","seq":10,"time":1787244321900,"data":{"turn":1,"message":{"id":"msg-1","source":{"provider":"opencode-go","model":"muse-spark-1.2-contributor"}},"usage":{"inputTokens":100,"outputTokens":50,"cacheReadTokens":10,"reasoningTokens":5}}}"#
        ]
        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: file, atomically: true, encoding: .utf8)

        let db = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(db)
        // Seed DSH root pointing at tmp
        try db.execute(
            "INSERT INTO scan_roots(kind, root_path, display_name, stable_source_key) VALUES (?, ?, ?, ?)",
            [.text(SourceKind.dshJSONL.rawValue), .text(tmp.path), .text("DSH Test"), .text("dsh_jsonl:\(tmp.path)")]
        )
        let scanner = LocalAgentScanner(database: db)
        let roots = try db.query("SELECT id FROM scan_roots WHERE kind = ?", [.text(SourceKind.dshJSONL.rawValue)])
        for row in roots {
            try await scanner.scanRoot(id: row.int("id")!)
        }
        let count = try db.query("SELECT count(*) AS c FROM usage_events")[0].int("c") ?? 0
        XCTAssertEqual(count, 1, "Should parse 1 DSH event")
        let row = try db.query("SELECT model_name, tokens_input, tokens_output, tokens_reasoning FROM usage_events")[0]
        XCTAssertEqual(row.string("model_name"), "muse-spark-1.2-contributor")
        XCTAssertEqual(row.int("tokens_input"), 100)
        // output should be 50 - 5 = 45 (reasoning subtracted)
        XCTAssertEqual(row.int("tokens_output"), 45)
        XCTAssertEqual(row.int("tokens_reasoning"), 5)
    }
}
