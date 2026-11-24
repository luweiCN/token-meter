import Darwin
import Foundation

/// The status-line payload also contains conversation and account details. Decode only quota fields.
package struct AntigravityQuota: Codable, Equatable {
    package static let providerID = "antigravity"
    package static let shortName = "AGY"
    package static let changed = Notification.Name("com.luwei.tokenmeter.antigravity-quota-changed")
    package static let captureArgument = "--capture-antigravity-quota"

    struct Bucket: Codable, Equatable {
        let fraction: Double?
        let amount: Double?
        let resetAt: Date?
    }
    let observedAt: Date
    let buckets: [String: Bucket]

    package static func cacheURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        TokenMeterPaths.baseDirectory(homeDirectory: home).appendingPathComponent("cache/antigravity-quota.json")
    }

    private struct Entry: Decodable {
        let bucket: RawBucket?
        init(from decoder: Decoder) { bucket = try? RawBucket(from: decoder) }
    }

    private struct RawBucket: Decodable {
        let remaining_fraction: Double?
        let remaining_amount: Double?
        let reset_time: String?
        let reset_in_seconds: Double?
        let disabled: Bool?
    }

    static func parse(_ data: Data, now: Date) throws -> Self? {
        struct Payload: Decodable {
            let quota: [String: Entry]?
            let agent_state: String?
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        if payload.agent_state == "authenticating" { return Self(observedAt: now, buckets: [:]) }
        guard let raw = payload.quota else { return nil }
        if raw.isEmpty && payload.agent_state == "initializing" { return nil }
        return fromStatusBuckets(raw, now: now)
    }

    static func parseStatusBuckets(_ data: Data, now: Date) throws -> Self {
        fromStatusBuckets(try JSONDecoder().decode([String: Entry].self, from: data), now: now)
    }

    private static func fromStatusBuckets(_ raw: [String: Entry], now: Date) -> Self {
        normalized(raw.compactMap { key, entry in entry.bucket.map { (key, $0) } }, at: now)
    }

    private static func normalized(_ raw: [(String, RawBucket)], at now: Date) -> Self {
        let iso = ISO8601DateFormatter()
        let preciseISO = ISO8601DateFormatter()
        preciseISO.formatOptions.insert(.withFractionalSeconds)
        var buckets: [String: Bucket] = [:]
        for (key, entry) in raw {
            guard entry.disabled != true, !key.isEmpty, key.utf8.count <= 128 else { continue }
            let fraction = entry.remaining_fraction.flatMap { (0...1).contains($0) ? $0 : nil }
            let amount = entry.remaining_amount.flatMap { $0 >= 0 ? $0 : nil }
            guard fraction != nil || amount != nil else { continue }
            let absoluteReset = entry.reset_time.flatMap { iso.date(from: $0) ?? preciseISO.date(from: $0) }
            let reset = absoluteReset.flatMap(Bucket.knownResetDate) ?? entry.reset_in_seconds.flatMap { seconds in
                guard seconds > 0, seconds <= Date.distantFuture.timeIntervalSince(now) else { return nil }
                return now.addingTimeInterval(seconds)
            }
            // The cache encodes whole ISO-8601 seconds. Compare live and stored resets at that same precision.
            let resetSecond = reset.map { Date(timeIntervalSince1970: floor($0.timeIntervalSince1970)) }
            buckets[key] = Bucket(fraction: fraction, amount: amount, resetAt: resetSecond)
        }
        return Self(observedAt: now, buckets: buckets)
    }

    /// A directory lock serializes simultaneous sessions and the opt-out operation.
    package static func withCacheLock<T>(at url: URL, _ action: () throws -> T) throws -> T {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(fd, LOCK_UN) }
        return try action()
    }

    package static func connectionURL(for cache: URL) -> URL {
        cache.deletingLastPathComponent().appendingPathComponent("antigravity-statusline.json")
    }

    package static func writePrivate(_ data: Data, to destination: URL) throws {
        var template = Array((destination.deletingLastPathComponent().path + "/.tokenmeter-XXXXXX").utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        let temporary = String(cString: template)
        defer { unlink(temporary) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
        guard rename(temporary, destination.path) == 0 else { throw POSIXError(.EIO) }
    }

    @discardableResult
    package static func capture(_ data: Data, at url: URL, now: Date = Date()) throws -> Bool {
        guard data.count <= 512 * 1024, let next = try parse(data, now: now) else { return false }
        return try next.save(at: url, supersededAfter: now, coalesce: true)
    }

    @discardableResult
    func save(at url: URL, supersededAfter start: Date, coalesce: Bool) throws -> Bool {
        return try Self.withCacheLock(at: url) {
            guard FileManager.default.fileExists(atPath: Self.connectionURL(for: url).path) else { return false }
            if let previous = try? Self.read(url), previous.observedAt > start ||
                (coalesce && previous.buckets == buckets && observedAt.timeIntervalSince(previous.observedAt) < 300) {
                return false
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try Self.writePrivate(encoder.encode(self), to: url)
            return true
        }
    }

    static func read(_ url: URL) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Self.self, from: Data(contentsOf: url))
    }
}

