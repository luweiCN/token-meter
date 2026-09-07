import CryptoKit
import Foundation

public enum PricingSnapshotUpdateOutcome: Equatable {
    case notDue
    case unchanged
    case updated
    case failed
}

/// 定期下载由 TokenMeter CI 转换、测试并发布的完整价格快照。
/// 客户端不直接解析 LiteLLM 原始 schema，避免上游改字段时把错价扩散到每台机器。
public enum PricingSnapshotUpdater {
    static let snapshotURL = URL(
        string: "https://github.com/luweiCN/token-meter/releases/download/pricing-data/litellm-pricing.json"
    )!
    static let checksumURL = URL(
        string: "https://github.com/luweiCN/token-meter/releases/download/pricing-data/litellm-pricing.json.sha256"
    )!
    static let lastSuccessfulCheckKey = "pricingSnapshotLastSuccessfulCheckAt"
    static let checkInterval: TimeInterval = 24 * 60 * 60
    static let maximumSnapshotBytes = 10 * 1_024 * 1_024
    public static let minimumRemoteModelCount = 300

    public static func shouldCheck(lastSuccessfulAt: Date?, now: Date = Date()) -> Bool {
        guard let lastSuccessfulAt else { return true }
        let elapsed = now.timeIntervalSince(lastSuccessfulAt)
        return elapsed < 0 || elapsed >= checkInterval
    }

    public static func timeUntilNextCheck(
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) -> TimeInterval {
        guard let lastSuccessfulAt = defaults.object(forKey: lastSuccessfulCheckKey) as? Date else {
            return 0
        }
        let elapsed = now.timeIntervalSince(lastSuccessfulAt)
        guard elapsed >= 0 else { return 0 }
        return max(0, checkInterval - elapsed)
    }

    /// 失败不更新节流时间：应用后续的 6h 定时器会再试，但现有缓存/随包快照始终可用。
    public static func refreshIfDue(
        defaults: UserDefaults = .standard,
        session: URLSession = .shared,
        cacheURL: URL = TokenMeterPaths.pricingSnapshotURL(),
        now: Date = Date(),
        minimumModelCount: Int = minimumRemoteModelCount
    ) async -> PricingSnapshotUpdateOutcome {
        let lastCheck = defaults.object(forKey: lastSuccessfulCheckKey) as? Date
        guard shouldCheck(lastSuccessfulAt: lastCheck, now: now) else { return .notDue }

        guard let checksumData = await download(checksumURL, session: session, maximumBytes: 4_096),
              let snapshotData = await download(snapshotURL, session: session, maximumBytes: maximumSnapshotBytes) else {
            return .failed
        }

        do {
            let changed = try validateAndStore(
                snapshotData: snapshotData,
                checksumData: checksumData,
                cacheURL: cacheURL,
                minimumModelCount: minimumModelCount
            )
            defaults.set(now, forKey: lastSuccessfulCheckKey)
            return changed ? .updated : .unchanged
        } catch {
            return .failed
        }
    }

    /// 先验校验和与完整 schema，再原子替换缓存；任一校验失败都不碰旧文件。
    @discardableResult
    static func validateAndStore(
        snapshotData: Data,
        checksumData: Data,
        cacheURL: URL,
        minimumModelCount: Int = minimumRemoteModelCount
    ) throws -> Bool {
        guard snapshotData.count <= maximumSnapshotBytes,
              let expected = parseChecksum(checksumData),
              expected == sha256Hex(snapshotData) else {
            throw PricingSnapshotUpdateError.checksumMismatch
        }

        let snapshot = try PricingSnapshot.decode(snapshotData)
        try snapshot.validate(minimumModelCount: minimumModelCount)
        guard snapshot.source == "litellm" else {
            throw PricingSnapshotUpdateError.unexpectedSource
        }

        if (try? Data(contentsOf: cacheURL)) == snapshotData {
            return false
        }
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try snapshotData.write(to: cacheURL, options: .atomic)
        return true
    }

    static func parseChecksum(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8),
              let first = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).first else {
            return nil
        }
        let value = first.lowercased()
        guard value.count == 64, value.allSatisfy(\.isHexDigit) else { return nil }
        return value
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func download(
        _ url: URL,
        session: URLSession,
        maximumBytes: Int
    ) async -> Data? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              data.count <= maximumBytes else {
            return nil
        }
        return data
    }
}

private enum PricingSnapshotUpdateError: Error {
    case checksumMismatch
    case unexpectedSource
}
