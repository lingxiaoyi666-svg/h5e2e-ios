# 端到端测试（H5E2E）— iOS 未签名 IPA 工程

由 `h5toipa.py` 于 2026-10-07 20:00 生成。**不需要 Mac。**

## 这个工程里有什么

| 路径 | 作用 |
| --- | --- |
| `H5E2E.xcodeproj/` | 手写 Xcode 工程（可直接用 Xcode 打开，也能被 xcodebuild 编译） |
| `H5E2E/WebApp/` | 你的 H5 页面，5 个文件 / 0.00 MB |
| `H5E2E/H5E2EApp.swift` | App 入口（隐藏状态栏、锁方向、固定浅色） |
| `H5E2E/WebContainerView.swift` | WKWebView 容器 + 左边缘右滑返回 |
| `H5E2E/WebAssetSchemeHandler.swift` | 自定义 scheme `h5e2eapp://` 提供资源 |
| `H5E2E/Info.plist` | Bundle ID / 显示名 / 方向 / 权限说明 |
| `H5E2E/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` | 图标（1024×1024，其余尺寸由 Xcode 生成） |
| `.github/workflows/build-ipa.yml` | 云端编译工作流（macos-15 + macos-14 双镜像） |

## 关键参数

- Bundle ID：`com.dsh.h5e2e`
- 版本：1.0.0 (1）
- 最低系统：iOS 16.0
- 入口页：`index.html`
- URL scheme：`h5e2eapp://`
- 方向：仅竖屏

## 为什么用自定义 scheme 而不是 file://

WKWebView 在 `file://` 下会拿不到 `fetch` / `XMLHttpRequest` 的同目录资源，页面会静默丢数据。
自定义 scheme 走完整 URL 语义，路径解析、百分号编码、MIME 类型都正常。

## 要让 H5 改一点点

- 页面头部加 `viewport-fit=cover`，并自己用 `env(safe-area-inset-*)` 处理刘海，App 侧没有加内边距。
- 想用左边缘右滑返回：把 App 的 `WebContainerView.swift` 里 `allowsBackForwardNavigationGestures` 打开即可。
- 外链（`http/https`）会被交给系统浏览器，不会顶掉 App；如需在 App 内打开，改 `WebContainerView.swift` 的 `decidePolicyFor`。

## 出包

### 方式一：云端出包（推荐，真的能出 IPA）

```powershell
$env:GH_TOKEN = "ghp_xxx"   # 需勾 repo + workflow 两个 scope
.\ship.ps1 -Token $env:GH_TOKEN -RepoName h5e2e-ios -Public
```

`-Public` 很重要：**公开仓库的 GitHub Actions 分钟数免费无限**，私有仓库会撞消费上限，
报错原文是 `The job was not started because recent account payments have failed`——
那不是工程问题，是计费闸门。

跑完 IPA 会落在 `out\`，用「全能签」签名后安装。

### 方式二：本机有 Mac 时

```bash
xcodebuild -project H5E2E.xcodeproj -scheme H5E2E \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO archive
```

## 改应用名 / 改图标 / 改 Bundle ID

| 想改什么 | 改哪里 |
| --- | --- |
| 手机主屏显示的名字 | `H5E2E/Info.plist` 的 `CFBundleDisplayName`，以及 `H5E2E/zh-Hans.lproj/InfoPlist.strings` |
| 图标 | 换掉 `AppIcon-1024.png`（1024×1024、正方形、不要透明通道），重新出包 |
| Bundle ID | `H5E2E.xcodeproj/project.pbxproj` 里搜 `com.dsh.h5e2e`（共 2 处，Debug/Release） |
| 最低系统版本 | 同上，搜 `IPHONEOS_DEPLOYMENT_TARGET` |
| 版本号 | 同上，搜 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` |

## 静态自检

```powershell
python verify_project.py -Root .
```

会检查 pbxproj 对象引用完整性、Sources 阶段是否含全部 .swift、WebApp 是否为 folder reference、
scheme 的 BlueprintIdentifier 是否对上 target、plist/XML/YAML 是否合法等等。
这些是**只有云端编译才会暴露**的静默失败，本地先挡一道。

## 已知坑（都踩过）

1. scheme 必须在 `xcshareddata/**xcschemes**/`（是 `xcschemes` 不是 `xschemes`），
   写错会报 `does not contain a scheme named`。
2. `WebApp` 必须是 folder reference（`lastKnownFileType = folder`），否则资源会被打散。
3. 文件夹资源要同时出现在三处：`PBXFileReference` + `PBXBuildFile` + `PBXResourcesBuildPhase`，少一处就不进包。
4. `.github/workflows/` 用 PAT 上传时，Token 必须勾 `workflow` scope。
