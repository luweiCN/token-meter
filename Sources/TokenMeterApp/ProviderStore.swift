import AppKit
import Combine
import Foundation
import TokenMeterCore

/// 带峰谷价的模型与定价品牌。峰谷是【模型品牌】的定价策略，供应商只是计费
/// 通道；同一个模型无论通过 OpenCode Go、Command Code 还是直接 API 使用，
/// 都共享同一份时刻表。之后再有厂商采用分时定价，在这里补模型与品牌即可。
struct TieredPricingEntry: Equatable, Identifiable {
    let brandName: String
    let modelName: String
    let tier: PeakOffPeakPricing

    var id: String { "\(brandName)/\(modelName)" }
}

/// 弹窗「峰谷时段」区块的一行：同一定价品牌下所有带峰谷价的模型归并成一行。
struct PeakPricingRow: Equatable, Identifiable {
    let brandName: String
    let modelNames: [String]
    let tier: PeakOffPeakPricing

    var id: String { brandName }
}

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
    /// 当月每日用量（弹窗头部热力图）；与 todaySummary 同步刷新。
    @Published private(set) var monthActivity: [DayActivity] = []
    /// 总计/当月/本周三卡（主界面同口径）；与 todaySummary 同步刷新。
    @Published private(set) var overviewStats = OverviewStats.empty
    @Published private(set) var localIndexUpdatedAt: Date?
    /// 当前显示汇率（USD→CNY）。启动先读缓存/兜底，随后按需刷新。
    @Published private(set) var exchangeRate: ExchangeRate
    /// 弹窗底部「暂停扫描」（OpenDesign 稿）：暂停期间定时器照跳，但两类刷新都短路。
    @Published var isScanPaused = false {
        didSet {
            if isScanPaused { stopAntigravityRefresh() }
            else if oldValue { refreshAntigravityIfNeeded() }
        }
    }
    /// refreshLocalAgentIndex 的 in-flight 互斥（MainActor 串行，但 await 让出时可重入）。
    private var isRefreshingLocalIndex = false

    let config: TokenMeterConfig
    private let providers: [UsageProvider]
    let antigravityConfig: ProviderConfig?
    private let antigravityProvider: AntigravityUsageProvider?
    private let queryAntigravity: (AntigravityUsageProvider) async throws -> Void
    private var antigravityGeneration = 0
    var antigravityConnectionError: String?
    private var antigravityRefreshTask: Task<Void, Never>?
    private var antigravityForceRequested = false
    private var antigravityLastAttempt: Date?
    private var antigravityQueryError: AntigravityQueryError?
    @Published private(set) var isRefreshingAntigravity = false
    private let codexAccountClient = CodexAccountClient()
    private var codexResetAutomation: CodexResetAutomation?
    private var codexResetTask: Task<Void, Never>?
    private var refreshGate = RefreshGate(minimumInterval: 300)
    private let snapshotCacheURL: URL
    private weak var notificationCenter: UsageNotificationDelivering?
    private let database: SQLiteDatabase?
    private let databaseURL: URL?
    private var summaryGeneration = 0
    private let settingsStore: SettingsStore?
    private let scanner: LocalAgentScanner?
    private let liveSessions: LiveSessionStore?
    /// 所有带峰谷价的模型（与供应商无关）。读取当前生效的缓存/随包快照；加载失败时为空，
    /// 菜单栏标识与弹窗「峰谷时段」区块随之隐藏，不影响额度显示。
    @Published private(set) var tieredPricingEntries: [TieredPricingEntry]
    /// 峰谷价模型 → 定价品牌。上游快照只按模型计价，模型本身不标展示品牌，
    /// 这里补品牌归属；不再绑定任何额度供应商。
    static let tieredModelBrands: [String: String] = [
        "deepseek-v4-flash": "DeepSeek",
        "deepseek-v4-pro": "DeepSeek",
    ]

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

    init(config: TokenMeterConfig, notificationCenter: UsageNotificationDelivering? = nil, databaseURL: URL?,
         antigravityCache: URL = AntigravityQuota.cacheURL(),
         queryAntigravity: @escaping (AntigravityUsageProvider) async throws -> Void = { try await $0.refreshQuota() }) {
        self.config = config
        self.antigravityConfig = config.providers.first { $0.type == .antigravity }
        self.antigravityProvider = antigravityConfig.map { AntigravityUsageProvider(config: $0, cache: antigravityCache) }
        self.queryAntigravity = queryAntigravity
        self.providers = ProviderRegistry.makeProviders(from: config).filter { !($0 is AntigravityUsageProvider) }
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

        self.databaseURL = openedDatabase == nil ? nil : databaseURL
        self.database = openedDatabase
        self.settingsStore = openedDatabase.map(SettingsStore.init(database:))
        // 写入扫描和前台操作使用独立连接，避免等待同一 sqlite3 句柄的互斥锁。
        self.scanner = self.databaseURL.flatMap { url in
            guard let writer = try? SQLiteDatabase(path: url.path),
                  (try? TokenMeterDatabaseMigrator.configureWriter(writer)) != nil else { return nil }
            return LocalAgentScanner(database: writer)
        }
        self.liveSessions = openedDatabase.map(LiveSessionStore.init(database:))
        self.tieredPricingEntries = ProviderStore.loadTieredPricingEntries()
        self.exchangeRate = ExchangeRateProvider.cachedOrFallback()

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
        if let databaseURL, settingsSnapshot != nil,
           let journalDatabase = try? SQLiteDatabase(path: databaseURL.path) {
            codexResetAutomation = CodexResetAutomation(
                client: codexAccountClient,
                store: CodexResetRedemptionStore(database: journalDatabase)
            )
        }
        // 额度 API 刷新与本地扫描解耦：扫描便宜、跟 autoRefreshSeconds（可到 60s）；
        // 额度接口敏感（Claude oauth/usage 实测高频会持续 429），至少 5 分钟一次。
        refreshGate = RefreshGate(minimumInterval: max(300, TimeInterval(settingsSnapshot?.autoRefreshSeconds ?? 300)))

        let cachedSnapshots = (try? ProviderSnapshotDiskCache.read(from: snapshotCacheURL)) ?? []
        self.providerSnapshots = cachedSnapshots.filter { $0.providerId != antigravityConfig?.id }
        self.snapshots = providerSnapshots.map(\.legacySnapshot)
    }

    /// 金额显示币种（设置页写入，Swift 只读）。默认人民币。
    var displayCurrency: DisplayCurrency {
        settingsSnapshot?.displayCurrency ?? .cny
    }

    /// 缓存过期才联网；失败退回缓存/兜底，绝不阻塞额度显示。
    func refreshExchangeRate() async {
        exchangeRate = await ExchangeRateProvider.refreshIfNeeded()
    }

    func reloadPricingMetadata() {
        tieredPricingEntries = ProviderStore.loadTieredPricingEntries()
    }

    private static func loadTieredPricingEntries() -> [TieredPricingEntry] {
        guard let snapshot = try? PricingSnapshot.loadEffective() else { return [] }
        let entries = tieredModelBrands.compactMap { modelName, brandName -> TieredPricingEntry? in
            snapshot.models[modelName]?.tiered.map {
                TieredPricingEntry(
                    brandName: brandName,
                    modelName: modelName,
                    tier: $0
                )
            }
        }
        return entries.sorted { $0.id < $1.id }
    }

    /// 弹窗「峰谷时段」区块的展示行：按定价品牌归并模型，不依赖任何供应商
    /// 额度接口是否启用或是否有额度快照。
    var peakPricingRows: [PeakPricingRow] {
        var grouped: [String: (models: [String], tier: PeakOffPeakPricing)] = [:]
        for entry in tieredPricingEntries {
            if var existing = grouped[entry.brandName] {
                existing.models.append(entry.modelName)
            } else {
                grouped[entry.brandName] = ([entry.modelName], entry.tier)
            }
        }
        return grouped.map { brandName, value in
            PeakPricingRow(
                brandName: brandName,
                modelNames: value.models.sorted(),
                tier: value.tier
            )
        }
        .sorted { $0.brandName < $1.brandName }
    }

    /// 设置页的供应商启停（provider_config_overrides.enabled）。没写过 override 的默认启用。
    func isProviderEnabled(_ providerId: String) -> Bool {
        guard let enabled = settingsSnapshot?.providerOverrides
            .first(where: { $0.providerId == providerId })?.enabled else {
            if let source = antigravityConfig, source.id == providerId { return source.enabled }
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
                names[override.providerId] = override.providerId == antigravityConfig?.id
                    ? AntigravityUsageProvider.menuName(name) : name
            }
        }
        guard !names.isEmpty else { return visible }
        return visible.map { snapshot in
            names[snapshot.providerId].map(snapshot.renamed(to:)) ?? snapshot
        }
    }

    func refresh() async {
        refreshAntigravityIfNeeded()
        // 启动时重置卡检查可能先取得账户查询权。等它结束后仍要完成本轮额度刷新。
        while let resetTask = codexResetTask {
            await resetTask.value
        }
        guard !Task.isCancelled, !isScanPaused, !isRefreshing else {
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
        providerSnapshots = mergedProviderSnapshots + providerSnapshots.filter { $0.providerId == antigravityConfig?.id }
        snapshots = providerSnapshots.map(\.legacySnapshot)
        try? ProviderSnapshotDiskCache.write(mergedProviderSnapshots, to: snapshotCacheURL)
        notificationCenter?.deliver(notificationEvents)
        isRefreshing = false
    }

    func reloadAntigravityQuota() async {
        guard let provider = antigravityProvider else { return }
        antigravityGeneration += 1
        let generation = antigravityGeneration
        var next: ProviderUsageSnapshot?
        if isProviderEnabled(provider.id), !isScanPaused {
            next = await provider.cachedSnapshot(failure: antigravityConnectionError ?? antigravityQueryError?.errorDescription)
        } else if isProviderEnabled(provider.id) { return }
        guard generation == antigravityGeneration else { return }
        let snapshotsWithoutGoogle = providerSnapshots.filter { $0.providerId != provider.id }
        let updated = snapshotsWithoutGoogle + (next.map { [$0] } ?? [])
        guard updated != providerSnapshots else { return }
        providerSnapshots = updated
        snapshots = updated.map(\.legacySnapshot)
    }

    func antigravityDidReceiveQuota() async {
        antigravityQueryError = nil
        await reloadAntigravityQuota()
    }

    func stopAntigravityRefresh() {
        antigravityRefreshTask?.cancel()
        antigravityLastAttempt = nil
        antigravityQueryError = nil
    }

    @discardableResult
    func refreshAntigravityIfNeeded(force: Bool = false) -> Task<Void, Never>? {
        guard let provider = antigravityProvider, isProviderEnabled(provider.id), !isScanPaused else { return nil }
        if force { antigravityForceRequested = true }
        if let antigravityRefreshTask { return antigravityRefreshTask }
        let task = Task {
            defer {
                antigravityRefreshTask = nil
                antigravityForceRequested = false
                if isRefreshingAntigravity { isRefreshingAntigravity = false }
            }
            await reloadAntigravityQuota()
            guard !Task.isCancelled, antigravityConnectionError == nil else { return }
            let current = providerSnapshots.first { $0.providerId == provider.id }
            let started = Date()
            if !antigravityForceRequested {
                if antigravityQueryError == .signIn { return }
                if let last = antigravityLastAttempt, started.timeIntervalSince(last) < 300 { return }
                if let current, current.status == .ok, !current.groups.isEmpty,
                   started.timeIntervalSince(current.fetchedAt) < 300 { return }
            }
            antigravityLastAttempt = started
            isRefreshingAntigravity = true
            do {
                try await queryAntigravity(provider)
                antigravityQueryError = nil
            } catch is CancellationError {
                antigravityLastAttempt = nil
                return
            } catch {
                guard !Task.isCancelled else { return }
                if let fresh = providerSnapshots.first(where: { $0.providerId == provider.id && !$0.groups.isEmpty }),
                   fresh.fetchedAt != current?.fetchedAt,
                   fresh.fetchedAt.timeIntervalSince1970 >= floor(started.timeIntervalSince1970) { return }
                antigravityQueryError = (error as? AntigravityQueryError) ?? .unavailable
            }
            guard !Task.isCancelled else { return }
            await reloadAntigravityQuota()
        }
        antigravityRefreshTask = task
        return task
    }

    func retryQuota(for providerID: String) async {
        if providerID == antigravityConfig?.id {
            await refreshAntigravityIfNeeded(force: true)?.value
        } else {
            await refresh()
        }
    }

    /// 绕过节流立即刷新一次：设置页完成 OpenCode Go 登录后调用，登录态
    /// 写盘即可见，不用等 5 分钟轮询窗口。
    func refreshNow() async {
        refreshGate = RefreshGate(minimumInterval: refreshGate.minimumInterval)
        refreshAntigravityIfNeeded(force: true)
        await refresh()
        await antigravityRefreshTask?.value
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

    func setPinnedBalanceProvider(_ providerId: String?) throws {
        guard let settingsStore else { throw ProviderStoreError.settingsUnavailable }
        try settingsStore.setPinnedBalanceProvider(providerId)
        settingsSnapshot = try settingsStore.snapshot()
    }

    func reloadSettings(expectedVersion: Int? = nil) throws {
        guard let settingsStore else { throw ProviderStoreError.settingsUnavailable }
        let snapshot = try settingsStore.snapshot()
        if let expectedVersion, snapshot.version < expectedVersion {
            throw ProviderStoreError.settingsVersionBehind(expected: expectedVersion, actual: snapshot.version)
        }
        settingsSnapshot = snapshot
        if let source = antigravityConfig, !isProviderEnabled(source.id) { stopAntigravityRefresh() }
        if !shouldAutomaticallyRedeemCodexCredits { stopCodexResetAutomation() }
        refreshGate = RefreshGate(minimumInterval: max(300, TimeInterval(snapshot.autoRefreshSeconds)))
    }

    var shouldAutomaticallyRedeemCodexCredits: Bool {
        settingsSnapshot?.codexResetAutoRedeemEnabled == true
            && isProviderEnabled("codex") && !isScanPaused
            && providers.contains { $0.id == "codex" }
    }

    var codexResetAutomationMessage: String {
        guard settingsSnapshot?.codexResetAutoRedeemEnabled == true else { return "自动使用已关闭" }
        guard isProviderEnabled("codex"), !isScanPaused else { return "已暂停自动使用" }
        return codexResetAutomation?.status.message ?? "自动使用暂不可用"
    }

    func stopCodexResetAutomation() { codexResetTask?.cancel() }

    func checkCodexResetAutomation() {
        guard shouldAutomaticallyRedeemCodexCredits else { stopCodexResetAutomation(); return }
        guard codexResetTask == nil, !isRefreshing, let codexResetAutomation else { return }
        codexResetTask = Task { [weak self] in
            guard let self else { return }
            defer { self.codexResetTask = nil }
            let consumed = await codexResetAutomation.check { self.shouldAutomaticallyRedeemCodexCredits }
            guard consumed else { return }
            // 成功已持久化。显示刷新失败只保留旧显示，绝不再次消费。
            guard let account = try? await self.codexAccountClient.read(),
                  let snapshot = try? account.snapshot(
                    providerId: "codex", displayName: self.config.providers.first { $0.id == "codex" }?.displayName ?? "Codex"
                  ) else { return }
            let refreshed = ProviderSnapshotCache.merge(previous: self.providerSnapshots, refreshed: [snapshot]).first ?? snapshot
            if let index = self.providerSnapshots.firstIndex(where: { $0.providerId == "codex" }) {
                self.providerSnapshots[index] = refreshed
            } else {
                self.providerSnapshots.append(refreshed)
            }
            self.snapshots = self.providerSnapshots.map(\.legacySnapshot)
            try? ProviderSnapshotDiskCache.write(self.providerSnapshots, to: self.snapshotCacheURL)
        }
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

    func reloadTodaySummary() async {
        guard let databaseURL else { return }
        summaryGeneration += 1
        let generation = summaryGeneration
        let snapshot = await Task.detached(priority: .utility) { () -> (MenuBarTodaySummary, [DayActivity], OverviewStats)? in
            guard let reader = try? SQLiteDatabase(path: databaseURL.path, readOnly: true) else { return nil }
            guard (try? reader.execute("BEGIN")) != nil else { return nil }
            defer { try? reader.execute("ROLLBACK") }
            let now = Date()
            return (MenuBarTodaySummaryRepository.load(from: reader, now: now), MonthActivityRepository.load(from: reader, now: now),
                    OverviewStatsRepository.load(from: reader, now: now))
        }.value
        guard generation == summaryGeneration, let (today, month, overview) = snapshot else { return }
        if todaySummary != today { todaySummary = today }
        if monthActivity != month { monthActivity = month }
        if overviewStats != overview { overviewStats = overview }
    }

    /// 热力图悬浮详情的当天模型明细（同步查库，行数 ≤6，悬浮时调用一次）。
    func modelBreakdown(for date: String) -> [DayModelUsage] {
        guard let database else { return [] }
        return DayModelBreakdownRepository.load(from: database, date: date)
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
                "SELECT id, kind, display_name FROM scan_roots WHERE enabled = 1 AND scan_mode != 'disabled' ORDER BY display_name ASC"
            )
        } catch {
            localIndexStatusText = "本地会话索引不可用"
            return LocalIndexRefreshResult(scanned: 0, failures: 0, status: .unavailable, message: localIndexStatusText)
        }

        let enabledKinds = enabledSourceKinds()
        let enabledRoots = roots.filter { row in
            row.string("kind").flatMap(SourceKind.init(rawValue:)).map(enabledKinds.contains) == true
        }
        let ids = enabledRoots.compactMap { $0.int("id") }
        let failedIDs: Set<Int64>
        do {
            failedIDs = Set(try await scanner.scanRoots(ids: ids).keys)
        } catch {
            failedIDs = Set(ids)
        }
        let failures = failedIDs.count
        let scanned = ids.count - failures
        let failedNames = enabledRoots.compactMap { row -> String? in
            guard let id = row.int("id"), failedIDs.contains(id) else { return nil }
            return row.string("display_name")
        }.joined(separator: "、")

        let status: LocalIndexRefreshStatus
        if failures > 0, scanned > 0 {
            localIndexStatusText = "\(failedNames) 索引失败"
            status = .partial
        } else if failures > 0 {
            localIndexStatusText = "\(failedNames) 索引失败"
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
        await reloadTodaySummary()

        return LocalIndexRefreshResult(scanned: scanned, failures: failures, status: status, message: localIndexStatusText)
    }

    private func enabledSourceKinds() -> Set<SourceKind> {
        guard let settingsSnapshot else {
            return Set(SourceKind.allCases)
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
        case .reasonix:
            .reasonixStats
        case .dsh:
            .dshJSONL
        case .grok:
            .grokJSONL
        case .qwenCode:
            .qwenJSONL
        case .qoder:
            .qoderJSONL
        case .workbuddy:
            .workbuddyJSONL
        case .antigravityCLI:
            .antigravitySQLite
        case .geminiCLI:
            .geminiChat
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
