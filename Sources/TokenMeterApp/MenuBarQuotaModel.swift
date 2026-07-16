import Foundation
import TokenMeterCore

/// 菜单栏额度组件的数据投影(Stats 式常驻图表,用户裁定的「网速组件」形态:
/// 每家一个双层电池条 + 双行小文字,上 5h 下 7d;单窗口的家退化为单条单行)。
/// 窗口选取与弹窗的环同一口径——复用 QuotaDisplayModel 的 rings(主组前两个
/// 百分比窗口 + pace 警戒 tone),两处显示永远一致。
enum MenuBarQuotaModel {
    struct Window: Equatable {
        let label: String
        /// 剩余百分比(与弹窗环同语义:越大越充裕)。
        let remainingPercent: Double
        let tone: UsageMetricTone
    }

    struct Cell: Equatable {
        let providerId: String
        /// 品牌短名(displayName 首词:「Claude」「Codex」「智谱」)——
        /// 缩写(Cl/Co)在菜单栏里认不出是谁(用户裁定,要写清楚)。
        let badge: String
        /// 1 或 2 个窗口;空窗口的 provider 不产 cell。
        let windows: [Window]
    }

    static func cells(from snapshots: [ProviderUsageSnapshot], now: Date = Date()) -> [Cell] {
        snapshots.compactMap { snapshot in
            let model = QuotaDisplayModel(snapshot: snapshot, now: now)
            let windows = model.rings.map {
                Window(label: $0.label, remainingPercent: $0.percent, tone: $0.tone)
            }
            guard !windows.isEmpty else { return nil }
            let shortName = snapshot.displayName.split(separator: " ").first.map(String.init)
                ?? snapshot.displayName
            return Cell(providerId: snapshot.providerId, badge: shortName, windows: windows)
        }
    }
}
