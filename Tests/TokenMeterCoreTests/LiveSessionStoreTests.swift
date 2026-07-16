import XCTest
@testable import TokenMeterCore

final class LiveSessionStoreTests: XCTestCase {
    private func makeStore() throws -> (store: LiveSessionStore, database: SQLiteDatabase) {
        let database = try SQLiteDatabase(path: ":memory:")
        try database.execute(TokenMeterDatabaseSchema.runtimeTables)
        return (LiveSessionStore(database: database), database)
    }

    private func event(
        _ kind: String,
        agent: String = "claudeCode",
        sessionId: String = "s1",
        ownerPid: String? = nil
    ) -> AgentSessionEvent? {
        AgentSessionEvent(agentKind: agent, sessionId: sessionId, kind: kind, cwd: "/tmp/project", ownerPid: ownerPid)
    }

    func testStartThenStopTogglesRunningState() throws {
        let (store, _) = try makeStore()

        try store.apply(XCTUnwrap(event("start")))
        XCTAssertEqual(store.runningCount(), 1)

        try store.apply(XCTUnwrap(event("stop")))
        XCTAssertEqual(store.runningCount(), 0)
    }

    func testHeartbeatRevivesEndedSession() throws {
        let (store, _) = try makeStore()

        try store.apply(XCTUnwrap(event("start")))
        try store.apply(XCTUnwrap(event("stop")))
        try store.apply(XCTUnwrap(event("heartbeat")))

        XCTAssertEqual(try store.runningSessions().map(\.sessionId), ["s1"])
    }

    func testSessionsAreKeyedByAgentAndSessionId() throws {
        let (store, _) = try makeStore()

        try store.apply(XCTUnwrap(event("start", agent: "claudeCode", sessionId: "s1")))
        try store.apply(XCTUnwrap(event("start", agent: "codex", sessionId: "s1")))
        try store.apply(XCTUnwrap(event("stop", agent: "codex", sessionId: "s1")))

        XCTAssertEqual(try store.runningSessions().map(\.agentKind), ["claudeCode"])
    }

    func testClearAllRemovesEverything() throws {
        let (store, _) = try makeStore()

        try store.apply(XCTUnwrap(event("start")))
        try store.clearAll()

        XCTAssertEqual(store.runningCount(), 0)
    }

    func testRejectsUnknownAgentKindAndEmptySessionId() {
        XCTAssertNil(AgentSessionEvent(agentKind: "vim", sessionId: "s1", kind: "start", cwd: nil))
        XCTAssertNil(AgentSessionEvent(agentKind: "claudeCode", sessionId: "", kind: "start", cwd: nil))
        XCTAssertNil(AgentSessionEvent(agentKind: "claudeCode", sessionId: "s1", kind: "reboot", cwd: nil))
    }

    func testOwnerPidParsesDigitsAndSwallowsGarbage() throws {
        XCTAssertEqual(try XCTUnwrap(event("start", ownerPid: "4242")).ownerPid, 4242)
        // 坏 pid 只损失互斥能力，不拒事件。
        XCTAssertNil(try XCTUnwrap(event("start", ownerPid: "not-a-pid")).ownerPid)
        XCTAssertNil(try XCTUnwrap(event("start", ownerPid: "")).ownerPid)
        XCTAssertNil(try XCTUnwrap(event("start")).ownerPid)
    }

    func testStartEndsOtherRunningSessionsOfSameAgentProcess() throws {
        let (store, _) = try makeStore()

        // 同一个 Claude 进程（pid 100）先后跑 s1、/resume 到 s2：s1 必须熄灭。
        try store.apply(XCTUnwrap(event("start", sessionId: "s1", ownerPid: "100")))
        // 另一个终端（pid 200）与另一家 agent（同 pid 数值）都不受影响。
        try store.apply(XCTUnwrap(event("start", sessionId: "s3", ownerPid: "200")))
        try store.apply(XCTUnwrap(event("start", agent: "codex", sessionId: "c1", ownerPid: "100")))

        try store.apply(XCTUnwrap(event("start", sessionId: "s2", ownerPid: "100")))

        let running = try store.runningSessions().map(\.sessionId)
        XCTAssertEqual(running.sorted(), ["c1", "s2", "s3"])
    }

    func testStartWithoutOwnerPidDoesNotEndAnything() throws {
        let (store, _) = try makeStore()

        try store.apply(XCTUnwrap(event("start", sessionId: "s1", ownerPid: "100")))
        try store.apply(XCTUnwrap(event("start", sessionId: "s2")))

        XCTAssertEqual(try store.runningSessions().map(\.sessionId).sorted(), ["s1", "s2"])
    }

    func testCompactRestartOfSameSessionIsIdempotent() throws {
        let (store, _) = try makeStore()

        // /compact 会对同一个 session_id 再发一次 SessionStart：互斥排除自己，不许误杀。
        try store.apply(XCTUnwrap(event("start", sessionId: "s1", ownerPid: "100")))
        try store.apply(XCTUnwrap(event("start", sessionId: "s1", ownerPid: "100")))

        XCTAssertEqual(try store.runningSessions().map(\.sessionId), ["s1"])
    }

    func testBlockedLifecycle() throws {
        let (store, database) = try makeStore()
        func blockedFlag() throws -> Int64? {
            try database.query("SELECT blocked FROM live_sessions WHERE session_id = 's1'").first?.int("blocked")
        }

        try store.apply(XCTUnwrap(event("start", ownerPid: "100")))
        XCTAssertEqual(try blockedFlag(), 0)

        // 权限确认弹出：blocked，且会话仍算 running（活着，只是在等人）。
        try store.apply(XCTUnwrap(event("blocked")))
        XCTAssertEqual(try blockedFlag(), 1)
        XCTAssertEqual(try store.runningSessions().map(\.sessionId), ["s1"])

        // 批准后工具跑完（PostToolUse → heartbeat）：解除。
        try store.apply(XCTUnwrap(event("heartbeat")))
        XCTAssertEqual(try blockedFlag(), 0)

        // 再次阻塞后直接退出：stop 也要清 blocked。
        try store.apply(XCTUnwrap(event("blocked")))
        try store.apply(XCTUnwrap(event("stop")))
        XCTAssertEqual(try blockedFlag(), 0)
        XCTAssertEqual(store.runningCount(), 0)
    }

    func testBlockedEventForUnknownSessionInsertsRunningRow() throws {
        let (store, database) = try makeStore()

        // 装 hooks 前已开启的会话：第一条上报就是 blocked（如权限确认），也要立牌。
        try store.apply(XCTUnwrap(event("blocked", sessionId: "orphan", ownerPid: "300")))

        XCTAssertEqual(try store.runningSessions().map(\.sessionId), ["orphan"])
        XCTAssertEqual(
            try database.query("SELECT blocked FROM live_sessions WHERE session_id = 'orphan'").first?.int("blocked"),
            1
        )
    }

    func testMigratorRebuildKeepsLiveSessionsTable() throws {
        // derivedVersion 变更的启动会全删非配置表——live_sessions 必须在重建后依然存在。
        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)
        try database.execute("PRAGMA user_version = 0")

        try TokenMeterDatabaseMigrator.migrate(database)

        let store = LiveSessionStore(database: database)
        try store.apply(XCTUnwrap(event("start")))
        XCTAssertEqual(try store.runningSessions().map(\.sessionId), ["s1"])
    }
}

private extension LiveSessionStore {
    func runningCount() -> Int {
        (try? runningSessions().count) ?? -1
    }
}
