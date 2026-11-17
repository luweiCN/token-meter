import Foundation
import SwiftUI

/// 与全年活跃度共用资源中的固定阈值和颜色，月份与峰值不参与分档。
enum MonthHeatmapBand: Int, CaseIterable {
    case zero, lightBlue, blue, cyan, green, yellow, red

    var minimumTokens: Int64 {
        Self.definitions[rawValue].minimumTokens
    }

    static func band(for tokens: Int64) -> Self {
        allCases.last(where: { tokens >= $0.minimumTokens }) ?? .zero
    }

    var rangeLabel: String {
        guard self != .zero else { return "0 Token" }
        let lower = "\(minimumTokens / 100_000_000)亿"
        guard let next = Self(rawValue: rawValue + 1) else { return "\(lower)及以上 Token" }
        let upper = "\(next.minimumTokens / 100_000_000)亿"
        if self == .lightBlue { return "非零，不足\(upper) Token" }
        return "\(lower)至不足\(upper) Token"
    }

    func color(in theme: MBTheme) -> Color {
        let palette = Self.definitions[rawValue]
        return Color(hex: theme == .light ? palette.light : palette.dark)
    }

    private struct Definition: Decodable {
        let minimumTokens: Int64
        let dark: UInt32
        let light: UInt32

        private enum CodingKeys: String, CodingKey { case minimumTokens, dark, light }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            minimumTokens = try values.decode(Int64.self, forKey: .minimumTokens)
            func hex(_ key: CodingKeys) throws -> UInt32 {
                let text = try values.decode(String.self, forKey: key)
                guard text.count == 7, text.hasPrefix("#"), let value = UInt32(text.dropFirst(), radix: 16) else {
                    throw DecodingError.dataCorruptedError(forKey: key, in: values, debugDescription: "Expected #RRGGBB")
                }
                return value
            }
            dark = try hex(.dark)
            light = try hex(.light)
        }
    }

    private static let definitions: [Definition] = {
        guard let url = Bundle.module.url(forResource: "token-heatmap-bands", withExtension: "json") else {
            preconditionFailure("Missing bundled token heatmap configuration")
        }
        do {
            let values = try JSONDecoder().decode([Definition].self, from: Data(contentsOf: url))
            precondition(values.count == allCases.count && values[0].minimumTokens == 0 && values[1].minimumTokens == 1)
            precondition(zip(values, values.dropFirst()).allSatisfy { $0.0.minimumTokens < $0.1.minimumTokens })
            return values
        } catch {
            preconditionFailure("Invalid bundled token heatmap configuration: \(error)")
        }
    }()
}
