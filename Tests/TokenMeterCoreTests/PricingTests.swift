import XCTest
@testable import TokenMeterCore

final class PricingTests: XCTestCase {
    private static func utcDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func peakTier(weekdaysOnly: Bool = false, holidays: [CalendarDay] = []) -> PeakOffPeakPricing {
        func rate(_ input: Double) -> RateCard {
            RateCard(inputPerMTok: input, outputPerMTok: input * 2, cacheReadPerMTok: 0,
                     cacheWrite5mPerMTok: 0, cacheWrite1hPerMTok: 0)
        }
        return PeakOffPeakPricing(
            effectiveAfter: Self.utcDate(2026, 8, 16, 16),
            peakHoursUTC: [1, 2, 3, 6, 7, 8, 9],
            weekdaysOnly: weekdaysOnly,
            holidays: holidays,
            peak: rate(0.44),
            offPeak: rate(0.22)
        )
    }

    func testLoadsBundledSnapshot() throws {
        let snapshot = try PricingSnapshot.loadBundled()
        XCTAssertFalse(snapshot.snapshotVersion.isEmpty)
        XCTAssertEqual(snapshot.source, "litellm")
        // 353 个模型。掉到 300 以下说明过滤条件坏了。
        XCTAssertGreaterThan(snapshot.models.count, 300)
    }

    func testBundledSnapshotPricesTheModelsThisMachineActuallyUses() throws {
        let snapshot = try PricingSnapshot.loadBundled()
        var byCanonical: [String: ModelPricing] = [:]
        for (key, pricing) in snapshot.models {
            byCanonical[ModelNameNormalizer.canonical(key)] = pricing
        }

        // 本机四个 agent 实际上报的模型名
        for model in ["claude-fable-5", "glm-4.6"] {
            let pricing = try XCTUnwrap(byCanonical[model], "\(model) 缺定价，成本会静默变成 unknown")
            XCTAssertGreaterThan(pricing.inputPerMTok, 0, "\(model) 的 input 价必须为正")
            XCTAssertGreaterThan(pricing.outputPerMTok, 0, "\(model) 的 output 价必须为正")
        }
    }

    func testEveryBundledModelHasPositiveBasePrices() throws {
        let snapshot = try PricingSnapshot.loadBundled()
        // 转换脚本会跳过没有基础价的条目，快照里不该有零价模型
        for (key, pricing) in snapshot.models {
            XCTAssertGreaterThan(pricing.inputPerMTok, 0, "\(key) 的 inputPerMTok 为零")
            XCTAssertGreaterThan(pricing.outputPerMTok, 0, "\(key) 的 outputPerMTok 为零")
        }
    }

    func testDecodesModelPricing() throws {
        let json = """
        {
          "snapshotVersion": "abc123",
          "source": "litellm",
          "models": {
            "claude-opus-4-8": {
              "inputPerMTok": 15.0,
              "outputPerMTok": 75.0,
              "cacheReadPerMTok": 1.5,
              "cacheWrite5mPerMTok": 18.75,
              "cacheWrite1hPerMTok": 30.0
            }
          }
        }
        """
        let snapshot = try JSONDecoder().decode(PricingSnapshot.self, from: Data(json.utf8))
        let pricing = try XCTUnwrap(snapshot.models["claude-opus-4-8"])
        XCTAssertEqual(pricing.inputPerMTok, 15.0)
        XCTAssertEqual(pricing.cacheWrite1hPerMTok, 30.0)
    }

