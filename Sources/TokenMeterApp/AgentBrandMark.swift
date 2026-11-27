import AppKit
import SwiftUI

/// T3 Code 各 Agent 自己的产品标。填色分亮暗两套，不跟菜单栏系列色走。
/// 没有对应标的 Agent 用圆点。
enum AgentBrandIcon: Equatable {
    struct Mark: Equatable {
        var viewBox: CGRect
        var paths: [SVGMarkPath]
    }

    case vector(Mark)
    case antigravity
    case openClaw

    static func icon(for providerId: String) -> AgentBrandIcon? {
        switch providerId {
        case "claude-code":
            return .vector(Mark(viewBox: CGRect(x: 0, y: 0, width: 256, height: 257), paths: [
                SVGMarkPath(d: claudeBrandPath, fillLight: 0xD97757, fillDark: 0xD97757, evenOdd: false),
            ]))
        case "codex":
            return .vector(Mark(viewBox: CGRect(x: 100, y: 100, width: 411, height: 411), paths: [
                SVGMarkPath(d: openAIBrandPath, fillLight: 0x000000, fillDark: 0xFFFFFF, evenOdd: true),
            ]))
        case "opencode":
            return .vector(Mark(viewBox: CGRect(x: 0, y: 0, width: 32, height: 40), paths: [
                SVGMarkPath(d: openCodeDetailPath, fillLight: 0xCFCECD, fillDark: 0x4B4646, evenOdd: false),
                SVGMarkPath(d: openCodeFramePath, fillLight: 0x211E1E, fillDark: 0xF1ECEC, evenOdd: false),
            ]))
        case "grok":
            return .vector(Mark(viewBox: CGRect(x: 0, y: 0, width: 24, height: 24), paths: [
                SVGMarkPath(d: grokBrandPathA, fillLight: 0x0F0F0F, fillDark: 0xF5F5F5, evenOdd: false),
                SVGMarkPath(d: grokBrandPathB, fillLight: 0x0F0F0F, fillDark: 0xF5F5F5, evenOdd: false),
            ]))
        case "antigravity-cli":
            return .antigravity
        case "openclaw":
            return .openClaw
        default:
            return nil
        }
    }

    /// Icons.tsx 里 AntigravityIcon 内嵌的拱形标。
    static let antigravityPNG = Data(base64Encoded: antigravityBrandPNGBase64) ?? Data()
    /// mcp/logos/openclaw.png。原图是白底，而且图形只占画布约六成；
    /// 放进和其他标一样的 14pt 格子会显得小。去掉衬底后裁到图形边缘。
    static let openClawPNG = Data(base64Encoded: openClawBrandPNGBase64) ?? Data()
}

struct SVGMarkPath: Equatable {
    var d: String
    var fillLight: UInt32
    var fillDark: UInt32
    var evenOdd: Bool
}

