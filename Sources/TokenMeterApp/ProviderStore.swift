import Combine
import Foundation
import TokenMeterCore

@MainActor
final class ProviderStore: ObservableObject {
    @Published private(set) var snapshots: [UsageSnapshot] = []
    @Published private(set) var providerSnapshots: [ProviderUsageSnapshot] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var notificationAuthorizationState: UsageNotificationAuthorizationState = .unknown
    @Published private(set) var settingsSnapshot: SettingsSnapshot?
    @Published private(set) var localIndexStatusText: String = "本地会话索引未启动"
    /// 弹窗头部「今日」汇总（OpenDesign 稿）；本地索引每次更新后重查。
    @Published private(set) var todaySummary: MenuBarTodaySummary = .empty
    @Published private(set) var localIndexUpdatedAt: Date?
    /// 弹窗底部「暂停扫描」（OpenDesign 稿）：暂停期间定时器照跳，但两类刷新都短路。
    @Published var isScanPaused = false
    /// refreshLocalAgentIndex 的 in-flight 互斥（MainActor 串行，但 await 让出时可重入）。
    private var isRefreshingLocalIndex = false

    let config: TokenMeterConfig
    private let providers: [UsageProvider]
    private var refreshGate = RefreshGate(minimumInterval: 300)
    private let snapshotCacheURL: URL
    private weak var notificationCenter: UsageNotificationDelivering?
    private let database: SQLiteDatabase?
    private let settingsStore: SettingsStore?
    private let scanner: LocalAgentScanner?
    private let liveSessions: LiveSessionStore?

    convenience init() {
        self.init(config: ProviderStore.loadConfig())
    }

    convenience init(notificationCenter: UsageNotificationDelivering?) {
        self.init(
            config: ProviderStore.loadConfig(),
            notificationCenter: notificationCenter,
            databaseURL: TokenMeterPaths.databaseURL()
        )
    }

    convenience init(config: TokenMeterConfig, notificationCenter: UsageNotificationDelivering? = nil) {
        self.init(
            config: config,
            notificationCenter: notificationCenter,
            databaseURL: TokenMeterPaths.databaseURL()
        )
    }

    init(config: TokenMeterConfig, notificationCenter: UsageNotificationDelivering? = nil, databaseURL: URL?) {
        self.config = config
        self.providers = ProviderRegistry.makeProviders(from: config)
        self.snapshotCacheURL = ProviderStore.snapshotCacheURL()
        self.notificationCenter = notificationCenter

        var openedDatabase: SQLiteDatabase?
        if let databaseURL {
            try? FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            openedDatabase = try? SQLiteDatabase(path: databaseURL.path)
        }

        self.database = openedDatabase
        self.settingsStore = openedDatabase.map(SettingsStore.init(database:))
        self.scanner = openedDatabase.map(LocalAgentScanner.init(database:))
        self.liveSessions = openedDatabase.map(LiveSessionStore.init(database:))

        if let openedDatabase, let settingsStore {
            do {
                try TokenMeterDatabaseMigrator.migrate(openedDatabase)
                try settingsStore.importConfigIfNeeded(config)
                self.settingsSnapshot = try settingsStore.snapshot()
                // 瞬态表：上个进程留下的 live 会话状态全部作废。
                try liveSessions?.clearAll()
            } catch {
                self.localIndexStatusText = "本地会话索引不可用"
            }
        }
        // 额度 API 刷新与本地扫描解耦：扫描便宜、跟 autoRefreshSeconds（可到 60s）；
        // 额度接口敏感（Claude oauth/usage 实测高频会持续 429），至少 5 分钟一次。
        refreshGate = RefreshGate(minimumInterval: max(300, TimeInterval(settingsSnapshot?.autoRefreshSeconds ?? 300)))

        let cachedSnapshots = (try? ProviderSnapshotDiskCache.read(from: snapshotCacheURL)) ?? []
        self.providerSnapshots = cachedSnapshots
        self.snapshots = cachedSnapshots.map(\.legacySnapshot)
    }

    /// 设置页的供应商启停（provider_config_overrides.enabled）。没写过 override 的默认启用。
    func isProviderEnabled(_ providerId: String) -> Bool {
        guard let enabled = settingsSnapshot?.providerOverrides
            .first(where: { $0.providerId == providerId })?.enabled else {
            return true
        }
        return enabled
    }

