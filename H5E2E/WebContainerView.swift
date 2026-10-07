//
//  WebContainerView.swift
//  承载 H5 的容器：WKWebView + 左边缘返回手势
//

import SwiftUI
import WebKit

struct WebContainerView: View {
    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            WebViewContainer()
        }
        .background(Color.white)
    }
}

/// 把 WKWebView 包成 SwiftUI 可用视图
struct WebViewContainer: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()

        // —— 关键：用自定义 scheme 提供资源，而不是 file:// ——
        // file:// 下 WKWebView 会拦掉 fetch/XHR，而本项目有 19 处 fetch 调用，
        // 其中 gerenxinxi.html 的 /js/pca.json、theme-loader.js 的 /api/public/mine-ui
        // 不在 local_api.js 的拦截表里，走 file:// 会静默失败。
        cfg.setURLSchemeHandler(WebAssetSchemeHandler(), forURLScheme: WebAssetSchemeHandler.scheme)

        // 允许内联播放、允许 localStorage 持久化（默认即允许，这里显式写出意图）
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []

        // H5 自己处理 safe-area，所以我们不用 contentInsetAdjustment
        cfg.preferences.isElementFullscreenEnabled = false

        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator

        // 页面固定竖屏设计，禁掉左右滑动历史手势，避免和 shuiming.html 的
        // scroll-snap 年份选择器抢手势
        web.allowsBackForwardNavigationGestures = false
        web.scrollView.bounces = false
        web.scrollView.alwaysBounceVertical = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.showsVerticalScrollIndicator = false
        web.scrollView.showsHorizontalScrollIndicator = false
        web.isOpaque = false
        web.backgroundColor = .white
        web.scrollView.backgroundColor = .white
        web.accessibilityIdentifier = "mainWebView"

        context.coordinator.webView = web
        context.coordinator.attachEdgeSwipe(to: web)

        if let url = URL(string: "\(WebAssetSchemeHandler.scheme)://localhost/index.html") {
            web.load(URLRequest(url: url))
        }
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.detachEdgeSwipe()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        private weak var swipe: UIScreenEdgePanGestureRecognizer?

        /// 左边缘右滑 = 网页返回上一页（替代被禁掉的系统手势）
        func attachEdgeSwipe(to web: WKWebView) {
            let g = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgeSwipe(_:)))
            g.edges = .left
            g.cancelsTouchesInView = false
            web.addGestureRecognizer(g)
            swipe = g
        }

        func detachEdgeSwipe() {
            if let g = swipe, let w = webView { w.removeGestureRecognizer(g) }
            swipe = nil
        }

        @objc private func handleEdgeSwipe(_ g: UIScreenEdgePanGestureRecognizer) {
            guard g.state == .ended, let w = webView else { return }
            let t = g.translation(in: w)
            let v = g.velocity(in: w)
            if t.x > 60 || v.x > 500 {
                if w.canGoBack {
                    w.goBack()
                } else {
                    // 已经在首页：从边缘右滑无副作用，避免用户以为卡死
                    w.evaluateJavaScript("window.dispatchEvent(new Event('appEdgeBack'))", completionHandler: nil)
                }
            }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            // 站内资源（自定义 scheme）一律放行
            if url.scheme == WebAssetSchemeHandler.scheme {
                decisionHandler(.allow)
                return
            }

            // 外部链接（如 login.html 里那个 http://175.24.180.44:8080 跳转）
            // 交给系统打开，别把 App 顶掉
            if url.scheme == "http" || url.scheme == "https" {
                if navigationAction.targetFrame?.isMainFrame ?? false {
                    UIApplication.shared.open(url)
                    decisionHandler(.cancel)
                    return
                }
                decisionHandler(.allow)
                return
            }

            if url.scheme == "about" || url.scheme == "data" || url.scheme == "blob" {
                decisionHandler(.allow)
                return
            }

            // 其它 scheme（tel:/mailto: 等）交给系统
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(error, phase: "didFail")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            report(error, phase: "didFailProvisional")
        }

        private func report(_ error: Error, phase: String) {
            let ns = error as NSError
            // -999 是主动取消，不算错误
            if ns.code == NSURLErrorCancelled { return }
            NSLog("[WebContainer] \(phase): \(ns.domain) \(ns.code) \(ns.localizedDescription)")
        }
    }
}
