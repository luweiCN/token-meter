import Foundation

public enum ProviderSnapshotCache {
    public static func merge(
        previous: [ProviderUsageSnapshot],
        refreshed: [ProviderUsageSnapshot]
    ) -> [ProviderUsageSnapshot] {
        let previousByProvider = Dictionary(uniqueKeysWithValues: previous.map { ($0.providerId, $0) })

        return refreshed.map { snapshot in
            if snapshot.status == .ok,
               snapshot.resetCredits == nil,
               let cached = previousByProvider[snapshot.providerId],
               let resetCredits = cached.resetCredits {
                return ProviderUsageSnapshot(
                    providerId: snapshot.providerId,
                    displayName: snapshot.displayName,
                    status: snapshot.status,
                    fetchedAt: snapshot.fetchedAt,
                    summary: snapshot.summary,
                    message: snapshot.message,
                    groups: snapshot.groups,
                    resetCredits: resetCredits
                )
            }

            guard snapshot.status != .ok,
                  let cached = previousByProvider[snapshot.providerId],
                  !cached.groups.isEmpty else {
                return snapshot
            }

            return ProviderUsageSnapshot(
                providerId: cached.providerId,
                displayName: cached.displayName,
                status: .warning,
                fetchedAt: cached.fetchedAt,
                summary: cached.summary,
                message: snapshot.message,
                groups: cached.groups,
                resetCredits: cached.resetCredits
            )
        }
    }
}

public enum ProviderSnapshotDiskCache {
    public static func read(from url: URL) throws -> [ProviderUsageSnapshot] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([ProviderUsageSnapshot].self, from: Data(contentsOf: url))
    }

    public static func write(_ snapshots: [ProviderUsageSnapshot], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshots.filter { !$0.groups.isEmpty })
        try data.write(to: url, options: .atomic)
    }
}
