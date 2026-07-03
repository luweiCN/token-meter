import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: ProviderStore?
    private var statusBarController: StatusBarController?
    private var refreshTimer: Timer?
    private let usageNotificationCenter = UsageNotificationCenter()

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

        let interval = TimeInterval(store.settingsSnapshot?.autoRefreshSeconds ?? 300)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.store?.refresh()
                await self?.store?.refreshLocalAgentIndex()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
    }
}
