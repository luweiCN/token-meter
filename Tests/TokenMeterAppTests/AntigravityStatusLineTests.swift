import XCTest
@testable import TokenMeterApp
@testable import TokenMeterCore

final class AntigravityStatusLineTests: XCTestCase {
    private func inHome(_ body: (AntigravityStatusLine, URL, URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appendingPathComponent(".gemini/antigravity-cli/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let executable = home.appendingPathComponent("user's TokenMeter")
        try Data("#!/bin/sh\ncat\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try body(AntigravityStatusLine(executable: executable, home: home), settings, AntigravityQuota.cacheURL(home: home))
    }

    private func document(_ file: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }

    func testDefaultTerminalLineAndUserChangesSurviveEnableDisable() throws {
        try inHome { installer, settings, cache in
            let original = Data(#"{"trustedWorkspaces":["/example"]}"#.utf8)
            try original.write(to: settings)
            try installer.setEnabled(false)
            XCTAssertEqual(try Data(contentsOf: settings), original)
            try installer.setEnabled(true)
            var config = try document(settings)
            let line = try XCTUnwrap(config["statusLine"] as? [String: Any])
            XCTAssertEqual(line["stack_with_default"] as? Bool, true)
            XCTAssertFalse((line["command"] as? String)?.contains("--passthrough") ?? true)
            let first = try Data(contentsOf: settings)
            try installer.setEnabled(true)
            XCTAssertEqual(try Data(contentsOf: settings), first)
            config["anotherSetting"] = true
            try JSONSerialization.data(withJSONObject: config).write(to: settings)
            try AntigravityQuota.writePrivate(Data("{}".utf8), to: cache)
            try installer.setEnabled(false)
            let restored = try document(settings)
            XCTAssertNil(restored["statusLine"])
            XCTAssertEqual(restored["anotherSetting"] as? Bool, true)
            XCTAssertEqual(restored["trustedWorkspaces"] as? [String], ["/example"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: AntigravityQuota.connectionURL(for: cache).path))
        }
    }

    func testCustomCommandReceivesOriginalInputAndIsRestored() throws {
        try inHome { installer, settings, _ in
            let original: [String: Any] = ["command": "tr a-z A-Z", "type": "command", "stack_with_default": false]
            try JSONSerialization.data(withJSONObject: ["statusLine": original]).write(to: settings)
            try installer.setEnabled(true)
            let line = try XCTUnwrap(try document(settings)["statusLine"] as? [String: Any])
            XCTAssertEqual(line["stack_with_default"] as? Bool, false)
            let command = try XCTUnwrap(line["command"] as? String)
            let process = Process(), out = Pipe(), input = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.standardInput = input
            process.standardOutput = out
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: Data("my custom output\n".utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(out.fileHandleForReading.readDataToEndOfFile(), Data("MY CUSTOM OUTPUT\n".utf8))
            try installer.setEnabled(false)
            let restored = try XCTUnwrap(try document(settings)["statusLine"] as? [String: Any])
            XCTAssertTrue(NSDictionary(dictionary: restored).isEqual(to: original))
        }
    }

    func testUserReplacingCommandKeepsTheirNewConfiguration() throws {
        try inHome { installer, settings, _ in
            try installer.setEnabled(true)
            let replacement = Data(#"{"statusLine":{"command":"echo mine"}}"#.utf8)
            try replacement.write(to: settings)
            try installer.setEnabled(false)
            XCTAssertEqual(try Data(contentsOf: settings), replacement)
            let invalid = Data("invalid json".utf8)
            try invalid.write(to: settings)
            XCTAssertThrowsError(try installer.setEnabled(true))
            XCTAssertEqual(try Data(contentsOf: settings), invalid)
        }
    }

    func testCustomCommandMayCloseInputEarly() throws {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let helper = Process(), input = Pipe(), output = Pipe()
        helper.executableURL = products.appendingPathComponent("TokenMeterApp")
        helper.arguments = [AntigravityQuota.captureArgument, "--passthrough"]
        helper.standardInput = input
        helper.standardOutput = output.fileHandleForWriting
        try output.fileHandleForReading.close()
        try helper.run()
        try input.fileHandleForWriting.write(contentsOf: Data("{}".utf8))
        try input.fileHandleForWriting.close()
        helper.waitUntilExit()
        XCTAssertEqual(helper.terminationStatus, 0)
    }

    @MainActor
    func testStaleRefreshPreservesFailureAgeAndManualRetryRestoresShortWindows() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = AntigravityQuota.cacheURL(home: home)
        try AntigravityQuota.withCacheLock(at: cache) {
            try AntigravityQuota.writePrivate(Data("{}".utf8), to: AntigravityQuota.connectionURL(for: cache))
        }
        let old = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 16 * 3600)
        let buckets = Data(#"{"quota":{"gemini-5h":{"remaining_fraction":1,"reset_in_seconds":18000},"gemini-weekly":{"remaining_fraction":1,"reset_in_seconds":604800}}}"#.utf8)
        XCTAssertTrue(try AntigravityQuota.capture(buckets, at: cache, now: old))
        let source = ProviderConfig(id: "antigravity", type: .antigravity, displayName: "Antigravity",
                                    enabled: true, credential: nil, endpoint: nil, manualUsage: nil)
        var attempts = 0
        let store = ProviderStore(config: TokenMeterConfig(menuBar: MenuBarConfig(primaryProviderId: nil), providers: [source]),
                                  databaseURL: nil, antigravityCache: cache) { _ in
            attempts += 1
            if attempts == 1 { throw AntigravityQueryError.location }
            let json = Data(#"{"gemini-5h":{"remaining_fraction":0.7},"gemini-weekly":{"remaining_fraction":0.8}}"#.utf8)
            let report = try AntigravityQuota.parseStatusBuckets(json, now: Date())
            try report.save(at: cache, supersededAfter: Date(), coalesce: false)
        }
        await store.refreshAntigravityIfNeeded()?.value
        let failed = try XCTUnwrap(store.displayProviderSnapshots.first { $0.providerId == source.id })
        XCTAssertEqual(failed.fetchedAt, old)
        XCTAssertEqual(failed.message, AntigravityQueryError.location.errorDescription)
        XCTAssertEqual(failed.status, .warning)
        XCTAssertEqual(QuotaDisplayModel(snapshot: failed).summaryText, "7d 100%")
        let observed = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        XCTAssertTrue(try AntigravityQuota.capture(buckets, at: cache, now: observed))
        await store.antigravityDidReceiveQuota()
        let fromCLI = try XCTUnwrap(store.displayProviderSnapshots.first { $0.providerId == source.id })
        XCTAssertEqual(fromCLI.fetchedAt, observed)
        XCTAssertEqual(QuotaDisplayModel(snapshot: fromCLI).summaryText, "5h 100% · 7d 100%")
        XCTAssertEqual(fromCLI.status, .ok)
        XCTAssertNil(fromCLI.message)
        await store.refreshAntigravityIfNeeded()?.value
        XCTAssertEqual(attempts, 1)
        let pending = store.refreshAntigravityIfNeeded()
        await store.retryQuota(for: source.id)
        await pending?.value
        let fresh = try XCTUnwrap(store.displayProviderSnapshots.first { $0.providerId == source.id })
        XCTAssertEqual(fresh.status, .ok)
        XCTAssertNil(fresh.message)
        XCTAssertEqual(QuotaDisplayModel(snapshot: fresh).summaryText, "5h 70% · 7d 80%")
        await store.refreshAntigravityIfNeeded()?.value
        XCTAssertEqual(attempts, 2)
        store.isScanPaused = true
        await store.retryQuota(for: source.id)
        XCTAssertEqual(attempts, 2)
    }

    @MainActor
    func testCachedEpochResetDisplaysBothClaudeGPTBarsWithoutCountdown() throws {
        try inHome { installer, _, cache in
            try installer.setEnabled(true)
            let legacy = Data(#"""
            {"observedAt":"2026-11-24T04:49:42Z","buckets":{
              "gemini-weekly":{"fraction":1,"resetAt":"2026-12-01T04:49:42Z"},
              "3p-5h":{"fraction":1,"resetAt":"1970-01-01T00:00:00Z"},
              "3p-weekly":{"fraction":1,"resetAt":"1970-01-01T00:00:00Z"},
              "expired":{"fraction":0.8,"resetAt":"2026-11-24T04:49:00Z"}}}
            """#.utf8)
            try legacy.write(to: cache)
            let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-24T04:50:00Z"))
            let config = try XCTUnwrap(ProviderConfigLoader.defaultConfig().providers.first { $0.type == .antigravity })
            let snapshot = AntigravityUsageProvider(config: config, cache: cache).snapshot(at: now)
            let card = QuotaDisplayModel(snapshot: snapshot, now: now)
            XCTAssertEqual(card.bars.map(\.label), ["Claude/GPT 5h", "Claude/GPT 7d"])
            XCTAssertEqual(card.bars.compactMap(\.percent), [100, 100])
            XCTAssertTrue(card.bars.allSatisfy { $0.resetText == nil })
        }
    }

    @MainActor
    func testMenuShowsScopedLabelsAndOnlyGeminiRings() throws {
        try inHome { installer, _, cache in
            try installer.setEnabled(true)
            let bytes = Data(#"{"quota":{"gemini-5h":{"remaining_fraction":1},"gemini-weekly":{"remaining_fraction":0.5},"3p-5h":{"remaining_fraction":0.4},"3p-weekly":{"remaining_fraction":0},"gemini-argon-wtu-weekly":{"remaining_fraction":0.75},"absolute":{"remaining_amount":17}}}"#.utf8)
            XCTAssertTrue(try AntigravityQuota.capture(bytes, at: cache))
            let config = try XCTUnwrap(ProviderConfigLoader.defaultConfig().providers.first { $0.type == .antigravity })
            let snapshot = AntigravityUsageProvider(config: config, cache: cache).snapshot(at: Date())
            let card = QuotaDisplayModel(snapshot: snapshot)
            XCTAssertEqual(card.rings.map(\.label), ["Gemini 5h", "Gemini 7d"])
            XCTAssertEqual(card.menuBarWindows.map(\.label), ["5h", "7d"])
            XCTAssertEqual(card.name, "AGY")
            XCTAssertEqual(card.summaryText, "5h 100% · 7d 50%")
            XCTAssertEqual(AntigravityUsageProvider.menuName("Antigravity"), "AGY")
            XCTAssertEqual(AntigravityUsageProvider.menuName("我的 Google"), "我的 Google")
            XCTAssertEqual(card.bars.map(\.label), ["Claude/GPT 5h", "Claude/GPT 7d", "Gemini Argon WTU 7d"])
            XCTAssertEqual(card.bars.map(\.percent), [40, 0, 75])
            XCTAssertEqual(card.creditDetails.first?.0, "absolute")
            XCTAssertNil(snapshot.accountCredits)
        }
    }
}