extension AntigravityQuota.Bucket {
    // AGY can pair a real remaining fraction with the Unix epoch and a zero countdown.
    fileprivate static func knownResetDate(_ date: Date) -> Date? {
        date.timeIntervalSince1970 > 0 ? date : nil
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(fraction: values.decodeIfPresent(Double.self, forKey: .fraction),
                      amount: values.decodeIfPresent(Double.self, forKey: .amount),
                      resetAt: values.decodeIfPresent(Date.self, forKey: .resetAt).flatMap(Self.knownResetDate))
    }
}

package struct AntigravityUsageProvider: UsageProvider {
    package let id: String
    package let displayName: String
    let cache: URL

    package init(config: ProviderConfig, cache: URL = AntigravityQuota.cacheURL()) {
        self.id = config.id
        self.displayName = Self.menuName(config.displayName)
        self.cache = cache
    }

    package static func menuName(_ name: String) -> String {
        name == "Antigravity" ? AntigravityQuota.shortName : name
    }

    package func fetchUsage() async -> UsageSnapshot { await fetchProviderUsage().legacySnapshot }

    package func fetchProviderUsage() async -> ProviderUsageSnapshot {
        snapshot(at: Date())
    }

    package func cachedSnapshot(failure: String?) async -> ProviderUsageSnapshot {
        snapshot(at: Date(), failure: failure)
    }

    func snapshot(at now: Date, failure: String? = nil) -> ProviderUsageSnapshot {
        let report = try? AntigravityQuota.read(cache)
        var items: [String: [UsageMetric]] = [:]
        for (key, value) in report?.buckets ?? [:] {
            guard value.resetAt.map({ $0 > now }) ?? true else { continue }
            let parts = key.split(separator: "-")
            let duration: Int? = parts.last == "5h" ? 300 : (parts.last == "weekly" ? 10_080 : nil)
            let group = duration == nil ? key : parts.dropLast().joined(separator: "-")
            let label = duration == 300 ? "5 小时" : (duration == 10_080 ? "每周" : key)
            let percent = value.fraction.map { $0 * 100 }
            let detail = percent == nil ? value.amount.map { "剩余 " + $0.formatted(.number) } : nil
            items[group, default: []].append(UsageMetric(
                id: key, label: label, kind: .quota, usedPercent: percent.map { 100 - $0 },
                remainingPercent: percent, resetText: value.resetAt.map { countdownText(until: $0, now: now) },
                status: percent == 0 ? .warning : .ok, detail: detail,
                resetAt: value.resetAt, windowDurationMinutes: duration
            ))
        }
        let titles = ["gemini": "Gemini", "3p": "Claude/GPT", "gemini-argon-wtu": "Gemini Argon WTU"]
        let priority = ["gemini": 0, "3p": 1]
        let groups = items.keys.sorted { (priority[$0] ?? 2, $0) < (priority[$1] ?? 2, $1) }.map { key in
            UsageGroup(id: key, title: titles[key] ?? key, subtitle: nil, items: items[key, default: []].sorted {
                ($0.windowDurationMinutes ?? .max, $0.id) < ($1.windowDurationMinutes ?? .max, $1.id)
            })
        }
        let status: UsageStatus
        if failure != nil {
            status = groups.isEmpty ? .error : .warning
        } else {
            status = groups.isEmpty ? .warning : .ok
        }
        return ProviderUsageSnapshot(providerId: id, displayName: displayName,
            status: status, fetchedAt: report?.observedAt ?? now,
            summary: nil, message: failure ?? (groups.isEmpty ? "等待 AGY 提供账户额度。" : nil), groups: groups)
    }
}
