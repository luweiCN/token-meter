import Foundation

public enum ModelNameNormalizer {
    public static let unknown = "unknown"

    private static let providerPrefixes = [
        "vertex_ai/",
        "bedrock/",
        "anthropic/",
        "openai/",
        "openai-codex/",
        "zai/",         // LiteLLM 用 zai/glm-4.6 作 key，OpenCode 上报的是裸 glm-4.6
        "deepseek/",
        "gemini/",
        // OmniRoute 网关按接入渠道加的路由前缀，不属于模型身份，剥掉后按裸模型名计价。
        // 只出现在本地会话日志侧，LiteLLM 键里没有这些前缀。前缀可叠加：OMP 里配置的
        // 模型名是「网关名/渠道/模型」两层（omniroute/cx/gpt-5.5），靠 canonical 的循环剥离处理。
        "omniroute/",
        "9router/",     // OmniRoute 在 OMP 里的另一个拼写
        "cx/",
        "opencode-go/",
        "ocg/",
        "glm-cn/",
        "glm/",
        "antigravity/",
        "google-antigravity/",
        "zhipu-coding-plan/"
    ]

    /// OmniRoute 为不支持切换思考档位的 agent 在网关层建的档位别名（gpt-5.5-xhigh 等）。
    /// 计价上就是基础模型：档位只改推理 token 用量，不改单价。
    /// 只收数据里实际见过的档位后缀。-medium/-low 刻意不收：
    /// mistral-medium、whisper-medium 的 medium 是尺寸不是档位，剥了就错了。
    private static let effortSuffixes = ["-xhigh", "-high"]

    public static func canonical(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return unknown }

        var name = raw.lowercased()

        // 循环剥离：网关前缀会叠加（omniroute/cx/gpt-5.5）。每轮要么剥掉一个
        // 非空前缀让名字变短，要么退出，必然终止。
        var stripped = true
        while stripped {
            stripped = false
            for prefix in providerPrefixes where name.hasPrefix(prefix) {
                name.removeFirst(prefix.count)
                stripped = true
                break
            }
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
