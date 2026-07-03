import Combine
import Foundation
import TokenMeterCore

@MainActor
final class ProviderStore: ObservableObject {
    @Published private(set) var snapshots: [UsageSnapshot] = []
    @Published private(set) var providerSnapshots: [ProviderUsageSnapshot] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var notificationAuthorizationState: UsageNotificationAuthorizationState = .unknown

    let config: TokenMeterConfig
    private let providers: [UsageProvider]
    private var refreshGate = RefreshGate(minimumInterval: 300)
    private let snapshotCacheURL: URL
    private weak var notificationCenter: UsageNotificationDelivering?

    convenience init() {
        self.init(config: ProviderStore.loadConfig())
    }

    convenience init(notificationCenter: UsageNotificationDelivering?) {
        self.init(config: ProviderStore.loadConfig(), notificationCenter: notificationCenter)
    }

    init(config: TokenMeterConfig, notificationCenter: UsageNotificationDelivering? = nil) {
        self.config = config
        self.providers = ProviderRegistry.makeProviders(from: config)
        self.snapshotCacheURL = ProviderStore.snapshotCacheURL()
        self.notificationCenter = notificationCenter
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
