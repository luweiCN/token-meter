import Foundation

/// 一套固定单价（每百万 token 美元）。峰谷档位与基础价共用这份五元组，
/// 避免 ModelPricing 里再嵌 ModelPricing 造成值类型递归。
public struct RateCard: Equatable, Codable {
    public let inputPerMTok: Double
    public let outputPerMTok: Double
    public let cacheReadPerMTok: Double
    public let cacheWrite5mPerMTok: Double
    public let cacheWrite1hPerMTok: Double

    public init(
        inputPerMTok: Double,
        outputPerMTok: Double,
        cacheReadPerMTok: Double,
        cacheWrite5mPerMTok: Double,
        cacheWrite1hPerMTok: Double
    ) {
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
        self.cacheReadPerMTok = cacheReadPerMTok
        self.cacheWrite5mPerMTok = cacheWrite5mPerMTok
        self.cacheWrite1hPerMTok = cacheWrite1hPerMTok
    }
}

/// 北京日历日（年/月/日）。峰谷价的法定节假日豁免用它表示，不含时区信息，
/// 「是不是节假日」只按北京这一天的日期比较。
public struct CalendarDay: Equatable, Hashable, Codable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }
}

/// 峰谷定价：一天内按小时分成高峰 / 空闲两档。
///
/// 目前只有 DeepSeek 用（2026-08-17 起生效）：空闲时段价格为高峰时段的一半。
/// 高峰时段为北京时间 9:00–12:00、14:00–18:00，即 UTC 1–3 点与 6–9 点
/// （其余小时为空闲）。`peakHoursUTC` 用 UTC 整点小时表示，与时区无关、
/// 也不受夏令时影响。
///
/// DeepSeek 官方口径：高峰只在工作日，周末与法定节假日整天按空闲价
/// （官方后台公告：「工作日高峰时段……周末、法定节假日执行平峰原价」）。
/// `weekdaysOnly` 打开后按北京日历日判：周六/周日整天空闲；`holidays`
/// 里的法定节假日（即使落在工作日）也整天空闲。调休上班的周六仍按
/// 「周末」整天空闲（公告只把「周末」整体划给平峰，未提及调休例外）。
public struct PeakOffPeakPricing: Equatable, Codable {
    /// 峰谷价生效时刻（含）。早于此的事件仍按 ModelPricing 的基础价计。
    public let effectiveAfter: Date
    /// 高峰时段的小时集合（0–23，UTC）。不在集合内的小时按空闲价。
    public let peakHoursUTC: [Int]
    /// true = 高峰只在工作日（北京时区周一至周五、且非法定节假日）。
    /// false = 每天按小时切，不看星期与节假日。
    public let weekdaysOnly: Bool
    /// 法定节假日（北京日历日，含当日）。`weekdaysOnly` 时才参与判定。
    public let holidays: [CalendarDay]
    public let peak: RateCard
    public let offPeak: RateCard

    public init(
        effectiveAfter: Date,
        peakHoursUTC: [Int],
        weekdaysOnly: Bool = false,
        holidays: [CalendarDay] = [],
        peak: RateCard,
        offPeak: RateCard
    ) {
        self.effectiveAfter = effectiveAfter
        self.peakHoursUTC = peakHoursUTC
        self.weekdaysOnly = weekdaysOnly
        self.holidays = holidays
        self.peak = peak
        self.offPeak = offPeak
    }

    /// 某个时刻落在哪个档位：生效前（notYetEffective）或高峰 / 空闲。
    public func phase(at date: Date) -> PeakOffPeakPhase {
        PeakOffPeakPhase.at(date: date, tiered: self)
    }

    /// 高峰窗口按北京时间表达：连续的 UTC 小时并成 (start, end) 区间，end 不含。
    /// 例：UTC [1,2,3,6,7,8,9] → 北京 9:00–12:00、14:00–18:00，即 [(9,12),(14,18)]。
    /// 给弹窗「高峰：工作日 9:00–12:00…」这类文案用，文案随数据走而不是写死。
    public var beijingPeakRanges: [(start: Int, end: Int)] {
        let beijingHours = Set(peakHoursUTC.map { ($0 + 8) % 24 }).sorted()
        guard let first = beijingHours.first else { return [] }
        var ranges: [(start: Int, end: Int)] = []
        var start = first
        var previous = first
        for hour in beijingHours.dropFirst() {
            if hour != previous + 1 {
                ranges.append((start, previous + 1))
                start = hour
            }
            previous = hour
        }
        ranges.append((start, previous + 1))
        return ranges
    }

    /// 只看时刻表（工作日/节假日/小时）的档位，不看成不生效——菜单栏与弹窗的
    /// 标识用它：没生效也照常显示样式，生效后同一显示自然变成真实档位。
    public func schedulePhase(at date: Date) -> PeakOffPeakPhase {
        PeakOffPeakPhase.scheduled(at: date, tiered: self)
    }

