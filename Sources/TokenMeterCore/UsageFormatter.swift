import Foundation

public enum UsageFormatter {
    /// token 数缩写（775 / 3.4K / 512.4M / 2398.5M），菜单栏标题与弹窗大数字共用。
    /// 这两处显示的都是【今日】用量——单日数字永远停在 M 单位：升到 1 位小数的 B
    /// 会把百万级变化吞掉，十亿级也就四位数 M，完全排得下。
    public static func compactTokens(_ value: Int64) -> String {
        let v = Double(value)
        if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%.1fK", v / 1_000) }
        return String(Int(v))
    }

    /// 多天聚合口径（总计/本月/本周卡片，与主界面 formatTokens 非单日分支一致）：
    /// ≥10 亿用 B（两位小数），百万级保留两位小数——总 token 上百亿时不再挂一大串 M。
    public static func compactTokensAggregated(_ value: Int64) -> String {
        let v = Double(value)
        if v >= 1_000_000_000_000 { return String(format: "%.2fT", v / 1_000_000_000_000) }
        if v >= 1_000_000_000 { return String(format: "%.2fB", v / 1_000_000_000) }
        if v >= 1_000_000 { return String(format: "%.2fM", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%.2fK", v / 1_000) }
        return String(Int(v))
    }

    public static func numberText(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }

        return String(format: "%.1f", value)
    }
}
