import XCTest
@testable import TokenMeterCore

final class ExchangeRateProviderTests: XCTestCase {
    private func tempHome() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testCachedOrFallbackUsesBundledConstantWhenNoCache() {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let rate = ExchangeRateProvider.cachedOrFallback(homeDirectory: home)
        XCTAssertEqual(rate.usdToCny, ExchangeRateProvider.fallbackRate, accuracy: 1e-9)
    }

    func testCacheRoundTrip() throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let fresh = ExchangeRate(usdToCny: 6.75, fetchedAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(fresh)
        try FileManager.default.createDirectory(
            at: ExchangeRateProvider.cacheURL(homeDirectory: home).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: ExchangeRateProvider.cacheURL(homeDirectory: home))

        let loaded = try XCTUnwrap(ExchangeRateProvider.loadCache(homeDirectory: home))
        XCTAssertEqual(loaded.usdToCny, 6.75, accuracy: 1e-9)
    }

    func testRefreshReturnsFreshCacheWithoutNetwork() async throws {
        let home = tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let fresh = ExchangeRate(usdToCny: 6.8, fetchedAt: Date().addingTimeInterval(-3600))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(fresh)
        try FileManager.default.createDirectory(
            at: ExchangeRateProvider.cacheURL(homeDirectory: home).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: ExchangeRateProvider.cacheURL(homeDirectory: home))

        // 24h 内算新鲜：直接回缓存，不发生网络请求。
        let rate = await ExchangeRateProvider.refreshIfNeeded(homeDirectory: home)
        XCTAssertEqual(rate.usdToCny, 6.8, accuracy: 1e-9)
    }
}