enum SVGPathParser {
    /// SVG path 的 M/L/H/V/C/Z（含相对写法）。这些产品标没有圆弧和二次曲线。
    static func path(from d: String) -> Path {
        var path = Path()
        let chars = Array(d)
        var index = 0
        var cx: CGFloat = 0
        var cy: CGFloat = 0
        var startX: CGFloat = 0
        var startY: CGFloat = 0
        var command: Character = " "

        func peek() -> Character? {
            index < chars.count ? chars[index] : nil
        }

        func skipSeparators() {
            while let char = peek(), char == "," || char.isWhitespace {
                index += 1
            }
        }

        func readNumber() -> CGFloat? {
            skipSeparators()
            let start = index
            guard index < chars.count else { return nil }
            if chars[index] == "+" || chars[index] == "-" { index += 1 }
            var sawDigit = false
            var sawDot = false
            var sawExponent = false
            while index < chars.count {
                let char = chars[index]
                if char.isNumber {
                    sawDigit = true
                    index += 1
                } else if char == "." && !sawDot && !sawExponent {
                    sawDot = true
                    index += 1
                } else if (char == "e" || char == "E"), sawDigit, !sawExponent {
                    sawExponent = true
                    index += 1
                    if index < chars.count, chars[index] == "+" || chars[index] == "-" {
                        index += 1
                    }
                } else {
                    break
                }
            }
            guard sawDigit, let value = Double(String(chars[start..<index])) else {
                index = start
                return nil
            }
            return CGFloat(value)
        }

        while index < chars.count {
            skipSeparators()
            guard index < chars.count else { break }
            if chars[index].isLetter {
                command = chars[index]
                index += 1
            } else if command == " " {
                break
            }

            switch command {
            case "Z", "z":
                path.closeSubpath()
                cx = startX
                cy = startY
                command = " "
            case "M", "m":
                let relative = command == "m"
                guard let rawX = readNumber(), let rawY = readNumber() else { return path }
                let x = relative ? cx + rawX : rawX
                let y = relative ? cy + rawY : rawY
                path.move(to: CGPoint(x: x, y: y))
                cx = x
                cy = y
                startX = x
                startY = y
                // 第一对坐标之后，多出来的数对是隐式 lineto。
                command = relative ? "l" : "L"
            case "L", "l":
                let relative = command == "l"
                guard let rawX = readNumber(), let rawY = readNumber() else { return path }
                let x = relative ? cx + rawX : rawX
                let y = relative ? cy + rawY : rawY
                path.addLine(to: CGPoint(x: x, y: y))
                cx = x
                cy = y
            case "H", "h":
                guard let raw = readNumber() else { return path }
                cx = command == "h" ? cx + raw : raw
                path.addLine(to: CGPoint(x: cx, y: cy))
            case "V", "v":
                guard let raw = readNumber() else { return path }
                cy = command == "v" ? cy + raw : raw
                path.addLine(to: CGPoint(x: cx, y: cy))
            case "C", "c":
                let relative = command == "c"
                guard let a = readNumber(), let b = readNumber(),
                      let c1 = readNumber(), let d1 = readNumber(),
                      let e = readNumber(), let f = readNumber() else { return path }
                let x1 = relative ? cx + a : a
                let y1 = relative ? cy + b : b
                let x2 = relative ? cx + c1 : c1
                let y2 = relative ? cy + d1 : d1
                let x = relative ? cx + e : e
                let y = relative ? cy + f : f
                path.addCurve(
                    to: CGPoint(x: x, y: y),
                    control1: CGPoint(x: x1, y: y1),
                    control2: CGPoint(x: x2, y: y2)
                )
                cx = x
                cy = y
            default:
                return path
            }
        }
        return path
    }
}

struct AgentBrandMark: View {
    let providerId: String
    @Environment(\.mbTheme) private var theme

    var body: some View {
        mark
            .frame(width: 14, height: 14)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var mark: some View {
        switch AgentBrandIcon.icon(for: providerId) {
        case .vector(let mark):
            VectorBrandMark(mark: mark, dark: theme != .light)
        case .antigravity:
            raster(AgentBrandIcon.antigravityPNG)
        case .openClaw:
            raster(AgentBrandIcon.openClawPNG)
        case nil:
            Text(verbatim: "•")
                .font(.system(size: 12))
                .foregroundStyle(theme.muted)
        }
    }

    @ViewBuilder private func raster(_ data: Data) -> some View {
        if let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
        }
    }
}

private struct VectorBrandMark: View {
    let mark: AgentBrandIcon.Mark
    let dark: Bool

    var body: some View {
        Canvas { context, size in
            let box = mark.viewBox
            let scale = min(size.width / box.width, size.height / box.height)
            let dx = (size.width - box.width * scale) / 2
            let dy = (size.height - box.height * scale) / 2
            let transform = CGAffineTransform(
                a: scale, b: 0, c: 0, d: scale,
                tx: dx - box.minX * scale,
                ty: dy - box.minY * scale
            )
            for item in mark.paths {
                let parsed = SVGPathParser.path(from: item.d).applying(transform)
                let hex = dark ? item.fillDark : item.fillLight
                context.fill(
                    parsed,
                    with: .color(Color(hex: hex)),
                    style: FillStyle(eoFill: item.evenOdd)
                )
            }
        }
    }
}
