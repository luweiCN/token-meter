import Foundation

public enum ProviderSnapshotDiskCache {
    public static func read(from url: URL) throws -> [ProviderUsageSnapshot] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let field = try decoder.singleValueContainer()
            let text = try field.decode(String.self)
            for fractional in [false, true] {
                if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: fractional).parse(text) {
                    return date
                }
            }
            throw DecodingError.dataCorruptedError(in: field, debugDescription: "Expected an RFC 3339 timestamp")
        }
        return try decoder.decode([ProviderUsageSnapshot].self, from: Data(contentsOf: url))
    }
}