    /// 弹窗与状态栏消费的展示投影：过滤停用的供应商 + 应用别名（displayName override）。
    /// 底层 providerSnapshots 保持固有名与全集——磁盘缓存与通知对比都用它，
    /// 启停/别名改动（settingsSnapshot 变化）即时反映，无需重新取数。
    var displayProviderSnapshots: [ProviderUsageSnapshot] {
        let visible = providerSnapshots.filter { isProviderEnabled($0.providerId) }
        guard let overrides = settingsSnapshot?.providerOverrides, !overrides.isEmpty else {
            return visible
        }
        var names: [String: String] = [:]
        for override in overrides {
            if let name = override.displayName, !name.isEmpty {
                names[override.providerId] = name
            }
        }
        guard !names.isEmpty else { return visible }
        return visible.map { snapshot in
            names[snapshot.providerId].map(snapshot.renamed(to:)) ?? snapshot
        }
    }

    func refresh() async {
        guard !isScanPaused else {
            return
        }

        guard !isRefreshing else {
            return
        }

        guard refreshGate.shouldRefresh() else {
            return
        }

        isRefreshing = true
        let previousProviderSnapshots = providerSnapshots
        var nextProviderSnapshots: [ProviderUsageSnapshot] = []

        for provider in providers where isProviderEnabled(provider.id) {
            let snapshot = await provider.fetchProviderUsage()
            nextProviderSnapshots.append(snapshot)
        }

        let mergedProviderSnapshots = ProviderSnapshotCache.merge(
            previous: providerSnapshots,
            refreshed: nextProviderSnapshots
        )
        let notificationEvents = UsageNotificationEventDetector.events(
            previous: previousProviderSnapshots,
            current: mergedProviderSnapshots,
            usedThresholdPercent: settingsSnapshot?.quotaUsedThresholdPercent ?? 0
        )
        providerSnapshots = mergedProviderSnapshots
        snapshots = mergedProviderSnapshots.map(\.legacySnapshot)
        try? ProviderSnapshotDiskCache.write(mergedProviderSnapshots, to: snapshotCacheURL)
        notificationCenter?.deliver(notificationEvents)
        isRefreshing = false
    }

    func refreshNotificationAuthorizationState() async {
        notificationAuthorizationState = await notificationCenter?.authorizationState() ?? .unknown
    }

    func requestNotificationAuthorization() async {
        notificationAuthorizationState = await notificationCenter?.requestAuthorization() ?? .unknown
    }

    func openNotificationSettings() {
        notificationCenter?.openNotificationSettings()
    }

    func reloadSettings(expectedVersion: Int? = nil) throws {
        guard let settingsStore else { throw ProviderStoreError.settingsUnavailable }
        let snapshot = try settingsStore.snapshot()
        if let expectedVersion, snapshot.version < expectedVersion {
            throw ProviderStoreError.settingsVersionBehind(expected: expectedVersion, actual: snapshot.version)
        }
        settingsSnapshot = snapshot
        refreshGate = RefreshGate(minimumInterval: max(300, TimeInterval(snapshot.autoRefreshSeconds)))
    }

    /// hooks 上报入口（IPC agent.sessionEvent）：写 live_sessions 表，
    /// Electron 的 isLive 判定直读该表。
    func applyAgentSessionEvent(_ event: AgentSessionEvent) throws {
        guard let liveSessions else {
            throw ProviderStoreError.liveSessionsUnavailable
        }
        try liveSessions.apply(event)
    }

    func seedDefaultScanRoots() {
        guard let database else {
            localIndexStatusText = "本地会话索引不可用"
            return
        }

        do {
            try LocalAgentScanner.seedDefaultScanRoots(database: database)
        } catch {
            localIndexStatusText = "本地会话索引不可用"
        }
    }

    /// 供 IPC 的流式全量重扫使用：scanner 本身不绑定 MainActor，取出引用后可在后台队列上跑，
    /// 避免几分钟的扫描占住 MainActor 冻结菜单栏。
    var localAgentScanner: LocalAgentScanner? { scanner }

    func reloadTodaySummary() {
        guard let database else { return }
        todaySummary = MenuBarTodaySummaryRepository.load(from: database)
    }

