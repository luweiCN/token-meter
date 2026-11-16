import AppKit
import SwiftUI
import XCTest
@testable import TokenMeterApp

@MainActor
final class MonthHeatmapBandTests: XCTestCase {
    func testFixedTokenIntervalsIncludeTheirLowerBoundary() {
        let cases: [(Int64, MonthHeatmapBand)] = [
            (-1, .zero), (0, .zero), (1, .lightBlue), (99_999_999, .lightBlue),
            (100_000_000, .blue), (299_999_999, .blue),
            (300_000_000, .cyan), (599_999_999, .cyan),
            (600_000_000, .green), (999_999_999, .green),
            (1_000_000_000, .yellow), (1_999_999_999, .yellow),
            (2_000_000_000, .red), (4_000_000_000, .red), (.max, .red),
        ]
        for (tokens, expected) in cases {
            XCTAssertEqual(MonthHeatmapBand.band(for: tokens), expected, "\(tokens) Token")
        }
    }

    func testOrdinaryDaysStayVisibleAlongsideAnExtremePeak() {
        let values: [Int64] = [0, 300_000_000, 700_000_000, 800_000_000, 4_000_000_000]
        XCTAssertEqual(values.map(MonthHeatmapBand.band(for:)), [.zero, .cyan, .green, .green, .red])
    }

    func testRangeLabelsUseTheSameBoundariesAsClassification() {
        XCTAssertEqual(MonthHeatmapBand.allCases.count, 7)
        XCTAssertEqual(MonthHeatmapBand.lightBlue.rangeLabel, "非零，不足1亿 Token")
        XCTAssertEqual(MonthHeatmapBand.green.rangeLabel, "6亿至不足10亿 Token")
        XCTAssertEqual(MonthHeatmapBand.yellow.rangeLabel, "10亿至不足20亿 Token")
        XCTAssertEqual(MonthHeatmapBand.red.rangeLabel, "20亿及以上 Token")
        for band in MonthHeatmapBand.allCases {
            XCTAssertEqual(MonthHeatmapBand.band(for: band.minimumTokens), band)
        }
    }

    func testEveryPositiveBandContrastsWithZeroAndThePanelInBothThemes() throws {
        for theme in [MBTheme.dark, .light] {
            for band in MonthHeatmapBand.allCases where band != .zero {
                for background in [theme.surface2, theme.surface, theme.bg] {
                    let foreground = try luminance(band.color(in: theme), over: background)
                    let backdrop = try luminance(background)
                    let contrast = (max(foreground, backdrop) + 0.05) / (min(foreground, backdrop) + 0.05)
                    XCTAssertGreaterThanOrEqual(contrast, 3, "\(band) 必须与零用量和面板背景清楚区分")
                }
            }
        }
    }

    private func luminance(_ color: Color, over background: Color? = nil) throws -> Double {
        let rgb = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
        let backdrop = try background.map { try XCTUnwrap(NSColor($0).usingColorSpace(.sRGB)) }
        let alpha = rgb.alphaComponent
        func linear(_ component: CGFloat) -> Double {
            let value = Double(component)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent * alpha + (backdrop?.redComponent ?? 0) * (1 - alpha))
            + 0.7152 * linear(rgb.greenComponent * alpha + (backdrop?.greenComponent ?? 0) * (1 - alpha))
            + 0.0722 * linear(rgb.blueComponent * alpha + (backdrop?.blueComponent ?? 0) * (1 - alpha))
    }
}