    func testDecodesTieredPricing() throws {
        let json = """
        {
          "snapshotVersion": "abc123",
          "source": "litellm",
          "models": {
            "deepseek-v4-flash": {
              "inputPerMTok": 0.14,
              "outputPerMTok": 0.28,
              "cacheReadPerMTok": 0.0028,
              "cacheWrite5mPerMTok": 0.0,
              "cacheWrite1hPerMTok": 0.28,
              "tiered": {
                "effectiveAfter": "2026-08-16T16:00:00Z",
                "peakHoursUTC": [1, 2, 3, 6, 7, 8, 9],
                "peak": {
                  "inputPerMTok": 0.44,
                  "outputPerMTok": 1.32,
                  "cacheReadPerMTok": 0.014,
                  "cacheWrite5mPerMTok": 0.0,
                  "cacheWrite1hPerMTok": 0.28
                },
                "offPeak": {
                  "inputPerMTok": 0.22,
                  "outputPerMTok": 0.66,
                  "cacheReadPerMTok": 0.007,
                  "cacheWrite5mPerMTok": 0.0,
                  "cacheWrite1hPerMTok": 0.28
                }
              }
            }
          }
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(PricingSnapshot.self, from: Data(json.utf8))
        let tiered = try XCTUnwrap(snapshot.models["deepseek-v4-flash"]?.tiered)
        XCTAssertEqual(tiered.effectiveAfter, ISO8601DateFormatter().date(from: "2026-08-16T16:00:00Z"))
        XCTAssertEqual(tiered.peakHoursUTC, [1, 2, 3, 6, 7, 8, 9])
        // 旧快照没有 weekdaysOnly/holidays：解码补默认值，不炸。
        XCTAssertFalse(tiered.weekdaysOnly)
        XCTAssertTrue(tiered.holidays.isEmpty)
        XCTAssertEqual(tiered.peak.outputPerMTok, 1.32)
        XCTAssertEqual(tiered.offPeak.outputPerMTok, 0.66)
    }

    func testDecodesTieredPricingWithWeekdayAndHolidayRules() throws {
        let json = """
        {
          "snapshotVersion": "abc123",
          "source": "litellm",
          "models": {
            "deepseek-v4-flash": {
              "inputPerMTok": 0.14,
              "outputPerMTok": 0.28,
              "cacheReadPerMTok": 0.0028,
              "cacheWrite5mPerMTok": 0.0,
              "cacheWrite1hPerMTok": 0.28,
              "tiered": {
                "effectiveAfter": "2026-08-16T16:00:00Z",
                "peakHoursUTC": [1, 2, 3, 6, 7, 8, 9],
                "weekdaysOnly": true,
                "holidays": [
                  {"year": 2026, "month": 10, "day": 1},
                  {"year": 2026, "month": 10, "day": 2}
                ],
                "peak": {
                  "inputPerMTok": 0.44,
                  "outputPerMTok": 1.32,
                  "cacheReadPerMTok": 0.014,
                  "cacheWrite5mPerMTok": 0.0,
                  "cacheWrite1hPerMTok": 0.28
                },
                "offPeak": {
                  "inputPerMTok": 0.22,
                  "outputPerMTok": 0.66,
                  "cacheReadPerMTok": 0.007,
                  "cacheWrite5mPerMTok": 0.0,
                  "cacheWrite1hPerMTok": 0.28
                }
              }
            }
          }
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(PricingSnapshot.self, from: Data(json.utf8))
        let tiered = try XCTUnwrap(snapshot.models["deepseek-v4-flash"]?.tiered)
        XCTAssertTrue(tiered.weekdaysOnly)
        XCTAssertEqual(tiered.holidays, [CalendarDay(year: 2026, month: 10, day: 1),
                                         CalendarDay(year: 2026, month: 10, day: 2)])
    }

    func testBundledSnapshotCarriesDeepSeekTieredPricing() throws {
        let snapshot = try PricingSnapshot.loadBundled()
        for name in ["deepseek-v4-flash", "deepseek-v4-pro"] {
            let tiered = try XCTUnwrap(snapshot.models[name]?.tiered, "\(name) 缺峰谷价，8/17 后会被按旧 flat 价计费")
            XCTAssertEqual(tiered.effectiveAfter, ISO8601DateFormatter().date(from: "2026-08-16T16:00:00Z"))
            XCTAssertEqual(tiered.peakHoursUTC, [1, 2, 3, 6, 7, 8, 9])
            XCTAssertTrue(tiered.weekdaysOnly, "\(name) 高峰必须只在工作日")
            XCTAssertEqual(tiered.holidays.count, 33, "\(name) 缺国务院办公厅 2026 法定节假日")
            XCTAssertTrue(tiered.holidays.contains(CalendarDay(year: 2026, month: 10, day: 1)))
            XCTAssertEqual(tiered.offPeak.inputPerMTok, tiered.peak.inputPerMTok / 2, accuracy: 1e-9)
            XCTAssertEqual(tiered.offPeak.outputPerMTok, tiered.peak.outputPerMTok / 2, accuracy: 1e-9)
            XCTAssertEqual(tiered.offPeak.cacheReadPerMTok, tiered.peak.cacheReadPerMTok / 2, accuracy: 1e-9)
        }
    }

    func testPeakPhaseBoundaries() {
        let tier = peakTier()

        // 生效前一分钟仍是旧 flat 价期
        XCTAssertEqual(tier.phase(at: Self.utcDate(2026, 8, 16, 15, 59)), .notYetEffective)
        // 生效时刻（北京 8/17 00:00）已按峰谷计价，且该小时空闲
        XCTAssertEqual(tier.phase(at: Self.utcDate(2026, 8, 16, 16, 0)), .offPeak)
        // 北京 9:30（高峰首窗内）与 11:59
        XCTAssertEqual(tier.phase(at: Self.utcDate(2026, 8, 17, 1, 30)), .peak)
        XCTAssertEqual(tier.phase(at: Self.utcDate(2026, 8, 17, 3, 59)), .peak)
        // 北京 12:00–13:59 是午间空隙
        XCTAssertEqual(tier.phase(at: Self.utcDate(2026, 8, 17, 4, 0)), .offPeak)
        // 北京 14:00 进第二高峰窗、18:00 退出
        XCTAssertEqual(tier.phase(at: Self.utcDate(2026, 8, 17, 6, 0)), .peak)
        XCTAssertEqual(tier.phase(at: Self.utcDate(2026, 8, 17, 10, 0)), .offPeak)
        // 深夜（北京 8/17 02:00 = UTC 8/16 18:00）
        XCTAssertEqual(tier.phase(at: Self.utcDate(2026, 8, 16, 18, 0)), .offPeak)
    }

    func testWeekdayOnlyKeepsEveryDayHourlyWhenFlagOff() {
        // weekdaysOnly=false 是旧语义：周六也照常按小时进高峰。
        let tier = peakTier()
        // 2026-09-26 是周六，北京 10:00 = UTC 02:00
        XCTAssertEqual(tier.phase(at: Self.utcDate(2026, 9, 26, 2, 0)), .peak)
    }

    func testWeekendIsOffPeakAllDay() {
        // 2026-09-26 是周六，北京 10:00 = UTC 02:00：高峰窗口内也必须是空闲。
        let tier = peakTier(weekdaysOnly: true)
        XCTAssertEqual(tier.phase(at: Self.utcDate(2026, 9, 26, 2, 0)), .offPeak)
        // 周日的凌晨（北京 03:00 = 周六 UTC 19:00）同样空闲
        XCTAssertEqual(tier.phase(at: Self.utcDate(2026, 9, 26, 19, 0)), .offPeak)
    }

    func testStatutoryHolidayWeekdayIsOffPeakAllDay() {
        // 2026-10-01 国庆（周四），北京 10:00 = UTC 02:00：节假日整天空闲。
        let tier = peakTier(weekdaysOnly: true, holidays: [CalendarDay(year: 2026, month: 10, day: 1)])
        XCTAssertEqual(tier.phase(at: Self.utcDate(2026, 10, 1, 2, 0)), .offPeak)
        XCTAssertEqual(tier.phase(at: Self.utcDate(2026, 10, 1, 12, 0)), .offPeak)
    }

    func testWorkingDayWindowsStillApply() {
        // 2026-09-24 是周四（非节假日），北京 9:30 = UTC 01:30 高峰、12:00 午间空闲。
        let tier = peakTier(weekdaysOnly: true)
        XCTAssertEqual(tier.phase(at: Self.utcDate(2026, 9, 24, 1, 30)), .peak)
        XCTAssertEqual(tier.phase(at: Self.utcDate(2026, 9, 24, 4, 0)), .offPeak)
    }

    func testFridayToWeekendBoundaryUsesBeijingDay() {
        let tier = peakTier(weekdaysOnly: true)
        // 2026-09-18 周五：北京 17:59 = UTC 09:59 高峰
        XCTAssertEqual(tier.phase(at: Self.utcDate(2026, 9, 18, 9, 59)), .peak)
        // 北京 9/19 00:00（周六）= UTC 9/18 16:00：跨日即空闲
        XCTAssertEqual(tier.phase(at: Self.utcDate(2026, 9, 18, 16, 0)), .offPeak)
    }

    func testNextTransitionSkipsWeekend() {
        // 周五 18:00（北京）空闲 → 下一次切换是周一 9:00 进高峰。
        let tier = peakTier(weekdaysOnly: true)
        let transition = tier.nextTransition(after: Self.utcDate(2026, 9, 18, 10, 0))
        XCTAssertEqual(transition?.phase, .peak)
        XCTAssertEqual(transition?.at, Self.utcDate(2026, 9, 21, 1, 0))
    }

    func testSchedulePhaseIgnoresEffectiveDate() {
        let tier = peakTier(weekdaysOnly: true)
        // 生效前的工作日高峰窗（北京 8/14 周五 9:30 = UTC 01:30）：
        // 时刻表口径给「峰」，计价口径仍按 notYetEffective 走基础价。
        // 菜单栏/弹窗只按计价口径显示：生效前完全不出现。
        let date = Self.utcDate(2026, 8, 14, 1, 30)
        XCTAssertEqual(tier.schedulePhase(at: date), .peak)
        XCTAssertEqual(tier.phase(at: date), .notYetEffective)
    }

    func testNextTransitionFindsNextHourlySwitch() {
        let tier = peakTier()
        // 8/16 15:00 UTC = 北京 23:00 空闲：下一个切换是北京次日 9:00
        // （UTC 8/17 01:00）进高峰。
        let transition = tier.nextTransition(after: Self.utcDate(2026, 8, 16, 15, 0))
        XCTAssertEqual(transition?.phase, .peak)
        XCTAssertEqual(transition?.at, Self.utcDate(2026, 8, 17, 1, 0))
    }

    func testBeijingPeakRangesMergeContiguousUtcHours() {
        let tier = peakTier()
        let ranges = tier.beijingPeakRanges
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0].start, 9)
        XCTAssertEqual(ranges[0].end, 12)
        XCTAssertEqual(ranges[1].start, 14)
        XCTAssertEqual(ranges[1].end, 18)
    }
}
