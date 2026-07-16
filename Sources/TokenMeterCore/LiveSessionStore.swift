import Foundation

/// hooks 上报的会话生命周期事件（IPC 方法 agent.sessionEvent 的领域形状）。
public struct AgentSessionEvent: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case start
        case heartbeat
        /// agent 停下来等用户（权限确认 / 提问 / 等输入）。heartbeat 或 stop 解除。
        case blocked
        case stop
    }

    /// 与 settings 的 enabledAgentKinds 同一命名空间。
    public static let allowedAgentKinds: Set<String> = ["claudeCode", "codex", "omp", "opencode"]

    public let agentKind: String
    public let sessionId: String
    public let kind: Kind
    public let cwd: String?
    /// 上报方的 agent 进程 pid（shell hook 取 $PPID、OMP 扩展取 process.pid）。
    /// start 事件据此把同进程的旧会话置 ended（/resume、/clear 切会话时旧会话
    /// 不再有任何事件）。解析不了就当没有——只损失互斥，不拒事件。
    public let ownerPid: Int?

    public init?(agentKind: String, sessionId: String, kind: String, cwd: String?, ownerPid: String? = nil) {
        guard Self.allowedAgentKinds.contains(agentKind),
              !sessionId.isEmpty,
              let parsedKind = Kind(rawValue: kind) else {
            return nil
        }
        self.agentKind = agentKind
        self.sessionId = sessionId
        self.kind = parsedKind
        self.cwd = cwd
        self.ownerPid = ownerPid.flatMap(Int.init)
    }
}

/// live_sessions 表的读写（表定义见 TokenMeterDatabaseSchema.runtimeTables）。
/// Electron 的 overviewRepository 直读同一张表判定 isLive / isBlocked——上报优先、
/// 未上报的 agent 回退「最近有事件写入」的推断。
public final class LiveSessionStore {
    private let database: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.database = database
    }

    /// app 启动时清空：上一次进程的 live 状态全部无意义。
    public func clearAll() throws {
        try database.execute("DELETE FROM live_sessions")
    }

    public func apply(_ event: AgentSessionEvent) throws {
        switch event.kind {
        case .start, .heartbeat, .blocked:
            if event.kind == .start, let ownerPid = event.ownerPid {
                // /resume、/clear：同一个 agent 进程换了会话，旧会话不会再有
                // 任何事件（Claude/Codex 切换都不发 SessionEnd），就地置 ended。
                // 按 (agent, pid) 互斥，多终端并行的不同进程互不影响。
                try database.execute(
                    """
                    UPDATE live_sessions SET state = 'ended', blocked = 0, last_seen_at = datetime('now')
                    WHERE agent_kind = ? AND owner_pid = ? AND session_id != ? AND state = 'running'
                    """,
                    [.text(event.agentKind), .int(Int64(ownerPid)), .text(event.sessionId)]
                )
            }
            try database.execute(
                """
                INSERT INTO live_sessions (agent_kind, session_id, cwd, owner_pid, state, blocked, started_at, last_seen_at)
                VALUES (?, ?, ?, ?, 'running', ?, datetime('now'), datetime('now'))
                ON CONFLICT(agent_kind, session_id) DO UPDATE SET
                  state = 'running',
                  blocked = excluded.blocked,
                  last_seen_at = datetime('now'),
                  cwd = COALESCE(excluded.cwd, live_sessions.cwd),
                  owner_pid = COALESCE(excluded.owner_pid, live_sessions.owner_pid)
                """,
                [
                    .text(event.agentKind),
                    .text(event.sessionId),
                    event.cwd.map(SQLiteValue.text) ?? .null,
                    event.ownerPid.map { SQLiteValue.int(Int64($0)) } ?? .null,
                    .int(event.kind == .blocked ? 1 : 0)
                ]
            )
        case .stop:
            try database.execute(
                "UPDATE live_sessions SET state = 'ended', blocked = 0, last_seen_at = datetime('now') WHERE agent_kind = ? AND session_id = ?",
                [.text(event.agentKind), .text(event.sessionId)]
            )
        }
    }

    public func runningSessions() throws -> [(agentKind: String, sessionId: String)] {
        try database.query(
            "SELECT agent_kind, session_id FROM live_sessions WHERE state = 'running' ORDER BY agent_kind, session_id"
        ).compactMap { row in
            guard let agentKind = row.string("agent_kind"), let sessionId = row.string("session_id") else {
                return nil
            }
            return (agentKind, sessionId)
        }
    }
}
