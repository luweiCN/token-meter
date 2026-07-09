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

    /// Array-returning overload. Test-only: it materializes every surfaced line in memory,
    /// which defeats the purpose of streaming for large files (e.g. Codex's 257k-line, 3+ GB
    /// sessions). Production call sites should use the `onLine` callback overload instead.
    public static func readLines(from url: URL, startingAt offset: Int64, markers: [String]? = nil) throws -> JSONLReadResult {
        try readLines(from: url, startingAt: offset, chunkSize: 256 * 1024, markers: markers)
    }

    /// Streaming overload used by production scanners.
    ///
    /// `markers`, when non-nil, restricts surfaced lines to those whose raw bytes contain at
    /// least one marker byte-string. The check runs against the assembled line's raw `Data`
    /// before any `String(decoding:)` or JSON parsing, so lines that don't match never pay
    /// those costs.
    ///
    /// Only Codex passes markers: its 3+ GB sessions are dominated by `function_call` /
    /// `function_call_output` lines that carry none of `token_count`, `session_meta`, or
    /// `turn_context`, so prefiltering on raw bytes skips the vast majority of lines cheaply.
    /// Claude and omp always pass `nil` — their `sessionId`, `cwd`, and `version` fields are
    /// spread across many different line types, so byte-filtering by a fixed marker set would
    /// silently drop metadata those parsers need.
    public static func readLines(
        from url: URL,
        startingAt offset: Int64,
        markers: [String]? = nil,
        onLine: @escaping (JSONLLine) throws -> Void
    ) throws -> JSONLReadResult {
        try readLines(from: url, startingAt: offset, chunkSize: 256 * 1024, retainingLines: false, markers: markers, onLine: onLine)
    }

    static func readLines(from url: URL, startingAt offset: Int64, chunkSize: Int, markers: [String]? = nil) throws -> JSONLReadResult {
        try readLines(from: url, startingAt: offset, chunkSize: chunkSize, retainingLines: true, markers: markers, onLine: nil)
    }

    static func readLines(
        from url: URL,
        startingAt offset: Int64,
        chunkSize: Int,
        markers: [String]? = nil,
        onLine: @escaping (JSONLLine) throws -> Void
    ) throws -> JSONLReadResult {
        try readLines(from: url, startingAt: offset, chunkSize: chunkSize, retainingLines: false, markers: markers, onLine: onLine)
    }

    private static func readLines(
        from url: URL,
        startingAt offset: Int64,
        chunkSize: Int,
        retainingLines: Bool,
        markers: [String]?,
        onLine: ((JSONLLine) throws -> Void)?
    ) throws -> JSONLReadResult {
        precondition(offset >= 0, "JSONL offset must be non-negative")
        precondition(chunkSize > 0, "JSONL chunk size must be positive")

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))

        let markerBytes = markers?.map { Data($0.utf8) }

        var lines: [JSONLLine] = []
        var currentLine = Data()
        var currentLineOffset = offset

        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            var searchStart = chunk.startIndex
            while searchStart < chunk.endIndex {
                if let newlineIndex = chunk[searchStart...].firstIndex(of: newlineByte) {
                    currentLine.append(chunk[searchStart..<newlineIndex])
                    // currentLine now holds the whole line's bytes (it may have been assembled
                    // across several chunks), so its count is the true line length regardless
                    // of where in this chunk the terminating newline landed.
                    let nextOffset = currentLineOffset + Int64(currentLine.count) + 1

                    if !currentLine.isEmpty, markerBytes.map({ containsAnyMarker(currentLine, markerBytes: $0) }) ?? true {
                        let line = JSONLLine(
                            text: String(decoding: currentLine, as: UTF8.self),
                            offset: currentLineOffset,
                            nextOffset: nextOffset
                        )
                        if retainingLines {
                            lines.append(line)
                        } else {
                            try onLine?(line)
                        }
                    }

                    currentLine.removeAll(keepingCapacity: true)
                    currentLineOffset = nextOffset
                    searchStart = chunk.index(after: newlineIndex)
                } else {
                    currentLine.append(chunk[searchStart...])
                    searchStart = chunk.endIndex
                }
            }
        }

        let residual = currentLine.isEmpty ? nil : String(decoding: currentLine, as: UTF8.self)
        return JSONLReadResult(
            lines: lines,
            nextOffset: currentLineOffset,
            residual: residual
        )
    }

    private static func containsAnyMarker(_ line: Data, markerBytes: [Data]) -> Bool {
        markerBytes.contains { marker in
            !marker.isEmpty && line.range(of: marker) != nil
        }
    }
}