    @discardableResult
    func refreshLocalAgentIndex() async -> LocalIndexRefreshResult {
        guard !isScanPaused else {
            return LocalIndexRefreshResult(scanned: 0, failures: 0, status: .ok, message: "扫描已暂停")
        }

        // 单飞：await scanner 时会让出 MainActor，定时器 / IPC 双入口能重入本函数。
        // 不挡的话增量扫描会并发堆叠（实测 16 路把 CPU 顶到 150%+），必须显式互斥。
        guard !isRefreshingLocalIndex else {
            return LocalIndexRefreshResult(scanned: 0, failures: 0, status: .ok, message: "扫描已在进行")
        }
        isRefreshingLocalIndex = true
        defer { isRefreshingLocalIndex = false }

        guard let database, let scanner else {
            localIndexStatusText = "本地会话索引不可用"
            return LocalIndexRefreshResult(scanned: 0, failures: 0, status: .unavailable, message: localIndexStatusText)
        }

        let roots: [SQLiteRow]
        do {
            roots = try database.query(
                "SELECT id, kind FROM scan_roots WHERE enabled = 1 AND scan_mode != 'disabled' ORDER BY display_name ASC"
            )
        } catch {
            localIndexStatusText = "本地会话索引不可用"
            return LocalIndexRefreshResult(scanned: 0, failures: 0, status: .unavailable, message: localIndexStatusText)
        }

        let enabledKinds = enabledSourceKinds()
        var scanned = 0
        var failures = 0
        for row in roots {
            guard let id = row.int("id"),
                  let kindText = row.string("kind"),
                  let kind = SourceKind(rawValue: kindText),
                  enabledKinds.contains(kind) else { continue }
            do {
                try await scanner.scanRoot(id: id)
                scanned += 1
            } catch {
                failures += 1
            }
        }

        let status: LocalIndexRefreshStatus
        if failures > 0, scanned > 0 {
            localIndexStatusText = "本地会话索引部分失败"
            status = .partial
        } else if failures > 0 {
            localIndexStatusText = "本地会话索引更新失败"
            status = .failed
        } else if scanned > 0 {
            localIndexStatusText = "已更新 \(scanned) 个本地数据源"
            status = .ok
        } else {
            localIndexStatusText = "没有已启用的本地会话来源"
            status = .ok
        }

        if scanned > 0 {
            localIndexUpdatedAt = Date()
        }
        reloadTodaySummary()

        return LocalIndexRefreshResult(scanned: scanned, failures: failures, status: status, message: localIndexStatusText)
    }

    private func enabledSourceKinds() -> Set<SourceKind> {
        guard let settingsSnapshot else {
            return Set(SourceKind.allCasesForLocalIndex)
        }
        let enabledAgentKinds = settingsSnapshot.enabledAgentKinds.compactMap(LocalAgentKind.init(rawValue:))
        guard !enabledAgentKinds.isEmpty else { return [] }
        return Set(enabledAgentKinds.map(\.sourceKind))
    }

    nonisolated private static func loadConfig() -> TokenMeterConfig {
        let environment = ProcessInfo.processInfo.environment

        if let path = environment["TOKENMETER_CONFIG"],
           let config = try? ProviderConfigLoader.load(from: URL(fileURLWithPath: path)) {
            return config
        }

        let homeConfigURL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".token-meter/config.json")

        if let config = try? ProviderConfigLoader.load(from: homeConfigURL) {
            return config
        }

        return ProviderConfigLoader.defaultConfig()
    }

    nonisolated private static func snapshotCacheURL() -> URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".token-meter/cache/provider-snapshots.json")
    }
}

private extension SourceKind {
    static var allCasesForLocalIndex: [SourceKind] {
        [.claudeJSONL, .codexJSONL, .opencodeSQLite, .ompJSONL]
    }
}

private extension LocalAgentKind {
    var sourceKind: SourceKind {
        switch self {
        case .claudeCode:
            .claudeJSONL
        case .codex:
            .codexJSONL
        case .opencode:
            .opencodeSQLite
        case .omp:
            .ompJSONL
        }
    }
}

enum ProviderStoreError: Error {
    case settingsUnavailable
    case settingsVersionBehind(expected: Int, actual: Int)
    case liveSessionsUnavailable
}

enum LocalIndexRefreshStatus: String {
    case ok
    case partial
    case failed
    case unavailable
}

struct LocalIndexRefreshResult {
    let scanned: Int
    let failures: Int
    let status: LocalIndexRefreshStatus
    let message: String
}
