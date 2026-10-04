import XCTest
@testable import TokenMeterCore

@MainActor
final class CodexResetAutomationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func database() throws -> SQLiteDatabase {
        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)
        return database
    }

    private func state(seconds: TimeInterval = 1_800, fingerprint: String = "quota-a") -> CodexAccountState {
        CodexAccountState(
            accountFingerprint: "account-a", availableCount: 2,
            credits: [
                CodexRedeemableCredit(id: "later", resetType: "codexRateLimits", status: "available", grantedAt: now, expiresAt: now.addingTimeInterval(86_400)),
                CodexRedeemableCredit(id: "soon", resetType: "codexRateLimits", status: "available", grantedAt: now, expiresAt: now.addingTimeInterval(seconds))
            ],
            quotaFingerprint: fingerprint, usageData: Data(), fetchedAt: now
        )
    }

    func testDisabledNeverReadsOrConsumes() async throws {
        let client = ResetClientFixture(state: state())
        let service = CodexResetAutomation(client: client, store: CodexResetRedemptionStore(database: try database()), now: { self.now })
        _ = await service.check(isEnabled: { false })
        XCTAssertEqual(client.readCount, 0)
        XCTAssertTrue(client.requests.isEmpty)
    }

    func testOnlyUnexpiredCardsWithinOneHourCanBeConsumed() async throws {
        for seconds in [3_601.0, 3_600, 1, 0, -1] {
            let client = ResetClientFixture(state: state(seconds: seconds))
            let service = CodexResetAutomation(client: client, store: CodexResetRedemptionStore(database: try database()), now: { self.now })
            _ = await service.check(isEnabled: { true })
            XCTAssertEqual(client.requests.count, seconds > 0 && seconds <= 3_600 ? 1 : 0, "seconds: \(seconds)")
            XCTAssertTrue(client.requests.allSatisfy { $0.creditID == "soon" })
        }
    }

    func testDisablingDuringReadPreventsConsumption() async throws {
        var enabled = true
        let client = ResetClientFixture(state: state())
        client.beforeReadReturns = { enabled = false }
        let service = CodexResetAutomation(client: client, store: CodexResetRedemptionStore(database: try database()), now: { self.now })
        _ = await service.check(isEnabled: { enabled })
        XCTAssertTrue(client.requests.isEmpty)
    }

    func testUncertainAttemptReusesKeyAfterRestartAndRebuild() async throws {
        let db = try database()
        var clock = now
        let client = ResetClientFixture(state: state())
        client.result = .failure(ResetFixtureError.offline)
        let first = CodexResetAutomation(client: client, store: CodexResetRedemptionStore(database: db), now: { clock })
        _ = await first.check(isEnabled: { true })
        let firstKey = try XCTUnwrap(client.requests.first?.key)
        try db.execute("PRAGMA user_version = 999")
        try TokenMeterDatabaseMigrator.migrate(db)
        clock = now.addingTimeInterval(121)
        client.state.fetchedAt = clock
        client.result = .success(.alreadyRedeemed)
        let restarted = CodexResetAutomation(client: client, store: CodexResetRedemptionStore(database: db), now: { clock })
        let succeeded = await restarted.check(isEnabled: { true })
        XCTAssertTrue(succeeded)
        XCTAssertEqual(client.requests.map(\.key), [firstKey, firstKey])
        XCTAssertEqual(client.requests.map(\.creditID), ["soon", "soon"])
        _ = await restarted.check(isEnabled: { true })
        XCTAssertEqual(client.requests.count, 2)
    }

    func testSuccessfulAttemptIsNotRepeatedWhenRefreshStillShowsCard() async throws {
        let client = ResetClientFixture(state: state())
        let store = CodexResetRedemptionStore(database: try database())
        let service = CodexResetAutomation(client: client, store: store, now: { self.now })
        _ = await service.check(isEnabled: { true })
        _ = await service.check(isEnabled: { true })
        XCTAssertEqual(client.requests.count, 1)
    }

    func testNothingToResetWaitsForNewQuotaState() async throws {
        let client = ResetClientFixture(state: state())
        client.result = .success(.nothingToReset)
        var clock = now
        let service = CodexResetAutomation(client: client, store: CodexResetRedemptionStore(database: try database()), now: { clock })
        _ = await service.check(isEnabled: { true })
        clock = now.addingTimeInterval(121)
        client.state.fetchedAt = clock
        _ = await service.check(isEnabled: { true })
        XCTAssertEqual(client.requests.count, 1)
        client.state.quotaFingerprint = "quota-b"
        _ = await service.check(isEnabled: { true })
        XCTAssertEqual(client.requests.count, 2)
        XCTAssertNotEqual(client.requests[0].key, client.requests[1].key)
    }

    func testMissingAccountDetailsAndStaleSnapshotsNeverConsume() async throws {
        for invalidCase in 0..<4 {
            let client = ResetClientFixture(state: state())
            switch invalidCase {
            case 0: client.state.accountFingerprint = nil
            case 1: client.state.credits = nil
            case 2: client.state.fetchedAt = now.addingTimeInterval(-61)
            default: client.state.credits = [CodexRedeemableCredit(id: "", resetType: "unknown", status: "available", grantedAt: nil, expiresAt: now.addingTimeInterval(30))]
            }
            let service = CodexResetAutomation(client: client, store: CodexResetRedemptionStore(database: try database()), now: { self.now })
            _ = await service.check(isEnabled: { true })
            XCTAssertTrue(client.requests.isEmpty)
        }
    }

    func testLeasePreventsAnotherOwnerFromSendingAndReusesKeyAfterExpiry() throws {
        let store = CodexResetRedemptionStore(database: try database())
        let first = try XCTUnwrap(store.claim(account: "account", credit: "credit", quota: "quota", owner: "one", now: now))
        XCTAssertNil(try store.claim(account: "account", credit: "credit", quota: "quota", owner: "two", now: now))
        let retry = try XCTUnwrap(store.claim(account: "account", credit: "credit", quota: "quota", owner: "two", now: now.addingTimeInterval(121)))
        XCTAssertEqual(first.key, retry.key)
    }

    func testJournalDoesNotStoreRawCreditIdentifier() async throws {
        let db = try database()
        let client = ResetClientFixture(state: state())
        let service = CodexResetAutomation(client: client, store: CodexResetRedemptionStore(database: db), now: { self.now })
        _ = await service.check(isEnabled: { true })
        let row = try XCTUnwrap(db.query("SELECT credit_hash, state FROM codex_reset_redemptions").first)
        XCTAssertNotEqual(row.string("credit_hash"), "soon")
        XCTAssertEqual(row.string("state"), "succeeded")
    }
}

private enum ResetFixtureError: Error { case offline }

@MainActor
private final class ResetClientFixture: CodexAccountServicing {
    struct Request { let creditID: String; let key: String }
    var state: CodexAccountState
    var result: Result<CodexResetOutcome, Error> = .success(.reset)
    var requests: [Request] = []
    var readCount = 0
    var beforeReadReturns: (() -> Void)?

    init(state: CodexAccountState) { self.state = state }

    func read() async throws -> CodexAccountState {
        readCount += 1
        beforeReadReturns?()
        return state
    }

    func consume(creditID: String, idempotencyKey: String, accountFingerprint: String) async throws -> CodexResetOutcome {
        requests.append(Request(creditID: creditID, key: idempotencyKey))
        return try result.get()
    }
}
