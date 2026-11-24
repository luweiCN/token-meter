import XCTest
@testable import TokenMeterCore

final class AntigravityQuotaTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func withCache(_ body: (URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = AntigravityQuota.cacheURL(home: home)
        try AntigravityQuota.withCacheLock(at: cache) {
            try AntigravityQuota.writePrivate(Data("{}".utf8), to: AntigravityQuota.connectionURL(for: cache))
        }
        try body(cache)
    }

    func testKeepsIndependentWindowsAndDiscardsConversationData() throws {
        let data = Data(#"""
        {"email":"private@example.invalid","context_window":{"remaining_percentage":0},"cost":{"total_usd":76},
         "quota":{"gemini-5h":{"remaining_fraction":0,"reset_in_seconds":3600},
         "gemini-weekly":{"remaining_fraction":0.75,"reset_in_seconds":604000},
         "3p-5h":{"remaining_fraction":0.9},"3p-weekly":{"remaining_fraction":1},
         "gemini-argon-wtu-weekly":{"remaining_fraction":0.45},"new-limit":{"remaining_amount":15},
         "malformed":{"remaining_fraction":"unknown"},"invalid":{"remaining_fraction":3},
         "hidden":{"remaining_fraction":1,"disabled":true}}}
        """#.utf8)
        try withCache { cache in
            XCTAssertTrue(try AntigravityQuota.capture(data, at: cache, now: now))
            XCTAssertFalse(try AntigravityQuota.capture(data, at: cache, now: now))
            let raw = try String(contentsOf: cache, encoding: .utf8)
            for marker in ["private@", "context_window", "total_usd", "malformed", "hidden"] {
                XCTAssertFalse(raw.contains(marker))
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: cache.path)
            XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, 0o600)
            let config = try XCTUnwrap(ProviderConfigLoader.defaultConfig().providers.first { $0.type == .antigravity })
            XCTAssertFalse(config.enabled)
            let provider = AntigravityUsageProvider(config: config, cache: cache)
            let snapshot = provider.snapshot(at: now)
            XCTAssertEqual(snapshot.fetchedAt, now)
            XCTAssertEqual(snapshot.groups.map(\.title), ["Gemini", "Claude/GPT", "Gemini Argon WTU", "new-limit"])
            XCTAssertEqual(snapshot.groups[0].items.compactMap(\.remainingPercent), [0, 75])
            XCTAssertEqual(snapshot.groups[0].items.first?.resetText, "1h0m")
            XCTAssertEqual(snapshot.groups[1].items.compactMap(\.remainingPercent), [90, 100])
            XCTAssertEqual(snapshot.groups[2].items.first?.remainingPercent, 45)
            XCTAssertNil(snapshot.groups[3].items.first?.remainingPercent)
            XCTAssertEqual(snapshot.groups[3].items.first?.detail, "剩余 15")
            XCTAssertNil(snapshot.accountCredits)
            let later = provider.snapshot(at: now.addingTimeInterval(3600))
            XCTAssertEqual(later.groups[0].items.map(\.id), ["gemini-weekly"])
        }
    }

    func testMissingAndEmptyBalancesRemainUnknownAndSignOutClearsQuota() throws {
        try withCache { cache in
            let active = Data(#"{"quota":{"gemini-5h":{"remaining_fraction":1,"reset_time":"2028-03-11T04:00:00.731Z"}}}"#.utf8)
            XCTAssertTrue(try AntigravityQuota.capture(active, at: cache, now: now))
            XCTAssertFalse(try AntigravityQuota.capture(active, at: cache, now: now.addingTimeInterval(1)))
            let previous = try AntigravityQuota.read(cache)
            XCTAssertNotNil(previous.buckets["gemini-5h"]?.resetAt)
            for payload in [#"{"context_window":{"remaining_percentage":0}}"#, #"{"agent_state":"initializing","quota":{}}"#] {
                XCTAssertFalse(try AntigravityQuota.capture(Data(payload.utf8), at: cache, now: now))
            }
            XCTAssertEqual(try AntigravityQuota.read(cache), previous)
            XCTAssertTrue(try AntigravityQuota.capture(Data(#"{"agent_state":"authenticating"}"#.utf8), at: cache, now: now))
            XCTAssertTrue(try AntigravityQuota.read(cache).buckets.isEmpty)
            try FileManager.default.removeItem(at: AntigravityQuota.connectionURL(for: cache))
            XCTAssertFalse(try AntigravityQuota.capture(active, at: cache, now: now))
        }
    }

    func testUnknownResetKeepsQuotaAndUsesOnlyPositiveRelativeTimes() throws {
        let data = Data(#"""
        {"3p-5h":{"remaining_fraction":1,"reset_time":"1970-01-01T00:00:00Z","reset_in_seconds":0},
         "3p-weekly":{"remaining_fraction":0,"reset_time":"1970-01-01T00:00:00Z","reset_in_seconds":90},
         "without-date":{"remaining_fraction":0.5,"reset_in_seconds":0},
         "disabled":{"remaining_fraction":1,"reset_in_seconds":0,"disabled":true}}
        """#.utf8)
        let quota = try AntigravityQuota.parseStatusBuckets(data, now: now)
        XCTAssertEqual(quota.buckets["3p-5h"]?.fraction, 1)
        XCTAssertNil(quota.buckets["3p-5h"]?.resetAt)
        XCTAssertEqual(quota.buckets["3p-weekly"]?.resetAt, now.addingTimeInterval(90))
        XCTAssertNil(quota.buckets["without-date"]?.resetAt)
        XCTAssertNil(quota.buckets["disabled"])
    }

    func testOlderConfigurationCanOptInWithoutEnablingCaptureByDefault() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"providers":[]}"#.utf8).write(to: file)
        let config = try ProviderConfigLoader.load(from: file)
        XCTAssertEqual(config.providers.map(\.type), [.antigravity])
        XCTAssertFalse(config.providers[0].enabled)
        XCTAssertTrue(ProviderRegistry.makeProviders(from: config).isEmpty)
    }

    func testBackgroundAndSessionStatusShareBucketsAndPreserveNewerObservation() throws {
        let json = #"""
        {"gemini-5h":{"remaining_fraction":0.25,"reset_time":"2028-03-11T04:00:00Z"},
         "gemini-weekly":{"remaining_fraction":0},"gemini-argon-wtu-weekly":{"remaining_fraction":0.75},
         "3p-5h":{"remaining_fraction":1},"3p-weekly":{"remaining_fraction":0.4}}
        """#
        let report = try AntigravityQuota.parseStatusBuckets(Data(json.utf8), now: now)
        let status = try AntigravityQuota.parse(Data(#"{"quota":"#.utf8) + Data(json.utf8) + Data("}".utf8), now: now)
        XCTAssertEqual(report, status)
        XCTAssertEqual(report.buckets.count, 5)
        XCTAssertEqual(report.buckets["gemini-5h"]?.fraction, 0.25)
        XCTAssertNotNil(report.buckets["gemini-5h"]?.resetAt)
        XCTAssertEqual(report.buckets["gemini-weekly"]?.fraction, 0)
        try withCache { cache in
            XCTAssertTrue(try report.save(at: cache, supersededAfter: now, coalesce: false))
            XCTAssertEqual(try AntigravityQuota.read(cache), report)
            let next = now.addingTimeInterval(10)
            XCTAssertTrue(try AntigravityQuota.capture(Data(#"{"quota":{"new-window":{"remaining_fraction":0.5}}}"#.utf8), at: cache, now: next))
            XCTAssertFalse(try report.save(at: cache, supersededAfter: now, coalesce: false))
            XCTAssertEqual(try AntigravityQuota.read(cache).buckets["new-window"]?.fraction, 0.5)
            try FileManager.default.removeItem(at: AntigravityQuota.connectionURL(for: cache))
            XCTAssertFalse(try report.save(at: cache, supersededAfter: next, coalesce: false))
        }
        let invalid = try AntigravityQuota.parseStatusBuckets(Data(#"{"broken":{"remaining_fraction":3}}"#.utf8), now: now)
        XCTAssertTrue(invalid.buckets.isEmpty)
    }

    func testGoogleEligibilityErrorIsReportedWithoutAccountDetails() {
        XCTAssertEqual(AntigravityQueryError.failure("Eligibility check failed: Your current account is not eligible for Antigravity, because it is not currently available in your location."), .location)
        XCTAssertEqual(AntigravityQueryError.failure("Not authenticated: user@example.invalid"), .signIn)
        XCTAssertEqual(AntigravityQueryError.failure("OAuth error: invalid_grant"), .signIn)
        XCTAssertEqual(AntigravityQueryError.failure("OAuth transport unavailable"), .unavailable)
        XCTAssertEqual(AntigravityQueryError.failure("", diagnostic: "doRefreshQuota: skipped (not logged in)", timedOut: true), .timeout)
        XCTAssertEqual(AntigravityQueryError.failure("", diagnostic: "Print mode: triggering interactive OAuth", timedOut: true), .signIn)
        XCTAssertEqual(AntigravityQueryError.failure("unexpected response for user@example.invalid"), .unavailable)
    }

    func testBackgroundUsageCannotLaunchBrowserAndClassifiesFailedRenewal() throws {
        try withCache { cache in
            let directory = cache.deletingLastPathComponent()
            let cli = directory.appendingPathComponent("agy")
            let script = #"""
            #!/bin/sh
            /usr/bin/open --help >/dev/null 2>&1
            [ "$?" = 126 ] || exit 81
            while [ "$#" -gt 1 ] && [ "$1" != "--log-file" ]; do shift; done
            [ "$1" = "--log-file" ] || exit 82
            printf '%s\n' "$2" > observed-log-path
            echo 'token refresh failed due to network error: Post "https://oauth2.googleapis.com/token": EOF' > "$2"
            echo 'Print mode: triggering interactive OAuth' >> "$2"
            echo 'Authentication required' >&2
            exit 1
            """#
            try script.write(to: cli, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
            XCTAssertThrowsError(try AntigravityUsageProvider.backgroundQuota(cli: cli, home: directory)) {
                XCTAssertEqual($0 as? AntigravityQueryError, .authNetwork)
            }
            let path = try String(contentsOf: directory.appendingPathComponent("observed-log-path"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
    }

    func testBackgroundQuotaReadsFreshStatusWithoutASessionOrPromptAndStopsCLI() throws {
        try withCache { cache in
            let home = cache.deletingLastPathComponent()
            let cli = home.appendingPathComponent("agy")
            let script = #"""
            #!/bin/sh
            [ -t 0 ] && (exec 3<>/dev/tty) || exit 1
            echo $$ > query-pid
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --log-file) shift 2 ;;
                    --settings) settings="$2"; shift 2 ;;
                    *) exit 2 ;;
                esac
            done
            command=$(printf '%s' "$settings" | /usr/bin/plutil -extract statusLine.command raw -o - -- -) || exit 3
            printf '%s' '{"agent_state":"initializing","quota":{}}' | /bin/sh -c "$command"
            printf '%s' '{"agent_state":"idle","quota":{"gemini-5h":{"remaining_fraction":0},"3p-weekly":{"remaining_fraction":0.75}}}' | /bin/sh -c "$command"
            exec /bin/sleep 30
            """#
            try script.write(to: cli, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
            let quota = try AntigravityUsageProvider.backgroundQuota(cli: cli, home: home)
            XCTAssertEqual(quota.buckets["gemini-5h"]?.fraction, 0)
            XCTAssertEqual(quota.buckets["3p-weekly"]?.fraction, 0.75)
            let child = try String(contentsOf: home.appendingPathComponent("query-pid"), encoding: .utf8)
            let pid = try XCTUnwrap(Int32(child.trimmingCharacters(in: .whitespacesAndNewlines)))
            XCTAssertEqual(kill(pid, 0), -1)
            XCTAssertEqual(errno, ESRCH)
        }
    }

    func testBackgroundQuotaTimeoutStopsTheChildAndKeepsTheServiceError() throws {
        try withCache { cache in
            let home = cache.deletingLastPathComponent()
            let cli = home.appendingPathComponent("agy")
            let script = #"""
            #!/bin/sh
            [ "$1" = "--log-file" ] || exit 2
            printf '%s' 'Account ineligible: it is not currently available in your location.' > "$2"
            echo $$ > query-pid
            exec /bin/sleep 30
            """#
            try script.write(to: cli, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
            XCTAssertThrowsError(try AntigravityUsageProvider.backgroundQuota(cli: cli, home: home, timeout: 0.6)) {
                XCTAssertEqual($0 as? AntigravityQueryError, .location)
            }
            let child = try String(contentsOf: home.appendingPathComponent("query-pid"), encoding: .utf8)
            let pid = try XCTUnwrap(Int32(child.trimmingCharacters(in: .whitespacesAndNewlines)))
            XCTAssertEqual(kill(pid, 0), -1)
            XCTAssertEqual(errno, ESRCH)
        }
    }
}
