import XCTest
@testable import TokenMeterCore

final class AgentBinaryDetectorTests: XCTestCase {
    private var bin: URL!

    override func setUpWithError() throws {
        bin = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenmeter-agent-detect-\(UUID().uuidString)/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: bin.deletingLastPathComponent())
    }

    private func installFakeBinary(_ name: String, versionOutput: String) throws {
        let url = bin.appendingPathComponent(name)
        try "#!/bin/sh\necho '\(versionOutput)'\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func testDetectReportsFoundPathAndFirstVersionLine() throws {
        try installFakeBinary("claude", versionOutput: "2.1.207 (Claude Code)")
        try installFakeBinary("omp", versionOutput: "omp/16.4.8")

        let statuses = AgentBinaryDetector.detect(in: [bin.path])
        let byKind = Dictionary(uniqueKeysWithValues: statuses.map { ($0.kind, $0) })

        XCTAssertEqual(statuses.map(\.kind), ["claudeCode", "codex", "omp", "opencode"])
        XCTAssertEqual(byKind["claudeCode"]?.found, true)
        XCTAssertEqual(byKind["claudeCode"]?.path, bin.appendingPathComponent("claude").path)
        XCTAssertEqual(byKind["claudeCode"]?.version, "2.1.207 (Claude Code)")
        XCTAssertEqual(byKind["omp"]?.version, "omp/16.4.8")
        XCTAssertEqual(byKind["codex"]?.found, false)
        XCTAssertNil(byKind["codex"]?.path)
        XCTAssertEqual(byKind["opencode"]?.found, false)
    }

    func testVersionFailureStillCountsAsFound() throws {
        // --version 崩掉的 CLI：found 仍为真（文件确实在），版本留空。
        let url = bin.appendingPathComponent("codex")
        try "#!/bin/sh\nexit 1\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)

        let codex = AgentBinaryDetector.detect(in: [bin.path]).first { $0.kind == "codex" }

        XCTAssertEqual(codex?.found, true)
        XCTAssertNil(codex?.version)
    }

    func testNonExecutableFileIsNotFound() throws {
        let url = bin.appendingPathComponent("opencode")
        try "not a binary".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        let opencode = AgentBinaryDetector.detect(in: [bin.path]).first { $0.kind == "opencode" }

        XCTAssertEqual(opencode?.found, false)
    }
}
