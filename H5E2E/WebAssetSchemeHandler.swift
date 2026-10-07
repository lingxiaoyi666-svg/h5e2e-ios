//
//  WebAssetSchemeHandler.swift
//  用自定义 scheme（h5e2eapp://localhost/...）从 App 包里提供 H5 资源。
//
//  为什么不用 file:// ：
//    WKWebView 在 file:// 下会拒绝 fetch/XHR 读取同目录资源，而本项目里有
//    gerenxinxi.html 的 fetch('/js/pca.json')、theme-loader.js 的
//    fetch('/api/public/mine-ui') 等不在 local_api.js 拦截表里的请求，
//    file:// 会让它们静默失败。自定义 scheme 走的是正常 URL 语义，不会。
//

import Foundation
import WebKit
import UniformTypeIdentifiers

final class WebAssetSchemeHandler: NSObject, WKURLSchemeHandler {

    static let scheme = "h5e2eapp"

    /// 资源根目录。首次启动时把 bundle 里的 WebApp 复制到 Documents，
    /// 之后一律从这里读；后续要改页面，直接替换 Documents/WebApp 即可，
    /// 不必重新签名安装。
    static var assetRoot: URL = {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dest = docs.appendingPathComponent("WebApp", isDirectory: true)

        if !fm.fileExists(atPath: dest.path) {
            if let src = Bundle.main.url(forResource: "WebApp", withExtension: nil) {
                do {
                    try fm.copyItem(at: src, to: dest)
                } catch {
                    NSLog("[WebAsset] 复制 WebApp 到 Documents 失败: \(error)")
                    return src
                }
            } else {
                NSLog("[WebAsset] bundle 里找不到 WebApp 目录")
                return docs
            }
        }
        return dest
    }()

    /// MIME 表：iOS 对未知 scheme 不猜类型，返回错的 Content-Type 会让
    /// CSS/JS 被当成文本而失效，页面直接白屏。
    private static let mimeMap: [String: String] = [
        "html": "text/html", "htm": "text/html",
        "js": "text/javascript", "mjs": "text/javascript",
        "css": "text/css",
        "json": "application/json",
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif", "webp": "image/webp", "svg": "image/svg+xml",
        "ico": "image/x-icon", "bmp": "image/bmp",
        "woff": "font/woff", "woff2": "font/woff2",
        "ttf": "font/ttf", "otf": "font/otf", "eot": "application/vnd.ms-fontobject",
        "mp3": "audio/mpeg", "mp4": "video/mp4", "wav": "audio/wav",
        "txt": "text/plain", "xml": "application/xml",
        "php": "text/plain",              // 本项目无真实后端，避免被当可执行
        "map": "application/json",
    ]

    private static func mime(for ext: String) -> String {
        if let t = mimeMap[ext.lowercased()] { return t }
        if let t = UTType(filenameExtension: ext)?.preferredMIMEType { return t }
        return "application/octet-stream"
    }

    // MARK: - WKURLSchemeHandler

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            fail(urlSchemeTask, code: 400, reason: "无 URL")
            return
        }

        let rel = resolveRelativePath(from: url)
        let root = Self.assetRoot
        let fileURL = root.appendingPathComponent(rel)

        // 防目录穿越
        let rootPath = root.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath == rootPath || filePath.hasPrefix(rootPath + "/") else {
            fail(urlSchemeTask, code: 403, reason: "越界路径: \(rel)")
            return
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: filePath, isDirectory: &isDir), !isDir.boolValue else {
            fail(urlSchemeTask, code: 404, reason: "未找到: \(rel)")
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch {
            fail(urlSchemeTask, code: 500, reason: "读取失败: \(rel)")
            return
        }

        let ext = (rel as NSString).pathExtension
        var headers: [String: String] = [
            "Content-Type": "\(Self.mime(for: ext)); charset=utf-8",
            "Content-Length": String(data.count),
            // 避免 App 升级后仍命中旧缓存
            "Cache-Control": "no-store, no-cache, must-revalidate",
            "Access-Control-Allow-Origin": "*",
        ]
        if ext.lowercased() == "html" {
            headers["Content-Type"] = "text/html; charset=utf-8"
        }

        guard let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers
        ) else {
            fail(urlSchemeTask, code: 500, reason: "构造响应失败")
            return
        }

        urlSchemeTask.didReceive(response)
        if urlSchemeTask.request.httpMethod != "HEAD" {
            urlSchemeTask.didReceive(data)
        }
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // 无进行中的异步操作，忽略
    }

    // MARK: - 工具

    /// h5e2eapp://localhost/a/b.html  ->  a/b.html
    /// h5e2eapp://localhost/js/x.js    ->  js/x.js
    private func resolveRelativePath(from url: URL) -> String {
        var p = url.path
        if p.hasPrefix("/") { p.removeFirst() }
        if p.isEmpty { p = "index.html" }        // 根路径默认回首页

        // URL 里可能是百分号编码（中文文件名、空格），解出来再找文件
        if let decoded = p.removingPercentEncoding { p = decoded }

        // 统一斜杠：H5 里会写 \ 的地方（历史遗留）也兼容
        p = p.replacingOccurrences(of: "\\", with: "/")
        return p
    }

    private func fail(_ task: WKURLSchemeTask, code: Int, reason: String) {
        NSLog("[WebAsset] \(code) \(reason)")
        let body = """
        <!doctype html><meta charset="utf-8">
        <body style="font:15px -apple-system;padding:24px;color:#333;background:#fff">
        <h3 style="margin:0 0 8px">资源未找到</h3>
        <p style="color:#666;margin:0 0 12px">\(reason)</p>
        <p style="color:#999;font-size:12px">cleartext=\(code)</p>
        </body>
        """.data(using: .utf8) ?? Data()

        if let url = task.request.url,
           let resp = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1",
                                      headerFields: ["Content-Type": "text/html; charset=utf-8",
                                                     "Content-Length": String(body.count)]) {
            task.didReceive(resp)
            task.didReceive(body)
            task.didFinish()
        } else {
            task.didFailWithError(NSError(domain: "WebAsset", code: code,
                                          userInfo: [NSLocalizedDescriptionKey: reason]))
        }
    }
}
