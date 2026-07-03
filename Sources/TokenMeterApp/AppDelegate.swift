import AppKit
import Combine
import TokenMeterCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: ProviderStore?
    private var statusBarController: StatusBarController?
    private var refreshTimer: Timer?
    private let usageNotificationCenter = UsageNotificationCenter()
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = ProviderStore(notificationCenter: usageNotificationCenter)
        store.seedDefaultScanRoots()
        self.store = store
        self.statusBarController = StatusBarController(store: store)

        Task {
            await store.refreshNotificationAuthorizationState()
            await store.refresh()
            await store.refreshLocalAgentIndex()
        }

        scheduleRefreshTimer(interval: refreshInterval(for: store.settingsSnapshot))
        bindSettingsTimer(to: store)
    }

    func applicationWillTerminate(_ notification: Notification) {
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
            }
        }
    }

    private func refreshInterval(for snapshot: SettingsSnapshot?) -> TimeInterval {
        TimeInterval(snapshot?.autoRefreshSeconds ?? 300)
    }
}
