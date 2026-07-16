import Foundation

public enum ModelNameNormalizer {
    public static let unknown = "unknown"

    /// OmniRoute 为不支持切换思考档位的 agent 在网关层建的档位别名（gpt-5.5-xhigh 等）。
    /// 计价上就是基础模型：档位只改推理 token 用量，不改单价。
    /// 只收数据里实际见过的档位后缀。-medium/-low 刻意不收：
    /// mistral-medium、whisper-medium 的 medium 是尺寸不是档位，剥了就错了。
    private static let effortSuffixes = ["-xhigh", "-high"]

    public static func canonical(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return unknown }

        var name = raw.lowercased()

        // 供应商/渠道/网关标记（anthropic/、codex/、omniroute/cx/ 等，可叠加）
        // 一律不属于模型身份：取 `/` 分隔的最后一段作为模型代号（用户裁定，
        // 取代早先的前缀白名单）。定价键侧（transform_pricing.py）仍用白名单——
        // 那边要防第三方托管价（cloudflare/ 等）冒充官方价，职责不同。
        if let lastSlash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: lastSlash)...])
        }

        // 只剥离 -YYYYMMDD 形式的日期后缀。
        // 不能写成 -\d+$：那会把 glm-4.6 和 claude-opus-4-8 也切掉。
        if let range = name.range(of: "-[0-9]{8}$", options: .regularExpression) {
            name.removeSubrange(range)
        }

        for suffix in effortSuffixes where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
            break
        }

        return name.isEmpty ? unknown : name
    }
}
