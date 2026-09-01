import XCTest
@testable import TokenMeterCore

final class CustomPricingTests: XCTestCase {
    // MARK: - 加载

    func testLoadThrowsWhenFileMissing() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("missing-\(UUID().uuidString).json")
        XCTAssertThrowsError(try CustomPricingOverrides.load(url: url))
    }

    func testLoadParsesOverridesAndCanonicalizesKeys() throws {
        let url = try writeConfig("""
        {
          "ox-alpha-free": {"inputPerMTok": 0, "outputPerMTok": 0, "cacheReadPerMTok": 0,
                            "cacheWrite5mPerMTok": 0, "cacheWrite1hPerMTok": 0},
          "omniroute/cx/gpt-5.5": {"inputPerMTok": 1.25, "outputPerMTok": 10.0, "cacheReadPerMTok": 0.125,
                                   "cacheWrite5mPerMTok": 0.0, "cacheWrite1hPerMTok": 0.0},
          "deepseek-v4-pro": {"inputPerMTok": 1.32, "outputPerMTok": 3.96, "cacheReadPerMTok": 0.044,
                              "cacheWrite5mPerMTok": 0.0, "cacheWrite1hPerMTok": 0.87,
                              "ignoreReported": true}
        }
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        let overrides = try CustomPricingOverrides.load(url: url)
        XCTAssertEqual(overrides.models.count, 3)
        XCTAssertNotNil(overrides.fingerprint)
        // canonicalKeys 与 usage_events.model_canonical 同一归一化：前缀键剥到最后一段。
        XCTAssertEqual(overrides.canonicalKeys, ["ox-alpha-free", "gpt-5.5", "deepseek-v4-pro"])
        XCTAssertEqual(overrides.ignoredReportedKeys, ["deepseek-v4-pro"])
    }

    func testLoadTreatsInvalidJSONAsEmptyForRetry() throws {
        let url = try writeConfig("{ not valid json")
        defer { try? FileManager.default.removeItem(at: url) }

        let overrides = try CustomPricingOverrides.load(url: url)
        XCTAssertTrue(overrides.models.isEmpty)
        // fingerprint 为 nil：每轮扫描都会重试，修好 JSON 立即生效。
        XCTAssertNil(overrides.fingerprint)
    }

    func testResolvedEntriesInheritBundledPricesAndDropUnresolvable() throws {
        let bundled = PricingSnapshot(
            snapshotVersion: "v1",
            source: "litellm",
            models: [
                "deepseek-v4-pro": ModelPricing(
                    inputPerMTok: 0.435, outputPerMTok: 0.87, cacheReadPerMTok: 0.003625,
                    cacheWrite5mPerMTok: 0, cacheWrite1hPerMTok: 0.87,
                    tiered: PeakOffPeakPricing(
                        effectiveAfter: Date(timeIntervalSince1970: 0),
                        peakHoursUTC: [1], weekdaysOnly: true, holidays: [],
                        peak: RateCard(inputPerMTok: 1.32, outputPerMTok: 3.96, cacheReadPerMTok: 0.044,
                                       cacheWrite5mPerMTok: 0, cacheWrite1hPerMTok: 0.87),
                        offPeak: RateCard(inputPerMTok: 0.66, outputPerMTok: 1.98, cacheReadPerMTok: 0.022,
                                          cacheWrite5mPerMTok: 0, cacheWrite1hPerMTok: 0.87)
                    )
                )
            ]
        )

        // 已知模型只开开关：价格（含 tiered）必须整体继承内置价。
        let known = CustomPricingEntry(ignoreReported: true)
        // 未知模型只开开关：凑不齐五价 → 整条丢弃。
        let unknown = CustomPricingEntry(ignoreReported: true)
        let overrides = CustomPricingOverrides(
            models: ["deepseek-v4-pro": known, "never-heard-of": unknown],
            fingerprint: "f",
            canonicalKeys: ["deepseek-v4-pro", "never-heard-of"],
            ignoredReportedKeys: ["deepseek-v4-pro", "never-heard-of"]
        )

        let (resolved, dropped) = overrides.resolvedModels(bundled: bundled)
        XCTAssertEqual(dropped, ["never-heard-of"])
        let pricing = try XCTUnwrap(resolved["deepseek-v4-pro"])
        XCTAssertEqual(pricing.inputPerMTok, 0.435, "省略的价格字段必须沿用内置价")
        XCTAssertNotNil(pricing.tiered, "内置峰谷档位必须一并继承")
    }

    // MARK: - 合并

    func testMergingOverridesBundledAndKeepsOriginal() throws {
        let bundled = PricingSnapshot(
            snapshotVersion: "v1",
            source: "litellm",
            models: [
                "gpt-5.5": ModelPricing(inputPerMTok: 1.25, outputPerMTok: 10, cacheReadPerMTok: 0.125,
                                        cacheWrite5mPerMTok: 0, cacheWrite1hPerMTok: 0)
            ]
        )
        let merged = bundled.merging(userOverrides: [
            "gpt-5.5": ModelPricing(inputPerMTok: 0, outputPerMTok: 0, cacheReadPerMTok: 0,
                                    cacheWrite5mPerMTok: 0, cacheWrite1hPerMTok: 0),
            "ox-alpha-free": ModelPricing(inputPerMTok: 0, outputPerMTok: 0, cacheReadPerMTok: 0,
                                          cacheWrite5mPerMTok: 0, cacheWrite1hPerMTok: 0)
        ])
        XCTAssertEqual(merged.models["gpt-5.5"]?.inputPerMTok, 0, "同名键必须覆盖内置价")
        XCTAssertNotNil(merged.models["ox-alpha-free"], "新键必须补充进快照")
        XCTAssertEqual(bundled.models["gpt-5.5"]?.inputPerMTok, 1.25, "合并不得改动原快照")
    }

    // MARK: - ignoreReported：强制本地计价覆盖上报价

    func testCostCalculatorIgnoresReportedCostForFlaggedModelsOnly() {
        let pricing = ["m-a": ModelPricing(inputPerMTok: 1, outputPerMTok: 2, cacheReadPerMTok: 0,
                                           cacheWrite5mPerMTok: 0, cacheWrite1hPerMTok: 0)]
        let strict = CostCalculator(
            snapshot: PricingSnapshot(snapshotVersion: "t", source: "test", models: pricing),
            ignoreReportedModels: ["m-a"]
        )
        let lenient = CostCalculator(snapshot: PricingSnapshot(snapshotVersion: "t", source: "test", models: pricing))
        let event = UsageEvent(eventSeq: 0, observedAt: Date(), modelName: "m-a", dedupeKey: nil,
                               inputTokens: 1_000_000, reportedCostUSDMicros: 99,
                               sourceOffset: 0)

        // 被标记：上报价 99 被忽略，按本地价 $1/MTok × 1M = $1。
        let forced = strict.cost(for: event)
        XCTAssertEqual(forced.source, .computed)
        XCTAssertEqual(forced.micros, 1_000_000)
        // 未标记：照旧采信上报价。
        XCTAssertEqual(lenient.cost(for: event).source, .reported)
    }

    func testIgnoreReportedOverridesThenRestoresReportedCost() async throws {
        let fixture = try CustomPricingScanFixture.make(model: "omp-model", kind: .ompJSONL)
        defer { fixture.cleanup() }

        // 首扫：OMP 带 cost.total → reported，原值落库、无留底。
        try await fixture.scanner.scanRoot(id: 1)
        var row = try fixture.eventRow()
        XCTAssertEqual(row.source, "reported")
        XCTAssertEqual(row.costMicros, 15_000)   // omp fixture: cost.total = 0.015
        XCTAssertNil(row.reportedBackupMicros)

        // 开 ignoreReported + 自定义价（input $100/MTok × 2000 in + output $200/MTok × 300 out
        // = $0.26）→ 存量行被改写为 computed，原上报价留底。
        try fixture.writePricing(model: "omp-model", input: 100, output: 200, ignoreReported: true)
        try await fixture.scanner.scanRoot(id: 1)

        row = try fixture.eventRow()
        XCTAssertEqual(row.source, "computed")
        XCTAssertEqual(row.costMicros, 260_000)
        XCTAssertEqual(row.reportedBackupMicros, 15_000, "原始上报价必须留底")

        // 新事件同样直接走本地计价并留底。
        try fixture.appendOmpEvent(sessionKey: "omp-force-2")
        try await fixture.scanner.scanRoot(id: 1)
        for r in try fixture.allEventRows() {
            XCTAssertEqual(r.source, "computed")
            XCTAssertEqual(r.reportedBackupMicros, 15_000)
        }

        // 移除开关：从留底还原原值，cost_source 回到 reported。
        try FileManager.default.removeItem(at: fixture.pricingURL)
        try await fixture.scanner.scanRoot(id: 1)

        for r in try fixture.allEventRows() {
            XCTAssertEqual(r.source, "reported")
            XCTAssertEqual(r.costMicros, 15_000, "必须从留底还原为原始上报价")
            XCTAssertNil(r.reportedBackupMicros, "还原后留底应清空")
        }
    }

    func testTieredReportedCostRemainsLocalWhenCustomPricingChanges() async throws {
        let fixture = try CustomPricingScanFixture.make(model: "deepseek-v4-flash", kind: .ompJSONL)
        defer { fixture.cleanup() }

        // 峰谷模型即使 OMP 带上报价，也从首扫开始按模型本地价计算，并保留原上报价。
        try await fixture.scanner.scanRoot(id: 1)
        var row = try fixture.eventRow()
        XCTAssertEqual(row.source, "computed")
        XCTAssertEqual(row.costMicros, 364)
        XCTAssertEqual(row.reportedBackupMicros, 15_000)

        // 覆盖模型基础价并触发重投影：峰谷模型仍不能恢复成供应商上报价。
        try fixture.writePricing(model: "deepseek-v4-flash", input: 100, output: 200)
        try await fixture.scanner.scanRoot(id: 1)
        row = try fixture.eventRow()
        XCTAssertEqual(row.source, "computed")
        XCTAssertEqual(row.costMicros, 260_000)
        XCTAssertEqual(row.reportedBackupMicros, 15_000)

        // 移除覆盖后回到随包峰谷模型基础价，原上报价仍只是留底，不再作为计价结果。
        try FileManager.default.removeItem(at: fixture.pricingURL)
        try await fixture.scanner.scanRoot(id: 1)
        row = try fixture.eventRow()
        XCTAssertEqual(row.source, "computed")
        XCTAssertEqual(row.costMicros, 364)
        XCTAssertEqual(row.reportedBackupMicros, 15_000)
    }

    // MARK: - 扫描器集成


    func testScannerReprojectsUnknownEventsToFreeWhenCustomPricingAppears() async throws {
        let fixture = try CustomPricingScanFixture.make()
        defer { fixture.cleanup() }

        // 无覆盖首扫：ox-alpha-free 不在定价表里 → unknown、成本空。
        try await fixture.scanner.scanRoot(id: 1)
        var event = try fixture.eventRow()
        XCTAssertEqual(event.source, "unknown")
        XCTAssertNil(event.costMicros)
        XCTAssertEqual(try fixture.rollupUnknownCount(), 1)

        // 写入全零价覆盖 → 下轮扫描把存量 unknown 重投影为 computed $0。
        try fixture.writePricing(model: "ox-alpha-free", input: 0, output: 0)
        try await fixture.scanner.scanRoot(id: 1)

        event = try fixture.eventRow()
        XCTAssertEqual(event.source, "computed", "免费模型必须按 $0 计为 computed，不再显示价格未知")
        XCTAssertEqual(event.costMicros, 0)
        XCTAssertEqual(try fixture.rollupUnknownCount(), 0, "rollup 的 unknown 计数必须同步归零")
        XCTAssertEqual(try fixture.rollupCostMicros(), 0)

        // 新事件也走覆盖价（仍是 0）：不会因为 calculator 未刷新而退回 unknown。
        try fixture.appendEvent(sessionKey: "free-model-2")
        try await fixture.scanner.scanRoot(id: 1)
        let rows = try fixture.allEventRows()
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.source == "computed" && $0.costMicros == 0 })
    }

    func testScannerFallsBackToUnknownWhenCustomPricingRemoved() async throws {
        let fixture = try CustomPricingScanFixture.make()
        defer { fixture.cleanup() }

        try fixture.writePricing(model: "ox-alpha-free", input: 0, output: 0)
        try await fixture.scanner.scanRoot(id: 1)
        XCTAssertEqual(try fixture.eventRow().source, "computed")

        // 覆盖移除 → 回退语义：该模型没有内置价，应回到 unknown，而不是沿用旧 computed。
        try FileManager.default.removeItem(at: fixture.pricingURL)
        try await fixture.scanner.scanRoot(id: 1)

        let event = try fixture.eventRow()
        XCTAssertEqual(event.source, "unknown")
        XCTAssertNil(event.costMicros)
        XCTAssertEqual(try fixture.rollupUnknownCount(), 1)
    }

    func testScannerAppliesNonZeroOverrideOverBundledPrice() async throws {
        // 内置已有价的模型被用户覆盖为自定义价：重投影与后续计价都用覆盖价。
        let fixture = try CustomPricingScanFixture.make(model: "claude-fable-5")
        defer { fixture.cleanup() }

        try await fixture.scanner.scanRoot(id: 1)
        let bundledCost = try XCTUnwrap(fixture.eventRow().costMicros, "内置价模型首扫应有成本")

        // input $100/MTok、output $200/MTok：1000 in + 500 out → 100000 + 100000 = 200000 micros。
        try fixture.writePricing(model: "claude-fable-5", input: 100, output: 200)
        try await fixture.scanner.scanRoot(id: 1)

        let event = try fixture.eventRow()
        XCTAssertEqual(event.source, "computed")
        XCTAssertEqual(event.costMicros, 200_000, "存量事件必须按用户覆盖价重算")
        XCTAssertNotEqual(event.costMicros, bundledCost)
    }
}

// MARK: - Fixtures

/// 一个最小 agent 根 + 内存库 + 独立 custom-pricing.json 的集成测试环境。
private final class CustomPricingScanFixture {
    let root: URL
    let pricingURL: URL
    let database: SQLiteDatabase
    let scanner: LocalAgentScanner
    private let sessionKey: String
    private let kind: SourceKind

    static func make(model: String = "ox-alpha-free", kind: SourceKind = .claudeJSONL) throws -> CustomPricingScanFixture {
        try self.init(model: model, kind: kind)
    }

    init(model: String, kind: SourceKind) throws {
        root = try temporaryDirectory()
        self.kind = kind
        sessionKey = "custom-pricing-\(model)"
        let content: String
        switch kind {
        case .claudeJSONL:
            content = claudeEventLine(sessionKey: sessionKey, model: model)
        case .ompJSONL:
            content = ompEventLines(sessionKey: sessionKey, model: model)
        default:
            fatalError("fixture 未支持的 kind: \(kind.rawValue)")
        }
        try Data(content.utf8).write(to: root.appendingPathComponent("\(sessionKey).jsonl"))

        let database = try SQLiteDatabase(path: ":memory:")
        try TokenMeterDatabaseMigrator.migrate(database)
        try database.execute(
            "INSERT INTO scan_roots(id, kind, root_path, display_name, stable_source_key) VALUES (?, ?, ?, ?, ?)",
            [.int(1), .text(kind.rawValue), .text(root.path),
             .text(kind.rawValue), .text("\(kind.rawValue):\(root.path)")]
        )
        self.database = database
        pricingURL = root.appendingPathComponent("custom-pricing.json")
        self.scanner = LocalAgentScanner(database: database, customPricingURL: pricingURL)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func writePricing(model: String, input: Double, output: Double, ignoreReported: Bool = false) throws {
        let flag = ignoreReported ? ", \"ignoreReported\": true" : ""
        let json = """
        {"\(model)": {"inputPerMTok": \(input), "outputPerMTok": \(output),
                      "cacheReadPerMTok": 0, "cacheWrite5mPerMTok": 0, "cacheWrite1hPerMTok": 0\(flag)}}
        """
        try Data(json.utf8).write(to: pricingURL)
    }

    /// 追加第二个独立会话文件，验证「新事件也走覆盖价」。
    func appendEvent(sessionKey: String) throws {
        try Data(claudeEventLine(sessionKey: sessionKey, model: "ox-alpha-free").utf8)
            .write(to: root.appendingPathComponent("\(sessionKey).jsonl"))
    }

    /// OMP 变体：usage.cost.total 让事件带上 reported 成本（$0.015）。
    func appendOmpEvent(sessionKey: String) throws {
        try Data(ompEventLines(sessionKey: sessionKey, model: "omp-model").utf8)
            .write(to: root.appendingPathComponent("\(sessionKey).jsonl"))
    }

    struct EventRow: Equatable {
        let source: String?
        let costMicros: Int64?
        let reportedBackupMicros: Int64?
    }

    func eventRow() throws -> EventRow {
        try XCTUnwrap(database.query(eventSQL + " LIMIT 1").first).mapRow()
    }

    func allEventRows() throws -> [EventRow] {
        try database.query(eventSQL + " ORDER BY id").map { $0.mapRow() }
    }

    private var eventSQL: String {
        """
        SELECT cost_source AS source, cost_usd_micros AS cost,
               reported_cost_usd_micros AS backup FROM usage_events
        """
    }

    func rollupUnknownCount() throws -> Int64 {
        try XCTUnwrap(database.query("SELECT coalesce(sum(cost_unknown_events), 0) AS value FROM daily_rollup").first?.int("value"))
    }

    func rollupCostMicros() throws -> Int64 {
        try XCTUnwrap(database.query("SELECT coalesce(sum(cost_usd_micros), 0) AS value FROM daily_rollup").first?.int("value"))
    }
}

private extension SQLiteRow {
    func mapRow() -> CustomPricingScanFixture.EventRow {
        CustomPricingScanFixture.EventRow(
            source: string("source"),
            costMicros: int("cost"),
            reportedBackupMicros: int("backup")
        )
    }
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func writeConfig(_ json: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("custom-pricing-\(UUID().uuidString).json")
    try Data(json.utf8).write(to: url)
    return url
}

private func claudeEventLine(sessionKey: String, model: String) -> String {
    "{\"sessionId\":\"\(sessionKey)\",\"cwd\":\"/repo\",\"timestamp\":\"2026-07-03T02:00:00Z\",\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"model\":\"\(model)\",\"usage\":{\"input_tokens\":1000,\"output_tokens\":500}}}\n"
}

/// OMP 会话：usage.cost.total 让事件带上 reported 成本（$0.015 = 15000 micros）。
private func ompEventLines(sessionKey: String, model: String) -> String {
    """
    {"type":"session","id":"\(sessionKey)","timestamp":"2026-07-03T02:00:00Z","cwd":"/repo"}
    {"type":"message","id":"\(sessionKey)-m1","timestamp":"2026-07-03T02:05:00Z","message":{"role":"assistant","model":"\(model)","usage":{"input":2000,"output":300,"cost":{"total":0.015}}}}

    """
}
