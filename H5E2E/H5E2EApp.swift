//
//  TaxApp.swift
//  端到端测试 —— H5 外壳（WKWebView）
//

import SwiftUI

@main
struct H5E2EApp: App {
    var body: some Scene {
        WindowGroup {
            WebContainerView()
                .ignoresSafeArea(.all)          // 网页自己处理 safe-area（已带 viewport-fit=cover）
                .preferredColorScheme(.light)   // 页面是浅色设计，固定浅色避免深色模式串色
                .statusBarHidden(true)          // H5 自带顶栏，隐藏系统状态栏保持满屏一致
        }
    }
}
