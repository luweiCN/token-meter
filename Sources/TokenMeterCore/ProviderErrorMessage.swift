public enum ProviderErrorMessage {
    public static func sanitized(providerName: String, errorMessage: String) -> String {
        let lowercased = errorMessage.lowercased()
        if lowercased.contains("node -e")
            || lowercased.contains("child_process")
            || lowercased.contains("codex app-server")
            || lowercased.contains("命令退出")
            || lowercased.contains("command failed") {
            return "\(providerName) 暂时无法读取额度"
        }

        return errorMessage
    }
}
