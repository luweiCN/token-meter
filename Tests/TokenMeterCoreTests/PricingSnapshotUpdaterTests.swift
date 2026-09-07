import XCTest
@testable import TokenMeterCore

final class PricingSnapshotUpdaterTests: XCTestCase {
    override func tearDown() {
        PricingSnapshotMockURLProtocol.handler = nil
        super.tearDown()
    }

    func testChecksImmediatelyThenWaitsTwentyFourHours() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertTrue(PricingSnapshotUpdater.shouldCheck(lastSuccessfulAt: nil, now: now))
        XCTAssertTrue(PricingSnapshotUpdater.shouldCheck(
            lastSuccessfulAt: now.addingTimeInterval(-86_400),
            now: now
        ))
        XCTAssertTrue(PricingSnapshotUpdater.shouldCheck(
            lastSuccessfulAt: now.addingTimeInterval(-86_401),
            now: now
        ))
        XCTAssertTrue(PricingSnapshotUpdater.shouldCheck(
            lastSuccessfulAt: now.addingTimeInterval(1),
            now: now
        ), "系统时间回拨后应立即重试，不能等待未来时间追平")
    }

    func testComputesExactDelayToNextSuccessfulCheck() throws {
        let suiteName = "PricingSnapshotUpdaterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertEqual(PricingSnapshotUpdater.timeUntilNextCheck(defaults: defaults, now: now), 0)
        defaults.set(now.addingTimeInterval(-3_600), forKey: PricingSnapshotUpdater.lastSuccessfulCheckKey)
        XCTAssertEqual(PricingSnapshotUpdater.timeUntilNextCheck(defaults: defaults, now: now), 23 * 3_600)
        defaults.set(now.addingTimeInterval(-86_400), forKey: PricingSnapshotUpdater.lastSuccessfulCheckKey)
        XCTAssertEqual(PricingSnapshotUpdater.timeUntilNextCheck(defaults: defaults, now: now), 0)
    }

    func testValidatedSnapshotAtomicallyReplacesCacheAndLoadsAsEffective() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheURL = directory.appendingPathComponent("cache/litellm-pricing.json")
        let data = try snapshotData(inputPrice: 10)
        let checksum = Data("\(PricingSnapshotUpdater.sha256Hex(data))  litellm-pricing.json\n".utf8)

        XCTAssertTrue(try PricingSnapshotUpdater.validateAndStore(
            snapshotData: data,
            checksumData: checksum,
            cacheURL: cacheURL,
            minimumModelCount: 1
        ))
        XCTAssertFalse(try PricingSnapshotUpdater.validateAndStore(
            snapshotData: data,
            checksumData: checksum,
            cacheURL: cacheURL,
            minimumModelCount: 1
        ), "相同内容不应重写缓存")

        let effective = try PricingSnapshot.loadEffective(cachedURL: cacheURL)
        XCTAssertEqual(effective.snapshotVersion, "remote-test")
        XCTAssertEqual(effective.models["gpt-6-astra"]?.inputPerMTok, 10)
        XCTAssertEqual(effective.models["gpt-6-astra"]?.longContext?.thresholdTokens, 272_000)
    }

    func testBadChecksumLeavesExistingCacheUntouched() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheURL = directory.appendingPathComponent("litellm-pricing.json")
        let oldData = Data("old-cache".utf8)
        try oldData.write(to: cacheURL)

        XCTAssertThrowsError(try PricingSnapshotUpdater.validateAndStore(
            snapshotData: snapshotData(inputPrice: 10),
            checksumData: Data(String(repeating: "0", count: 64).utf8),
            cacheURL: cacheURL,
            minimumModelCount: 1
        ))
        XCTAssertEqual(try Data(contentsOf: cacheURL), oldData)
    }

    func testRejectsStructurallyValidSnapshotWithInvalidPrice() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheURL = directory.appendingPathComponent("litellm-pricing.json")
        let data = try snapshotData(inputPrice: -1)
        let checksum = Data(PricingSnapshotUpdater.sha256Hex(data).utf8)

        XCTAssertThrowsError(try PricingSnapshotUpdater.validateAndStore(
            snapshotData: data,
            checksumData: checksum,
            cacheURL: cacheURL,
            minimumModelCount: 1
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    func testRefreshDownloadsBothFilesStoresCacheAndThrottlesNextCheck() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheURL = directory.appendingPathComponent("litellm-pricing.json")
        let suiteName = "PricingSnapshotUpdaterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1_000_000)
        let snapshot = try snapshotData(inputPrice: 10)
        let checksum = Data(PricingSnapshotUpdater.sha256Hex(snapshot).utf8)
        var requestedURLs: [URL] = []

        PricingSnapshotMockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            requestedURLs.append(url)
            if url == PricingSnapshotUpdater.checksumURL {
                return (200, checksum)
            }
            if url == PricingSnapshotUpdater.snapshotURL {
                return (200, snapshot)
            }
            return (404, Data())
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PricingSnapshotMockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let first = await PricingSnapshotUpdater.refreshIfDue(
            defaults: defaults,
            session: session,
            cacheURL: cacheURL,
            now: now,
            minimumModelCount: 1
        )
        XCTAssertEqual(first, .updated)
        XCTAssertEqual(try Data(contentsOf: cacheURL), snapshot)
        XCTAssertEqual(defaults.object(forKey: PricingSnapshotUpdater.lastSuccessfulCheckKey) as? Date, now)
        XCTAssertEqual(Set(requestedURLs), [PricingSnapshotUpdater.checksumURL, PricingSnapshotUpdater.snapshotURL])

        requestedURLs.removeAll()
        let second = await PricingSnapshotUpdater.refreshIfDue(
            defaults: defaults,
            session: session,
            cacheURL: cacheURL,
            now: now.addingTimeInterval(60),
            minimumModelCount: 1
        )
        XCTAssertEqual(second, .notDue)
        XCTAssertTrue(requestedURLs.isEmpty)
    }

    func testRefreshFailureDoesNotStartTwentyFourHourThrottle() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "PricingSnapshotUpdaterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        PricingSnapshotMockURLProtocol.handler = { _ in (500, Data()) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PricingSnapshotMockURLProtocol.self]

        let outcome = await PricingSnapshotUpdater.refreshIfDue(
            defaults: defaults,
            session: URLSession(configuration: configuration),
            cacheURL: directory.appendingPathComponent("litellm-pricing.json"),
            minimumModelCount: 1
        )

        XCTAssertEqual(outcome, .failed)
        XCTAssertNil(defaults.object(forKey: PricingSnapshotUpdater.lastSuccessfulCheckKey))
    }

    private func snapshotData(inputPrice: Double) throws -> Data {
        let rate = RateCard(
            inputPerMTok: 20,
            outputPerMTok: 75,
            cacheReadPerMTok: 2,
            cacheWrite5mPerMTok: 25,
            cacheWrite1hPerMTok: 25
        )
        let snapshot = PricingSnapshot(
            snapshotVersion: "remote-test",
            source: "litellm",
            models: [
                "gpt-6-astra": ModelPricing(
                    inputPerMTok: inputPrice,
                    outputPerMTok: 50,
                    cacheReadPerMTok: 1,
                    cacheWrite5mPerMTok: 12.5,
                    cacheWrite1hPerMTok: 12.5,
                    longContext: LongContextPricing(thresholdTokens: 272_000, rate: rate)
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class PricingSnapshotMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (statusCode: Int, data: Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let result = try XCTUnwrap(Self.handler)(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: result.statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/octet-stream"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
