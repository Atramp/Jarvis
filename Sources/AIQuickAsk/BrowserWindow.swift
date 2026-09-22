import AppKit
import SwiftUI
import WebKit

// MARK: - 浏览器状态

/// 内嵌浏览器的 UI 状态（工具栏按钮可用性 / 加载进度）。
/// 单例复用：webview 每次激活都是全新实例（关闭即销毁），状态对象与面板同生命周期。
final class BrowserState: ObservableObject {
    static let shared = BrowserState()

    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var progress: Double = 0

    func reset() {
        canGoBack = false
        canGoForward = false
        isLoading = false
        progress = 0
    }

    private init() {}
}

// MARK: - 内嵌浏览器控制器

/// 主面板内嵌的 WKWebView 管理器（无独立窗口、无地址栏）。
///
/// 生命周期（内存策略，2026-09-21 排查结论）：
/// - 激活（`browserActive = true`）→ 创建全新 webview 并加载；
/// - 关闭 → `teardown()` 立即析构，WebContent 子进程（页面内存大头）随之退出；
/// - GPU / Networking 基础设施进程由 WebKit 保活复用 —— 这是下一次激活近秒开的原因。
///
/// 导航约定：
/// - 页面内普通链接 → 本 webview 内浏览（WKWebView 默认行为）；
/// - `target=_blank` 新标签链接 → 本 webview 内继续浏览（不弹 Safari）；
/// - 工具栏「safari」按钮 → 主动交给系统默认浏览器。
final class EmbeddedBrowserController: NSObject, WKNavigationDelegate, WKUIDelegate {
    static let shared = EmbeddedBrowserController()

    /// 菜单栏「浏览器」入口的起始页。
    static let homeURL = URL(string: "https://www.google.com")

    private var webView: WKWebView?
    private var kvoTokens: [NSKeyValueObservation] = []

    /// 加载 URL（webview 不存在则先创建）。
    /// `BrowserEmbedView` 在 browserActive 时会把同一个实例挂进视图树，这里先行创建不影响复用。
    func load(_ url: URL) {
        let web = ensureWebView()
        web.load(URLRequest(url: url))
    }

    func goBack() {
        webView?.goBack()
    }

    func goForward() {
        webView?.goForward()
    }

    /// 当前页交给系统默认浏览器（工具栏 safari 按钮）。
    func openInDefaultBrowser() {
        guard let url = webView?.url else { return }
        NSWorkspace.shared.open(url)
    }

    /// 取当前 webview（不存在则创建）。BrowserEmbedView 挂载时通过它取同一实例。
    func ensureWebView() -> WKWebView {
        if let web = webView { return web }

        let web = WKWebView(frame: .zero)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        webView = web
        observe(web)
        return web
    }

    /// 立即销毁 webview（收起网页 / 清空对话 / 关面板时调用），幂等。
    /// WKWebView 析构后 WebContent 子进程随之退出 —— 「关了不占内存」的关键。
    func teardown() {
        guard let web = webView else { return }
        web.stopLoading()
        web.navigationDelegate = nil
        web.uiDelegate = nil
        kvoTokens.removeAll()
        webView = nil
        BrowserState.shared.reset()
    }

    /// KVO：导航状态同步到工具栏。回调统一甩回主线程；进度做 2% 阈值节流
    /// （进度回调极高频，不节流会把工具栏 SwiftUI 树拖着高频重绘）。
    private func observe(_ web: WKWebView) {
        kvoTokens = [
            web.observe(\.canGoBack, options: [.initial, .new]) { _, _ in
                DispatchQueue.main.async { BrowserState.shared.canGoBack = web.canGoBack }
            },
            web.observe(\.canGoForward, options: [.initial, .new]) { _, _ in
                DispatchQueue.main.async { BrowserState.shared.canGoForward = web.canGoForward }
            },
            web.observe(\.isLoading, options: [.initial, .new]) { _, _ in
                DispatchQueue.main.async { BrowserState.shared.isLoading = web.isLoading }
            },
            web.observe(\.estimatedProgress, options: [.new]) { _, _ in
                DispatchQueue.main.async {
                    let s = BrowserState.shared
                    let p = web.estimatedProgress
                    if web.isLoading ? abs(p - s.progress) > 0.02 : s.progress != p {
                        s.progress = p
                    }
                }
            }
        ]
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation, withError error: Error) {
        // -999 = NSURLErrorCancelled：主动导航取消，不算失败，不弹错误页
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        showFailurePage(L10n.t(.browserLoadFailed, error.localizedDescription))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation,
                 withError error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        showFailurePage(L10n.t(.browserConnectFailed, error.localizedDescription))
    }

    /// 加载失败占位页（页内可点击重试）。
    private func showFailurePage(_ reason: String) {
        let html = "<html><body style='font-family:-apple-system,sans-serif;color:#666;"
            + "display:flex;justify-content:center;padding-top:120px'>"
            + "<p>" + reason + "　<a href='javascript:location.reload()'>"
            + L10n.t(.browserRetry) + "</a></p></body></html>"
        webView?.loadHTMLString(html, baseURL: nil)
    }

    // MARK: - WKUIDelegate

    /// `target=_blank`（新标签页）链接：不弹新窗口，本 webview 继续浏览。
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            load(url)
        }
        return nil
    }
}

// MARK: - SwiftUI 桥接

/// 把控制器的 webview 挂进 SwiftUI 视图树；视图被移除时兜底销毁（幂等）。
struct BrowserEmbedView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        EmbeddedBrowserController.shared.ensureWebView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        EmbeddedBrowserController.shared.teardown()
    }
}
