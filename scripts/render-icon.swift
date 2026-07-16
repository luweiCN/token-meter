// 应用图标渲染：CoreGraphics 直绘 1024×1024 PNG（四角真透明）。
// 不走 qlmanage——QuickLook 渲染 SVG 会把透明区填成白色（踩过）。
//   swift scripts/render-icon.swift <输出.png>
import AppKit

let size = 1024
let corner: CGFloat = 229   // macOS 图标标准圆角比例 ~22.4%

guard CommandLine.arguments.count >= 2 else {
    fputs("用法: swift render-icon.swift <输出.png>\n", stderr)
    exit(1)
}
let outputPath = CommandLine.arguments[1]

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
    data: nil, width: size, height: size,
    bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

// SVG 坐标（原点左上）→ CG（原点左下）：翻转 y。
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

// 底板：满幅圆角矩形 + 纵向渐变（#03202f → #00111e）。
let plate = CGPath(
    roundedRect: CGRect(x: 0, y: 0, width: size, height: size),
    cornerWidth: corner, cornerHeight: corner, transform: nil
)
ctx.addPath(plate)
ctx.clip()
let gradient = CGGradient(
    colorsSpace: space,
    colors: [rgb(0x03202F), rgb(0x00111E)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size), options: [])

// 品牌 logo（设计稿 brand 22×22）：translate(228,228) scale(25.8)，描边 1.6。
let s: CGFloat = 25.8
let o: CGFloat = 228
func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o + x * s, y: o + y * s) }

ctx.setStrokeColor(rgb(0x0FC5ED))
ctx.setLineWidth(1.6 * s)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

let frame = CGPath(
    roundedRect: CGRect(x: o + 1 * s, y: o + 1 * s, width: 20 * s, height: 20 * s),
    cornerWidth: 5 * s, cornerHeight: 5 * s, transform: nil
)
ctx.addPath(frame)
ctx.strokePath()

ctx.move(to: pt(6, 13.5))
ctx.addLine(to: pt(9, 8.5))
ctx.addLine(to: pt(11.6, 12.1))
ctx.addLine(to: pt(14, 6.5))
ctx.addLine(to: pt(16, 13.5))
ctx.strokePath()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
let png = rep.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: outputPath))

// 自检：四角必须真透明（qlmanage 之坑的回归防线）。
let probe = NSBitmapImageRep(cgImage: image)
let cornerAlpha = probe.colorAt(x: 2, y: 2)?.alphaComponent ?? -1
print("corner alpha: \(cornerAlpha) (期望 0)")
