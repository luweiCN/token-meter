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

    func testClaudeParserDoesNotCopyPrivateTextIntoRawMetadata() throws {
        let lines = [
            JSONLLine(text: #"{"type":"summary","summary":"SECRET_SUMMARY_SHOULD_NOT_BE_INDEXED","leafUuid":"claude-privacy"}"#, offset: 0, nextOffset: 1),
            JSONLLine(text: #"{"sessionId":"claude-privacy","type":"assistant","requestId":"req-privacy","message":{"id":"msg-privacy","model":"claude-sonnet","usage":{"input_tokens":1,"output_tokens":2},"content":[{"type":"text","text":"SECRET_ASSISTANT_SHOULD_NOT_BE_INDEXED"}],"toolUseResult":{"content":"SECRET_TOOL_OUTPUT_SHOULD_NOT_BE_INDEXED"}}}"#, offset: 1, nextOffset: 2)
        ]

        let parsed = try ClaudeCodeSessionParser().parse(lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/claude.jsonl"))

        XCTAssertFalse(parsed.rawMeta.values.contains { value in
            value.contains("SECRET_SUMMARY_SHOULD_NOT_BE_INDEXED")
                || value.contains("SECRET_ASSISTANT_SHOULD_NOT_BE_INDEXED")
                || value.contains("SECRET_TOOL_OUTPUT_SHOULD_NOT_BE_INDEXED")
        })
    }

    func testOmpParserDoesNotCopyPrivateTextIntoRawMetadata() throws {
        let lines = [
            JSONLLine(text: #"{"type":"session","id":"omp-privacy","cwd":"/repo"}"#, offset: 0, nextOffset: 1),
            JSONLLine(text: #"{"type":"message","message":{"role":"assistant","content":"SECRET_OMP_ASSISTANT_SHOULD_NOT_BE_INDEXED","tool":{"output":"SECRET_OMP_TOOL_SHOULD_NOT_BE_INDEXED"},"usage":{"inputTokens":1,"outputTokens":2}}}"#, offset: 1, nextOffset: 2)
        ]

        let parsed = try OmpSessionParser().parse(lines: lines, sourceURL: URL(fileURLWithPath: "/tmp/omp.jsonl"))

        XCTAssertFalse(parsed.rawMeta.values.contains { value in
            value.contains("SECRET_OMP_ASSISTANT_SHOULD_NOT_BE_INDEXED")
                || value.contains("SECRET_OMP_TOOL_SHOULD_NOT_BE_INDEXED")
        })
    }
}
