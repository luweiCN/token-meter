import Foundation

/// parser 是流式的：逐行 consume，最后 finish 出完整事件列表。
///
/// 要流式的是**行**，不是**事件**。本机最大的 Codex session 文件 3.28 GB /
/// 257,115 行，绝不能把 [JSONLLine] 全读进内存；但它只产出约 36k 个事件，
/// 累积成数组只有几 MB。
public protocol UsageEventParser: AnyObject {
    init(resuming state: ParserState?)
    func consume(_ line: JSONLLine)
    /// `session == nil` 表示"这个文件不是一个会话文件"（例如 Claude 的辅助文件：无 sessionId、
    /// 也从未见过挂在 message 下的 usage 对象）。这与"是会话但零事件"（session 非 nil、events 为空，
    /// 如 Codex 无 token_count 的文件）是两回事：前者无 sessionKey 可言，无法构造 ParsedSession。
    /// 真正坏掉的会话文件（有 usage 却缺 sessionId）仍然抛 `missingSessionKey`，绝不静默返回 nil。
    func finish(sourceURL: URL) throws -> (session: ParsedSession?, state: ParserState)
}

public extension UsageEventParser {
    /// 测试便利方法，一次性喂完所有行。
    /// **生产路径不得使用**：必须走 JSONLStreamReader 的 onLine 回调。
    ///
    /// 便利方法只服务于"这些行构成一个会话"的用例，因此把 `finish` 的可选 session 解包成非可选；
    /// 若 parser 判定不是会话（返回 nil），按缺 session key 抛错，与旧行为一致。
    static func parse(
        lines: [JSONLLine],
        sourceURL: URL,
        resuming state: ParserState? = nil
    ) throws -> (session: ParsedSession, state: ParserState) {
        let parser = Self(resuming: state)
        for line in lines { parser.consume(line) }
        let result = try parser.finish(sourceURL: sourceURL)
        guard let session = result.session else { throw LocalAgentParserError.missingSessionKey }
        return (session, result.state)
    }
}
