import Foundation

/// 按设置里的 enabledAgentKinds 对账各 coding agent 的 hooks/插件：
/// 开 = 注入上报条目，关 = 移除。自家条目以 command 尾注 「# tokenmeter-hook」
/// 识别（Muxy 同款标记法），herdr/Muxy/用户自有条目一概不碰。
/// 注意两家 hooks 改动都从下一个 agent 会话才生效（不可热重载）。
struct AgentHooksInstaller: Sendable {
    static let marker = "# tokenmeter-hook"

    let hookScriptPath: String
    let ompExtensionSource: URL
    let homeDirectory: URL

    init(hookScriptPath: String, ompExtensionSource: URL, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.hookScriptPath = hookScriptPath
        self.ompExtensionSource = ompExtensionSource
        self.homeDirectory = homeDirectory
    }

    static func bundled() -> AgentHooksInstaller {
        let resources = Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")
        return AgentHooksInstaller(
            hookScriptPath: resources.appendingPathComponent("hooks/tokenmeter-agent-hook.sh").path,
            ompExtensionSource: resources.appendingPathComponent("hooks/tokenmeter-omp-agent-state.ts")
        )
    }

    /// 事件 → 上报动作。Codex 没有 SessionEnd 事件，会话结束靠心跳停摆兜底
    /// （见 Electron 侧 isLive 判定）。
    /// blocked 的解除不靠专门事件：用户回应后必然跟着 UserPromptSubmit（回答提问）
    /// 或 PostToolUse（权限批准后工具跑完），heartbeat 顺路清掉。
    static let claudeEvents: [(hook: String, action: String)] = [
        ("SessionStart", "start"),
        ("UserPromptSubmit", "heartbeat"),
        // PostToolUse 兼两职：长任务心跳（防 5 分钟停摆误灭）+ 权限批准后及时解除 blocked。
        ("PostToolUse", "heartbeat"),
        ("Stop", "heartbeat"),
        // PermissionRequest 在权限确认弹出时即刻触发；Notification 兜底覆盖
        // 「等输入超过 60 秒」（含 AskUserQuestion 待答）——都算 blocked。
        ("PermissionRequest", "blocked"),
        ("Notification", "blocked"),
        ("SessionEnd", "stop")
    ]
    static let codexEvents: [(hook: String, action: String)] = [
        ("SessionStart", "start"),
        ("UserPromptSubmit", "heartbeat"),
        ("Stop", "heartbeat"),
        // Codex 没有 SessionEnd，退出只能靠心跳停摆兜底——PostToolUse 提高心跳
        // 密度（长任务期间工具调用不断），停摆窗口才能压到 5 分钟。
        ("PostToolUse", "heartbeat"),
        ("PermissionRequest", "blocked")
    ]

    /// 幂等对账：失败静默（下次设置变更/启动会重试），实际装没装以
    /// installedState() 的文件事实为准。
    func sync(enabledKinds: Set<String>) {
        try? syncHooksFile(
            at: claudeSettingsURL,
            events: Self.claudeEvents,
            agentKind: "claudeCode",
            enabled: enabledKinds.contains("claudeCode")
        )
        try? syncHooksFile(
            at: codexHooksURL,
            events: Self.codexEvents,
            agentKind: "codex",
            enabled: enabledKinds.contains("codex")
        )
        try? syncOmpExtension(enabled: enabledKinds.contains("omp"))
    }

    func installedState() -> [String: Bool] {
        [
            "claudeCode": hooksFileHasMarker(claudeSettingsURL),
            "codex": hooksFileHasMarker(codexHooksURL),
            "omp": FileManager.default.fileExists(atPath: ompExtensionDestination.path)
        ]
    }

    var claudeSettingsURL: URL {
        homeDirectory.appendingPathComponent(".claude/settings.json")
    }

    var codexHooksURL: URL {
        homeDirectory.appendingPathComponent(".codex/hooks.json")
    }

    var ompExtensionDestination: URL {
        homeDirectory.appendingPathComponent(".omp/agent/extensions/tokenmeter-omp-agent-state.ts")
    }

    private func hooksFileHasMarker(_ url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.contains(Self.marker)
    }

    private func syncHooksFile(
        at url: URL,
        events: [(hook: String, action: String)],
        agentKind: String,
        enabled: Bool
    ) throws {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // 文件存在但不是合法 JSON：绝不覆写，宁可不装。
                return
            }
            root = parsed
        } else if !enabled {
            // 文件不存在且要求卸载：无事可做。
            return
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]

        // 先把自家旧条目全部清掉（含旧脚本路径的），再按需追加——天然幂等。
        for (event, entries) in hooks {
            guard var array = entries as? [[String: Any]] else { continue }
            array.removeAll(where: Self.isTokenMeterEntry)
            if array.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = array
            }
        }

        if enabled {
            for (event, action) in events {
                var array = hooks[event] as? [[String: Any]] ?? []
                array.append([
                    "matcher": "",
                    "hooks": [[
                        "type": "command",
                        "command": "'\(hookScriptPath)' \(agentKind) \(action) \(Self.marker)",
                        "timeout": 10
                    ] as [String: Any]]
                ])
                hooks[event] = array
            }
        }

        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private static func isTokenMeterEntry(_ entry: [String: Any]) -> Bool {
        guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
        return inner.contains { hook in
            (hook["command"] as? String)?.contains(marker) == true
        }
    }

    private func syncOmpExtension(enabled: Bool) throws {
        let fileManager = FileManager.default
        let destination = ompExtensionDestination
        if enabled {
            // ~/.omp/agent 不存在 = 本机没装 OMP，不无中生有制造目录。
            let agentDir = destination.deletingLastPathComponent().deletingLastPathComponent()
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: agentDir.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return
            }
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Data(contentsOf: ompExtensionSource)
            try data.write(to: destination, options: .atomic)
        } else if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
    }
}
