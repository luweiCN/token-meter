import Foundation

public enum ModelNameNormalizer {
    public static let unknown = "unknown"

    private static let providerPrefixes = [
        "vertex_ai/",
        "bedrock/",
        "anthropic/",
        "openai/",
        "openai-codex/",
        "zai/"          // LiteLLM 用 zai/glm-4.6 作 key，OpenCode 上报的是裸 glm-4.6
    ]

    public static func canonical(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return unknown }

        var name = raw.lowercased()

        for prefix in providerPrefixes where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
            break
        }

        // 只剥离 -YYYYMMDD 形式的日期后缀。
        // 不能写成 -\d+$：那会把 glm-4.6 和 claude-opus-4-8 也切掉。
        if let range = name.range(of: "-[0-9]{8}$", options: .regularExpression) {
            name.removeSubrange(range)
        }

        return name.isEmpty ? unknown : name
    }
}
