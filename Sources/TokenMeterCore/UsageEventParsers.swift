import Foundation

/// parser 是流式的：逐行 consume，最后 finish 出完整事件列表。
///
/// 要流式的是**行**，不是**事件**。本机最大的 Codex session 文件 3.28 GB /
/// 257,115 行，绝不能把 [JSONLLine] 全读进内存；但它只产出约 36k 个事件，
/// 累积成数组只有几 MB。
public protocol UsageEventParser: AnyObject {
    init(resuming state: ParserState?)
    func consume(_ line: JSONLLine)
    func finish(sourceURL: URL) throws -> (session: ParsedSession, state: ParserState)
}

public extension UsageEventParser {
    /// 测试便利方法，一次性喂完所有行。
    /// **生产路径不得使用**：必须走 JSONLStreamReader 的 onLine 回调。
    static func parse(
        lines: [JSONLLine],
        sourceURL: URL,
        resuming state: ParserState? = nil
    ) throws -> (session: ParsedSession, state: ParserState) {
        let parser = Self(resuming: state)
        for line in lines { parser.consume(line) }
        return try parser.finish(sourceURL: sourceURL)
    }
}
