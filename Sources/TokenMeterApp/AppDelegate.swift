import AppKit
import Combine
import TokenMeterCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: ProviderStore?
    private var statusBarController: StatusBarController?
    private var refreshTimer: Timer?
    private var codexResetTimer: Timer?
    private var exchangeRateTimer: Timer?
    private var pricingRefreshTimer: Timer?
    private var startupTask: Task<Void, Never>?
    private var ipcServer: TokenMeterIPCServer?
    private let usageNotificationCenter: UsageNotificationDelivering
    private var cancellables: Set<AnyCancellable> = []
    private var isTerminating = false
    /// 测试可替换，避免 AppDelegate 生命周期测试访问真实网络。
    var refreshPricingSnapshot: () async -> PricingSnapshotUpdateOutcome = {
        await PricingSnapshotUpdater.refreshIfDue()
    }

    override init() {
        usageNotificationCenter = UsageNotificationCenter()
        super.init()
    }

    init(usageNotificationCenter: UsageNotificationDelivering) {
        self.usageNotificationCenter = usageNotificationCenter
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        isTerminating = false
        let store = ProviderStore(notificationCenter: usageNotificationCenter)
        store.seedDefaultScanRoots()
        self.store = store
        self.statusBarController = StatusBarController(store: store)
        let ipcServer = TokenMeterIPCServer(store: store)
        try? ipcServer.start()
        self.ipcServer = ipcServer

        startupTask?.cancel()
        startupTask = Task { [weak self] in
            guard let self, !Task.isCancelled,
                  let store = self.store,
                  let ipcServer = self.ipcServer else { return }
            await store.refreshNotificationAuthorizationState()
            guard !Task.isCancelled else { return }
            await store.refresh()
            guard !Task.isCancelled else { return }
            let pricingOutcome = await self.refreshPricingSnapshot()
            guard !Task.isCancelled, !self.isTerminating else { return }
            if pricingOutcome == .updated {
                store.reloadPricingMetadata()
            }
            self.schedulePricingRefreshTimer(after: self.nextPricingRefreshDelay(for: pricingOutcome))
            guard !Task.isCancelled else { return }
            await store.refreshLocalAgentIndex()
            guard !Task.isCancelled else { return }
            await store.refreshExchangeRate()
            guard !Task.isCancelled else { return }
            ipcServer.broadcastDataChanged()
        }

        scheduleRefreshTimer(interval: refreshInterval(for: store.settingsSnapshot))
        scheduleExchangeRateTimer()
        bindSettingsTimer(to: store)
        bindCodexResetAutomation(to: store)
        bindHooksInstaller(to: store)
        // 静默更新检查（24h 节流）：有新版发系统通知；手动入口在右键菜单。
        UpdateChecker.autoCheckIfDue()
    }

    /// enabledAgentKinds 一变（含启动的首个快照）就对账 hooks 装卸：
    /// 开 = 注入上报条目，关 = 移除。sync 幂等，多跑无害。
    private func bindHooksInstaller(to store: ProviderStore) {
        let installer = AgentHooksInstaller.bundled()
        store.$settingsSnapshot
            .compactMap { $0?.enabledAgentKinds }
            .removeDuplicates()
            .sink { kinds in
                installer.sync(enabledKinds: Set(kinds))
            }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        startupTask?.cancel()
        startupTask = nil
        ipcServer?.stop()
        refreshTimer?.invalidate()
        codexResetTimer?.invalidate()
        store?.stopCodexResetAutomation()
        exchangeRateTimer?.invalidate()
        pricingRefreshTimer?.invalidate()
        cancellables.removeAll()
    }

    private func bindCodexResetAutomation(to store: ProviderStore) {
        store.$settingsSnapshot.combineLatest(store.$isScanPaused)
            .sink { [weak self, weak store] _, _ in
                // @Published 在赋值前发事件；下一次主线程调度读取最终设置。
                Task { @MainActor [weak self, weak store] in
                    guard let self, let store, !self.isTerminating else { return }
                    self.codexResetTimer?.invalidate()
                    self.codexResetTimer = nil
                    guard store.shouldAutomaticallyRedeemCodexCredits else {
                        store.stopCodexResetAutomation()
                        return
                    }
                    store.checkCodexResetAutomation()
                    let timer = Timer(timeInterval: 60, repeats: true) { [weak store] _ in
                        Task { @MainActor in store?.checkCodexResetAutomation() }
                    }
                    RunLoop.main.add(timer, forMode: .common)
                    self.codexResetTimer = timer
                }
            }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak store] _ in
                Task { @MainActor in store?.checkCodexResetAutomation() }
            }
            .store(in: &cancellables)
    }

    private func bindSettingsTimer(to store: ProviderStore) {
        store.$settingsSnapshot
            .dropFirst()
            .map { [weak self] snapshot in
                self?.refreshInterval(for: snapshot) ?? 300
            }
            .removeDuplicates()
            .sink { [weak self] interval in
                self?.scheduleRefreshTimer(interval: interval)
            }
            .store(in: &cancellables)
    }

    private func scheduleRefreshTimer(interval: TimeInterval) {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.store?.refresh()
                await self?.store?.refreshLocalAgentIndex()
                // 扫描是数据更新的唯一定时来源（hooks 事件不再触发扫描），
                // 扫完必须广播，Electron 页面才知道该重取了。
                self?.ipcServer?.broadcastDataChanged()
            }
        }
    }

    /// 汇率每 6 小时试一次（provider 内部有 24h 新鲜窗口，过期才真的联网），
    /// 失败静默退回缓存/兜底，不影响额度显示。
    private func scheduleExchangeRateTimer() {
        exchangeRateTimer?.invalidate()
        exchangeRateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.store?.refreshExchangeRate()
            }
        }
    }

    /// 成功后精确排到下一个 24h 检查点；失败则 6h 后重试。
    /// 新快照落盘后立即跑一轮本地索引，扫描器只重算变价模型。
    private func schedulePricingRefreshTimer(after delay: TimeInterval) {
        guard !isTerminating else { return }
        pricingRefreshTimer?.invalidate()
        pricingRefreshTimer = Timer.scheduledTimer(withTimeInterval: max(60, delay), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let outcome = await self.refreshPricingSnapshot()
                guard !Task.isCancelled, !self.isTerminating else { return }
                if outcome == .updated {
                    self.store?.reloadPricingMetadata()
                    await self.store?.refreshLocalAgentIndex()
                    self.ipcServer?.broadcastDataChanged()
                }
                self.schedulePricingRefreshTimer(after: self.nextPricingRefreshDelay(for: outcome))
            }
        }
    }

    private func nextPricingRefreshDelay(for outcome: PricingSnapshotUpdateOutcome) -> TimeInterval {
        outcome == .failed ? 6 * 3600 : PricingSnapshotUpdater.timeUntilNextCheck()
    }

    private func refreshInterval(for snapshot: SettingsSnapshot?) -> TimeInterval {
        TimeInterval(snapshot?.autoRefreshSeconds ?? 300)
    }
}
