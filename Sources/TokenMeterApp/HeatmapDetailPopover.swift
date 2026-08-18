import AppKit
import SwiftUI

/// 热力图悬浮详情用的独立浮窗窗口（AppKit 无边框透明窗口 + SwiftUI 内容）。
///
/// 为什么要独立窗口：详情卡 300pt 宽，而热力图贴在弹窗面板右缘，面板内既放不下、
/// 也越不出面板边界。独立窗口可以跟随悬浮的格子（鼠标）定位、超出面板显示，
/// 圆角和箭头全部自绘，不受系统 popover 样式限制。
@MainActor
final class HeatmapDetailPopover {
    static let shared = HeatmapDetailPopover()

    private var window: NSWindow?
    private var hosting: NSHostingView<AnyView>?

    private init() {}

    func show<Content: View>(
        below screenPoint: NSPoint,
        @ViewBuilder content: () -> Content
    ) {
        let root = AnyView(content())
        if let hosting, let window {
            hosting.rootView = root
            window.contentView = hosting
            reposition(below: screenPoint)
            window.orderFront(nil)
            return
        }

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .popUpMenu
        window.contentView = hostingView
        self.hosting = hostingView
        self.window = window
        reposition(below: screenPoint)
        window.orderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
    }

    /// 浮窗水平居中于鼠标（箭头因此指向被悬浮的格子），垂直在鼠标下方 8pt；
    /// 超出屏幕时水平收边、下方放不下时翻到鼠标上方。
    private func reposition(below point: NSPoint) {
        guard let window else { return }
        let size = window.contentView?.fittingSize ?? window.frame.size
        var origin = NSPoint(x: point.x - size.width / 2, y: point.y - size.height - 8)

        // 多显示器：收边必须按鼠标所在的那块屏，不能用 NSScreen.main（否则三号屏
        // 上的浮窗会被夹回一号屏）。鼠标坐标与屏幕 frame 同为全局坐标（主屏左下原点）。
        let screen = NSScreen.screens.first { candidate in
            NSMouseInRect(point, candidate.frame, false)
        } ?? NSScreen.main
        if let screen {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            if origin.y < visible.minY {
                origin.y = point.y + 8
            }
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        }

        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}