    /// `date` 之后档位第一次改变的时刻与去向。找不到（不应发生）返回 nil。
    /// 给弹窗「17:00 转谷」这类提示用：从下一整点起逐小时探测，
    /// 跨周末/跨法定节假日都能覆盖（最长间隔是周五 18:00 → 周一 9:00，约 63 小时）。
    public func nextTransition(after date: Date) -> PhaseTransition? {
        let current = schedulePhase(at: date)
        let calendar = Self.utcCalendar
        var probe = calendar.dateInterval(of: .hour, for: date)?.end
            ?? date.addingTimeInterval(3600)
        for _ in 0..<(45 * 24) {
            let next = schedulePhase(at: probe)
            if next != current {
                return PhaseTransition(phase: next, at: probe)
            }
            probe = probe.addingTimeInterval(3600)
        }
        return nil
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    // 旧快照只有 effectiveAfter/peakHoursUTC/peak/offPeak。新增字段缺省
    // （weekdaysOnly=false、holidays=[]）时保持按小时切价的旧语义，不炸解码。
    private enum CodingKeys: String, CodingKey {
        case effectiveAfter
        case peakHoursUTC
        case weekdaysOnly
        case holidays
        case peak
        case offPeak
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        effectiveAfter = try container.decode(Date.self, forKey: .effectiveAfter)
        peakHoursUTC = try container.decode([Int].self, forKey: .peakHoursUTC)
        weekdaysOnly = try container.decodeIfPresent(Bool.self, forKey: .weekdaysOnly) ?? false
        holidays = try container.decodeIfPresent([CalendarDay].self, forKey: .holidays) ?? []
        peak = try container.decode(RateCard.self, forKey: .peak)
        offPeak = try container.decode(RateCard.self, forKey: .offPeak)
    }
}

/// 峰谷价的一个时刻状态。菜单栏标识与计价共用同一个判断，时段不会两处漂移。
public enum PeakOffPeakPhase: Equatable {
    case notYetEffective
    case peak
    case offPeak

    public static func at(date: Date, tiered: PeakOffPeakPricing) -> PeakOffPeakPhase {
        guard date >= tiered.effectiveAfter else { return .notYetEffective }
        return scheduled(at: date, tiered: tiered)
    }

    public static func scheduled(at date: Date, tiered: PeakOffPeakPricing) -> PeakOffPeakPhase {
        if tiered.weekdaysOnly {
            // 北京没有夏令时，Asia/Shanghai 固定 UTC+8；工作日与节假日按北京日历日判。
            let beijing = beijingCalendar.dateComponents([.year, .month, .day, .weekday], from: date)
            let weekday = beijing.weekday ?? 0
            if weekday == 1 || weekday == 7 { return .offPeak }
            if let year = beijing.year, let month = beijing.month, let day = beijing.day,
               tiered.holidays.contains(CalendarDay(year: year, month: month, day: day)) {
                return .offPeak
            }
        }
        let hour = utcCalendar.component(.hour, from: date)
        return tiered.peakHoursUTC.contains(hour) ? .peak : .offPeak
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private static let beijingCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()
}

/// 档位切换点：`at` 时刻起变成 `phase`。
public struct PhaseTransition: Equatable {
    public let phase: PeakOffPeakPhase
    public let at: Date

    public init(phase: PeakOffPeakPhase, at: Date) {
        self.phase = phase
        self.at = at
    }
}

public struct ModelPricing: Equatable, Codable {
    public let inputPerMTok: Double
    public let outputPerMTok: Double
    public let cacheReadPerMTok: Double
    public let cacheWrite5mPerMTok: Double
    public let cacheWrite1hPerMTok: Double
    /// 可选峰谷价。nil 表示该模型只有一套固定价。
    public let tiered: PeakOffPeakPricing?

    public init(
        inputPerMTok: Double,
        outputPerMTok: Double,
        cacheReadPerMTok: Double,
        cacheWrite5mPerMTok: Double,
        cacheWrite1hPerMTok: Double,
        tiered: PeakOffPeakPricing? = nil
    ) {
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
        self.cacheReadPerMTok = cacheReadPerMTok
        self.cacheWrite5mPerMTok = cacheWrite5mPerMTok
        self.cacheWrite1hPerMTok = cacheWrite1hPerMTok
        self.tiered = tiered
    }

    /// 基础价五元组。峰谷价生效前按它计价。
    public var rate: RateCard {
        RateCard(
            inputPerMTok: inputPerMTok,
            outputPerMTok: outputPerMTok,
            cacheReadPerMTok: cacheReadPerMTok,
            cacheWrite5mPerMTok: cacheWrite5mPerMTok,
            cacheWrite1hPerMTok: cacheWrite1hPerMTok
        )
    }
}

public struct PricingSnapshot: Equatable, Codable {
    public let snapshotVersion: String
    public let source: String
    public let models: [String: ModelPricing]

    public init(snapshotVersion: String, source: String, models: [String: ModelPricing]) {
        self.snapshotVersion = snapshotVersion
        self.source = source
        self.models = models
    }

    /// 从随包分发的快照加载。运行时不发起任何网络请求。
    public static func loadBundled() throws -> PricingSnapshot {
        guard let url = Bundle.module.url(forResource: "litellm-pricing", withExtension: "json") else {
            throw PricingError.bundledSnapshotMissing
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PricingSnapshot.self, from: Data(contentsOf: url))
    }
}

public enum PricingError: Error, Equatable {
    case bundledSnapshotMissing
}
