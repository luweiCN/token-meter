import XCTest
@testable import TokenMeterCore

final class PrivacyIndexingTests: XCTestCase {
    func testCodexParserDoesNotCopyMessageTextIntoRawMetadata() throws {
        let lines = [
            JSONLLine(text: #"{"type":"session_meta","payload":{"id":"session-privacy","cwd":"/repo"}}"#, offset: 0, nextOffset: 1),
            JSONLLine(text: #"{"type":"event_msg","payload":{"type":"message","content":"SECRET_PROMPT_SHOULD_NOT_BE_INDEXED"}}"#, offset: 1, nextOffset: 2),
            JSONLLine(text: #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,"output_tokens":2}}}}"#, offset: 2, nextOffset: 3)
        ]

        let parsed = try CodexSessionParser().parse(lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/codex.jsonl"))

        XCTAssertFalse(parsed.rawMeta.values.contains { $0.contains("SECRET_PROMPT_SHOULD_NOT_BE_INDEXED") })
    }
}
