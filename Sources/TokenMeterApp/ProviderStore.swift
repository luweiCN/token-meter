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

    let config: TokenMeterConfig
    private let providers: [UsageProvider]
    private var refreshGate = RefreshGate(minimumInterval: 300)
    private let snapshotCacheURL: URL
    private weak var notificationCenter: UsageNotificationDelivering?
    private let database: SQLiteDatabase?
    private let settingsStore: SettingsStore?
    private let scanner: LocalAgentScanner?

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

        if let openedDatabase, let settingsStore {
            do {
                try TokenMeterDatabaseMigrator.migrate(openedDatabase)
                try settingsStore.importConfigIfNeeded(config)
                self.settingsSnapshot = try settingsStore.snapshot()
            } catch {
                self.localIndexStatusText = "本地会话索引不可用"
            }
        }
        refreshGate = RefreshGate(minimumInterval: TimeInterval(settingsSnapshot?.autoRefreshSeconds ?? 300))

        let cachedSnapshots = (try? ProviderSnapshotDiskCache.read(from: snapshotCacheURL)) ?? []
        self.providerSnapshots = cachedSnapshots
        self.snapshots = cachedSnapshots.map(\.legacySnapshot)
    }

    func refresh() async {
        guard !isRefreshing else {
            return
        }

        guard refreshGate.shouldRefresh() else {
            return
        }

        isRefreshing = true
        let previousProviderSnapshots = providerSnapshots
        var nextProviderSnapshots: [ProviderUsageSnapshot] = []

        for provider in providers {
            let snapshot = await provider.fetchProviderUsage()
            nextProviderSnapshots.append(snapshot)
        }

        let mergedProviderSnapshots = ProviderSnapshotCache.merge(
            previous: providerSnapshots,
            refreshed: nextProviderSnapshots
        )
        let notificationEvents = UsageNotificationEventDetector.events(
            previous: previousProviderSnapshots,
            current: mergedProviderSnapshots
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
        refreshGate = RefreshGate(minimumInterval: TimeInterval(snapshot.autoRefreshSeconds))
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

    @discardableResult
    func refreshLocalAgentIndex() async -> LocalIndexRefreshResult {
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
            localIndexStatusText = "已更新 \(scanned) 个本地会话来源"
            status = .ok
        } else {
            localIndexStatusText = "没有已启用的本地会话来源"
            status = .ok
        }

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
