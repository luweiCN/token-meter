import SwiftUI

/// 固定日 Token 区间。边界同时驱动取色与日期详情，月份和峰值不参与分档。
enum MonthHeatmapBand: Int, CaseIterable {
    case zero, lightBlue, blue, cyan, green, yellow, red

    var minimumTokens: Int64 {
        switch self {
        case .zero: return 0
        case .lightBlue: return 1
        case .blue: return 100_000_000
        case .cyan: return 300_000_000
        case .green: return 600_000_000
        case .yellow: return 1_000_000_000
        case .red: return 2_000_000_000
        }
    }

    static func band(for tokens: Int64) -> Self {
        allCases.last(where: { tokens >= $0.minimumTokens }) ?? .zero
    }

    var rangeLabel: String {
        guard self != .zero else { return "0 Token" }
        let lower = "\(minimumTokens / 100_000_000)亿"
        guard let next = Self(rawValue: rawValue + 1) else { return "\(lower)及以上 Token" }
        let upper = "\(next.minimumTokens / 100_000_000)亿"
        if self == .lightBlue { return "非零，不足\(upper) Token" }
        return "\(lower)至不足\(upper) Token"
    }

    func color(in theme: MBTheme) -> Color {
        let palette: (dark: UInt32, light: UInt32)
        switch self {
        case .zero: return theme.surface2
        case .lightBlue: palette = (0x4D7C97, 0x5289AC)
        case .blue: palette = (0x4C8DD8, 0x3476BE)
        case .cyan: palette = (0x2BA2B5, 0x00798F)
        case .green: palette = (0x45B68B, 0x087559)
        case .yellow: palette = (0xD0AD48, 0x866200)
        case .red: palette = (0xF4A5A0, 0xB82F39)
        }
        return Color(hex: theme == .light ? palette.light : palette.dark)
    }
}
