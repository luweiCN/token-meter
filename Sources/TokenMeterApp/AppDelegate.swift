import AppKit
import Combine
import TokenMeterCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: ProviderStore?
    private var statusBarController: StatusBarController?
    private var refreshTimer: Timer?
    private var ipcServer: TokenMeterIPCServer?
    private let usageNotificationCenter = UsageNotificationCenter()
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = ProviderStore(notificationCenter: usageNotificationCenter)
        store.seedDefaultScanRoots()
        self.store = store
        self.statusBarController = StatusBarController(store: store)
        let ipcServer = TokenMeterIPCServer(store: store)
        try? ipcServer.start()
        self.ipcServer = ipcServer

        Task {
            await store.refreshNotificationAuthorizationState()
            await store.refresh()
            await store.refreshLocalAgentIndex()
            ipcServer.broadcastDataChanged()
        }

        scheduleRefreshTimer(interval: refreshInterval(for: store.settingsSnapshot))
        bindSettingsTimer(to: store)
        bindHooksInstaller(to: store)
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
        ipcServer?.stop()
        refreshTimer?.invalidate()
        cancellables.removeAll()
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

    private func refreshInterval(for snapshot: SettingsSnapshot?) -> TimeInterval {
        TimeInterval(snapshot?.autoRefreshSeconds ?? 300)
    }
}
