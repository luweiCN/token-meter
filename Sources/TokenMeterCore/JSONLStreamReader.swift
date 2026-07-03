import Foundation

public struct JSONLLine: Equatable {
    public let text: String
    public let offset: Int64
    public let nextOffset: Int64

    public init(text: String, offset: Int64, nextOffset: Int64) {
        self.text = text
        self.offset = offset
        self.nextOffset = nextOffset
    }
}

public struct JSONLReadResult: Equatable {
    public let lines: [JSONLLine]
    public let nextOffset: Int64
    public let residual: String?

    public init(lines: [JSONLLine], nextOffset: Int64, residual: String?) {
        self.lines = lines
        self.nextOffset = nextOffset
        self.residual = residual
    }
}

public enum JSONLStreamReader {
    private static let newlineByte = UInt8(ascii: "\n")

    public static func readLines(from url: URL, startingAt offset: Int64) throws -> JSONLReadResult {
        try readLines(from: url, startingAt: offset, chunkSize: 64 * 1024)
    }

    static func readLines(from url: URL, startingAt offset: Int64, chunkSize: Int) throws -> JSONLReadResult {
        precondition(offset >= 0, "JSONL offset must be non-negative")
        precondition(chunkSize > 0, "JSONL chunk size must be positive")

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))

        var lines: [JSONLLine] = []
        var currentLine = Data()
        var currentLineOffset = offset
        var cursor = offset

        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            for byte in chunk {
                if byte == newlineByte {
                    let nextOffset = cursor + 1
                    if !currentLine.isEmpty {
                        lines.append(
                            JSONLLine(
                                text: String(decoding: currentLine, as: UTF8.self),
                                offset: currentLineOffset,
                                nextOffset: nextOffset
                            )
                        )
                    }
                    currentLine.removeAll(keepingCapacity: true)
                    currentLineOffset = nextOffset
                } else {
                    currentLine.append(byte)
                }
                cursor += 1
            }
        }

        let residual = currentLine.isEmpty ? nil : String(decoding: currentLine, as: UTF8.self)
        return JSONLReadResult(
            lines: lines,
            nextOffset: currentLineOffset,
            residual: residual
        )
    }
}
