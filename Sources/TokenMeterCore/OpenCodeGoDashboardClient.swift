import AppKit
import Foundation
import WebKit

/// OpenCode Go 控制台用量窗口（DOM 读取结果）。
public struct OpenCodeGoUsageWindowData: Equatable {
    public let label: String
    public let usagePercent: Double

    public init(label: String, usagePercent: Double) {
        self.label = label
        self.usagePercent = usagePercent
    }
}

/// 把控制台 DOM 里的 usage-item 行解析为窗口数据（纯函数，可测）。
/// 标签是 i18n 文案，中英文都出现过（页面语言跟随系统）：
/// Rolling Usage / Weekly Usage / Monthly Usage 与 滚动用量 / 每周用量 / 每月用量。
public enum OpenCodeGoDashboardParser {
    public static func parse(items: [(label: String, value: String)]) -> [OpenCodeGoUsageWindowData] {
        var windows: [OpenCodeGoUsageWindowData] = []
        for item in items {
            let label = item.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let percent = Double(value.replacingOccurrences(of: "%", with: "")) else {
                continue
            }
            let windowLabel: String
            if label.contains("rolling") || label.contains("滚动") {
                windowLabel = "5h"
            } else if label.contains("weekly") || label.contains("每周") {
                windowLabel = "Weekly"
            } else if label.contains("monthly") || label.contains("每月") {
                windowLabel = "Monthly"
            } else {
                continue
            }
            windows.append(OpenCodeGoUsageWindowData(label: windowLabel, usagePercent: percent))
        }
        return windows
    }
}

/// 用隐藏 WKWebView 抓取 OpenCode Go 控制台用量。
///
/// 控制台是 SolidStart 应用：用量数据由 server action 在客户端 hydrate 后
/// 拉取并渲染进 DOM，静态 HTML 里只有 pending 占位（{p:0,s:0,f:0}），
/// 直接 HTTP 刮取永远拿不到数字。这里注入登录 cookie 加载 dashboard 页，
/// 等 hydrate 完成后执行 JS 读取渲染出的 usage-item 行。
///
/// WKWebView 必须只在主线程创建与操作（AppKit 约束），本类 @MainActor。
@MainActor
public final class OpenCodeGoDashboardClient: NSObject {
    public static let shared = OpenCodeGoDashboardClient()

    private let webView: WKWebView
    private let hostWindow: NSWindow
    private var loadContinuation: CheckedContinuation<Bool, Never>?
    private var inFlightTask: Task<[OpenCodeGoUsageWindowData], Error>?

    private override init() {
        let configuration = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: configuration)

        // WKWebView 完全不可见（屏幕外 / 全透明 / 尺寸过小）会被 WebKit 判定为
        // occlusion 而暂停页面渲染，hydrate 的 JS 不会执行。用主屏右下角一个小窗
        // 兜住：忽略鼠标、无边框、不抢焦点，只占 200×260 像素。
        let hostRect = NSScreen.main.map { screen -> NSRect in
            let visible = screen.visibleFrame
            return NSRect(x: visible.maxX - 200, y: visible.minY, width: 200, height: 260)
        } ?? NSRect(x: 0, y: 0, width: 200, height: 260)
        hostWindow = NSWindow(
            contentRect: hostRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        hostWindow.level = .statusBar
        hostWindow.isOpaque = false
        hostWindow.backgroundColor = .clear
        hostWindow.ignoresMouseEvents = true
        hostWindow.alphaValue = 0.02
        hostWindow.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
        hostWindow.contentView = webView
        hostWindow.orderFront(nil)

        super.init()
        webView.navigationDelegate = self
    }

    public enum FetchError: LocalizedError {
        case loadTimeout
        case dataTimeout
        case missingUsageItems
        case invalidCredential

        public var errorDescription: String? {
            switch self {
            case .loadTimeout:
                return "OpenCode Go 页面加载超时"
            case .dataTimeout:
                return "OpenCode Go 用量数据加载超时"
            case .missingUsageItems:
                return "没有从 OpenCode Go dashboard 解析到 rolling/weekly/monthly usage"
            case .invalidCredential:
                return "OpenCode Go 登录态无效"
            }
        }
    }

    /// 单飞：并发刷新（定时器 + IPC 双入口）共享同一个进行中的抓取任务。
    public func fetchUsage(workspaceId: String, authCookie: String) async throws -> [OpenCodeGoUsageWindowData] {
        if let inFlightTask {
            return try await inFlightTask.value
        }

        let task = Task { try await performFetch(workspaceId: workspaceId, authCookie: authCookie) }
        inFlightTask = task
        defer { inFlightTask = nil }
        return try await task.value
    }

    private func performFetch(workspaceId: String, authCookie: String) async throws -> [OpenCodeGoUsageWindowData] {
        // 每次刷新重新注入 cookie（Electron 登录流程可能刚写过新值）。
        let cookie = HTTPCookie(properties: [
            .domain: "opencode.ai",
            .path: "/",
            .name: "auth",
            .value: authCookie,
            .expires: Date().addingTimeInterval(365 * 24 * 60 * 60),
            .secure: true
        ])
        if let cookie {
            await webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        }

        let url = URL(string: "https://opencode.ai/workspace/\(workspaceId)/go")!
        webView.load(URLRequest(url: url))

        let finished = await withCheckedContinuation { continuation in
            loadContinuation = continuation
        }
        guard finished else {
            throw FetchError.loadTimeout
        }

        // 页面 hydrate 后用量数据才会渲染：轮询 DOM 直到读到或超时。
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let items = await readUsageItems()
            if !items.isEmpty {
                let windows = OpenCodeGoDashboardParser.parse(items: items)
                if windows.isEmpty {
                    throw FetchError.missingUsageItems
                }
                return windows
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw FetchError.dataTimeout
    }

    /// 读取渲染后的 usage-item 行（label/value），未渲染时返回空数组。
    private func readUsageItems() async -> [(label: String, value: String)] {        let script = """
        JSON.stringify([...document.querySelectorAll('[data-slot="usage-item"]')].map(el => ({
          label: (el.querySelector('[data-slot="usage-label"]')?.textContent || '').trim(),
          value: (el.querySelector('[data-slot="usage-value"]')?.textContent || '').trim()
        })))
        """

        let value: Any?
        do {
            value = try await webView.evaluateJavaScript(script)
        } catch {
            return []
        }

        guard let json = value as? String,
              let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return array.compactMap { object in
            guard let label = object["label"] as? String,
                  let value = object["value"] as? String else {
                return nil
            }
            return (label, value)
        }
    }
}

extension OpenCodeGoDashboardClient: WKNavigationDelegate {
    public nonisolated func webView(
        _ webView: WKWebView,
        didFinish navigation: WKNavigation!
    ) {
        Task { @MainActor in
            loadContinuation?.resume(returning: true)
            loadContinuation = nil
        }
    }

    public nonisolated func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor in
            loadContinuation?.resume(returning: false)
            loadContinuation = nil
        }
    }

    public nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor in
            loadContinuation?.resume(returning: false)
            loadContinuation = nil
        }
    }
}
