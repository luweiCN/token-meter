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
    @Published private(set) var providerSnapshots: [ProviderUsageSnapshot] = []
    @Published private(set) var notificationAuthorizationState: UsageNotificationAuthorizationState = .unknown
    @Published private(set) var settingsSnapshot: SettingsSnapshot?
    @Published private(set) var localIndexStatusText: String = "本地会话索引未启动"
    @Published private(set) var dailyNodeSummary: NodeDailySummary?
    @Published private(set) var dailyAgents: [DailyAgentRow] = []
    @Published private(set) var dailyModels: DailyModelSummary?
    private let nodeDirectory: URL?
    private var nodeSummaryGeneration = 0
    private struct LocalUsageSummary {
        let date: Date
        let today: MenuBarTodaySummary
        let month: [DayActivity]
        let overview: OverviewStats
    }
    private var localUsage: LocalUsageSummary?
    /// 菜单栏数字和弹窗头部共用同一份今日汇总。
    @Published private(set) var todaySummary: MenuTodayUsage = .empty
    /// 当月每日用量（弹窗头部热力图）；与 todaySummary 同步刷新。
    @Published private(set) var monthActivity: [DayActivity] = []
    /// 较早的设备快照只包含当日汇总。
    @Published private(set) var overviewStats: MenuUsagePeriods? = .local(.empty)
    @Published private(set) var localIndexUpdatedAt: Date?
    /// 当前显示汇率（USD→CNY）。启动先读缓存/兜底，随后按需刷新。
    @Published private(set) var exchangeRate: ExchangeRate
    /// 与后台共用暂停标记，暂停时也取消本次从菜单发起的刷新。
    @Published var isScanPaused = false {
        didSet {
            if isScanPaused { pendingRefresh?.task.cancel() }
            if databaseURL == TokenMeterPaths.databaseURL() { DesktopNode.setPaused(isScanPaused) }
        }
    }
    /// refreshLocalAgentIndex 的 in-flight 互斥（MainActor 串行，但 await 让出时可重入）。
    private var isRefreshingLocalIndex = false

    private let config: TokenMeterConfig
    let accountFeed: DesktopAccountFeed
    private var readGeneration = 0
    private struct PendingRefresh {
        let providerID: String?
        let task: Task<Void, Error>
    }
    @Published private var pendingRefresh: PendingRefresh?
    @Published private var refreshErrors: [String: String] = [:]

    var isRefreshing: Bool { pendingRefresh != nil }

    func isRefreshingQuota(for providerID: String) -> Bool {
        guard let pendingRefresh else { return false }
        return pendingRefresh.providerID == nil || pendingRefresh.providerID == providerID
    }

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
        self.init(config: ProviderConfigLoader.current())
    }

    convenience init(notificationCenter: UsageNotificationDelivering?) {
        self.init(
            config: ProviderConfigLoader.current(),
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
         accountFeed: DesktopAccountFeed? = nil) {
        self.config = config
        self.nodeDirectory = databaseURL?.deletingLastPathComponent().appendingPathComponent("node", isDirectory: true)
        let directory = databaseURL?.deletingLastPathComponent() ?? TokenMeterPaths.baseDirectory()
        self.accountFeed = accountFeed ?? DesktopAccountFeed(home: directory.lastPathComponent == ".token-meter"
            ? directory.deletingLastPathComponent() : directory)
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
        if databaseURL == TokenMeterPaths.databaseURL() { isScanPaused = FileManager.default.fileExists(atPath: DesktopNode.directory.appendingPathComponent("index-paused").path) }
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

    /// 设置页的启停首选项优先于供应商定义的默认值。
    func isProviderEnabled(_ providerId: String) -> Bool {
        guard let enabled = settingsSnapshot?.providerOverrides
            .first(where: { $0.providerId == providerId })?.enabled else {
            return config.providers.first { $0.id == providerId }?.enabled ?? false
        }
        return enabled
    }

    /// 弹窗与状态栏消费的展示投影：过滤停用的供应商 + 应用别名（displayName override）。
    /// 后台快照保留供应商原名，用于通知对比。启停和别名只改变展示。
    var displayProviderSnapshots: [ProviderUsageSnapshot] {
        providerSnapshots.filter { isProviderEnabled($0.providerId) }.map { source in
            let snapshot: ProviderUsageSnapshot
            if let error = refreshErrors[source.providerId] {
                snapshot = ProviderUsageSnapshot(providerId: source.providerId, displayName: source.displayName,
                    status: source.groups.isEmpty ? .error : .warning, fetchedAt: source.fetchedAt,
                    summary: source.summary, message: error, groups: source.groups,
                    resetCredits: source.resetCredits, accountCredits: source.accountCredits)
            } else {
                snapshot = source
            }
            guard let name = settingsSnapshot?.providerOverrides.first(where: { $0.providerId == source.providerId })?.displayName,
                  !name.isEmpty else { return snapshot }
            let isGoogle = config.providers.first { $0.id == source.providerId }?.type == .antigravity
            return snapshot.renamed(to: isGoogle ? AntigravityQuota.menuName(name) : name)
        }
    }

    func reloadAccountSnapshots() async {
        readGeneration += 1
        let generation = readGeneration
        let file = accountFeed.snapshotURL
        guard let current = await Task.detached(priority: .utility, operation: {
            try? ProviderSnapshotDiskCache.read(from: file)
        }).value, generation == readGeneration, current != providerSnapshots else { return }

        let events = UsageNotificationEventDetector.events(previous: providerSnapshots,
            current: current.filter { isProviderEnabled($0.providerId) },
            usedThresholdPercent: settingsSnapshot?.quotaUsedThresholdPercent ?? 0)
        for snapshot in current where !refreshErrors.isEmpty &&
            providerSnapshots.first(where: { $0.providerId == snapshot.providerId }) != snapshot {
            refreshErrors[snapshot.providerId] = nil
        }
        providerSnapshots = current
        if !events.isEmpty { notificationCenter?.deliver(events) }
    }

    func retryQuota(for providerID: String) async {
        do {
            try await refreshNow(providerID: providerID)
        } catch is CancellationError {
        } catch {
            refreshErrors[providerID] = error.localizedDescription
        }
    }

    func refreshNow(providerID: String? = nil) async throws {
        while let running = pendingRefresh {
            if running.providerID == nil || running.providerID == providerID {
                return try await running.task.value
            }
            _ = try? await running.task.value
        }
        guard !isScanPaused, providerID.map(isProviderEnabled) ?? true else { throw CancellationError() }

        let task = Task {
            defer { pendingRefresh = nil }
            try await accountFeed.refresh(providerID)
            if let providerID { refreshErrors[providerID] = nil } else { refreshErrors.removeAll() }
            await reloadAccountSnapshots()
        }
        pendingRefresh = PendingRefresh(providerID: providerID, task: task)
        try await task.value
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
        if let providerID = pendingRefresh?.providerID, !isProviderEnabled(providerID) {
            pendingRefresh?.task.cancel()
        }
    }

    func codexResetAutomationMessage() async -> String {
        guard settingsSnapshot?.codexResetAutoRedeemEnabled == true else { return "自动使用已关闭" }
        guard isProviderEnabled("codex"), !isScanPaused else { return "已暂停自动使用" }
        let feed = accountFeed
        return await Task.detached(priority: .utility) { feed.resetStatusMessage() }.value
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

    func refreshScheduledLocalIndex() async {
        guard !isScanPaused else { return }
        if let status = await Task.detached(priority: .utility, operation: { DesktopNode.indexStatus() }).value {
            localIndexUpdatedAt = Date(timeIntervalSince1970: Double(status.at))
            localIndexStatusText = status.failures == 0 ? "已更新 \(status.scanned) 个本地数据源" : "\(status.failures) 个来源索引失败"
            await reloadTodaySummary()
        } else {
            await refreshLocalAgentIndex()
        }
    }

    func reloadTodaySummary() async {
        summaryGeneration += 1
        let generation = summaryGeneration
        nodeSummaryGeneration += 1
        let nodeGeneration = nodeSummaryGeneration
        let now = Date()
        let databaseURL = self.databaseURL
        let nodeDirectory = self.nodeDirectory
        let (nodes, snapshot) = await Task.detached(priority: .utility) { () -> (NodeDailySummary?, LocalUsageSummary?) in
            let nodes = nodeDirectory.flatMap { DesktopNode.dailySummary(now: now, directory: $0) }
            guard let url = databaseURL, let reader = try? SQLiteDatabase(path: url.path, readOnly: true),
                  (try? reader.execute("BEGIN")) != nil else { return (nodes, nil) }
            defer { try? reader.execute("ROLLBACK") }
            return (nodes, LocalUsageSummary(
                date: now,
                today: MenuBarTodaySummaryRepository.load(from: reader, now: now),
                month: MonthActivityRepository.load(from: reader, now: now),
                overview: OverviewStatsRepository.load(from: reader, now: now)
            ))
        }.value
        guard generation == summaryGeneration else { return }
        if let snapshot { localUsage = snapshot }
        applyDailyNodeSummary(nodes, generation: nodeGeneration)
    }

    func reloadDailyNodeSummary() async {
        guard let nodeDirectory else { return }
        nodeSummaryGeneration += 1
        let generation = nodeSummaryGeneration
        let nodes = await Task.detached(priority: .utility) { DesktopNode.dailySummary(directory: nodeDirectory) }.value
        guard generation == nodeSummaryGeneration, dailyNodeSummary != nodes else { return }
        applyDailyNodeSummary(nodes, generation: generation)
    }

    private func applyDailyNodeSummary(_ nodes: NodeDailySummary?, generation: Int) {
        if generation == nodeSummaryGeneration, dailyNodeSummary != nodes { dailyNodeSummary = nodes }
        let node = dailyNodeSummary
        let local = localUsage.flatMap { Calendar.current.isDateInToday($0.date) ? $0 : nil }
        let localToday = local?.today ?? .empty
        let today = MenuTodayUsage.from(node: node, local: localToday)
        if todaySummary != today { todaySummary = today }

        let overview: MenuUsagePeriods?
        let month: [DayActivity]
        let localPeriods = MenuUsagePeriods.local(local?.overview ?? .empty)
        if let node, let history = node.history {
            overview = node.includesLocal ? history.periods : history.periods.adding(localPeriods)
            month = history.monthActivity(local: local?.month ?? [], includesLocal: node.includesLocal) ?? []
        } else if node?.includesRemote == true {
            overview = nil
            month = []
        } else {
            overview = localPeriods
            month = local?.month ?? []
        }
        if overviewStats != overview { overviewStats = overview }
        if monthActivity != month { monthActivity = month }

        let agents = DailyAgentRow.rows(node: node, local: localToday.perProvider)
        if dailyAgents != agents { dailyAgents = agents }
        let models = DailyModelSummary.from(node: node, local: localToday.perModel)
        if dailyModels != models { dailyModels = models }
    }

    func modelBreakdown(for date: String) -> [DailyModelSummary.Row] {
        let history = dailyNodeSummary?.history
        let cached = history?.days[date]?.models ?? []
        var rows = cached
        if let database, history == nil || dailyNodeSummary?.includesLocal != true {
            // Apply the six-row limit after merging and filtering.
            let local = DayModelBreakdownRepository.load(from: database, date: date, limit: -1)
            rows += local.map { DailyModelSummary.Row(id: $0.model, usage: DailyUsage(local: $0), hasCredits: $0.hasCredits) }
        }
        return Array((DailyModelSummary.merging(rows)?.rows ?? []).prefix(6))
    }

    func deviceBreakdown(for date: String) -> [DayDeviceUsage] {
        var rows: [DayDeviceUsage] = []
        let node = dailyNodeSummary
        if let node {
            let day = node.history?.days[date]
            if let usages = day?.devices {
                rows = node.devices.compactMap { device in
                    guard let amount = usages[device.id],
                          amount.usage.hasUsage(hasCredits: amount.hasCredits) || (date == node.day && device.active) else { return nil }
                    return DayDeviceUsage(id: device.id, name: device.name, usage: amount.usage)
                }
            } else if date == node.day {
                rows = node.devices.filter(\.active).map {
                    DayDeviceUsage(id: $0.id, name: $0.name, usage: $0.usage)
                }
            } else if day != nil {
                // Older snapshots have historical totals and no device split for those dates.
                return []
            }
        }

        if node?.includesLocal != true, let localUsage, Calendar.current.isDateInToday(localUsage.date),
           let day = localUsage.month.first(where: { $0.date == date }) {
            let usage = DailyUsage(activity: day)
            if usage.hasUsage(hasCredits: day.hasCredits) {
                rows.append(DayDeviceUsage(id: "local", name: "本机", usage: usage))
            }
        }
        return rows.sorted {
            if $0.usage.tokens != $1.usage.tokens { return $0.usage.tokens > $1.usage.tokens }
            if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.id < $1.id
        }
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

        let enabledRoots: [SQLiteRow]
        do {
            enabledRoots = try LocalAgentScanner.enabledRoots(in: database, settings: settingsSnapshot)
        } catch {
            localIndexStatusText = "本地会话索引不可用"
            return LocalIndexRefreshResult(scanned: 0, failures: 0, status: .unavailable, message: localIndexStatusText)
        }
        let ids = enabledRoots.compactMap { $0.int("id") }
        let failedIDs: Set<Int64>
        do {
            failedIDs = Set(try await scanner.scanRoots(ids: ids).keys)
        } catch LocalAgentScannerError.scanAlreadyInProgress {
            await reloadTodaySummary()
            return LocalIndexRefreshResult(scanned: 0, failures: 0, status: .ok, message: "扫描已在进行")
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
