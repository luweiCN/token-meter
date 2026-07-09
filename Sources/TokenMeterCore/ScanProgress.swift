import Foundation

/// 全量重扫的进度快照。按字节度量，不按文件数：本机最大的单个 session 文件是 GB 级，
/// 多数文件只有几十 KB，按 filesDone/filesTotal 画进度会先冲到 90% 再卡在几个大文件上。
public struct ScanProgressEvent: Equatable, Codable {
    public let filesTotal: Int
    public let filesDone: Int
    public let bytesTotal: Int64
    public let bytesDone: Int64
    public let currentRoot: String

    public init(filesTotal: Int, filesDone: Int, bytesTotal: Int64, bytesDone: Int64, currentRoot: String) {
        self.filesTotal = filesTotal
        self.filesDone = filesDone
        self.bytesTotal = bytesTotal
        self.bytesDone = bytesDone
        self.currentRoot = currentRoot
    }
}

/// 按字节进度每跨越 0.5% 放行一条事件，外加末尾一条。
///
/// 刻意不看时钟：时钟会让测试需要注入 `Date` 供给器，而这里唯一要保证的是
/// 「事件条数有界」和「最后一条一定发出」。两者都只跟字节数有关。0.5% 一档、共 200 档，
/// 因此十万级调用最多放行约 201 条，5,000+ 文件也不会刷屏。
public struct ScanProgressThrottle {
    private static let stepPercent = 0.5
    private var lastEmittedBucket = -1

    public init() {}

    public mutating func shouldEmit(bytesDone: Int64, bytesTotal: Int64, isFinal: Bool) -> Bool {
        if isFinal { return true }
        guard bytesTotal > 0 else { return false }
        let percent = Double(bytesDone) / Double(bytesTotal) * 100
        let bucket = Int(percent / Self.stepPercent)
        guard bucket > lastEmittedBucket else { return false }
        lastEmittedBucket = bucket
        return true
    }
}
