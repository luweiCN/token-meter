import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: ProviderStore?
    private var statusBarController: StatusBarController?
    private var refreshTimer: Timer?
    private let usageNotificationCenter = UsageNotificationCenter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = ProviderStore(notificationCenter: usageNotificationCenter)
        self.store = store
        self.statusBarController = StatusBarController(store: store)

        Task {
            await store.refreshNotificationAuthorizationState()
            await store.refresh()
        }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.store?.refresh()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
    }
}
