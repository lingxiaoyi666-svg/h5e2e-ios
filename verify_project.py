# -*- coding: utf-8 -*-
"""
verify_project.py —— Xcode 工程静态自检（不需要 Mac，也不跑 xcodebuild）

目的：挡住「本地看不出来、只有云端 xcodebuild 才炸」的那几类静默失败：
  · pbxproj 里有引用没定义            → Xcode 直接打不开工程
  · .swift 没进 Sources 阶段          → 文件不编译，且不报错
  · WebApp 不是 folder reference      → 资源被打散，App 里页面路径全错
  · 文件夹资源没进 Resources 阶段      → App 里没有页面，白屏
  · scheme 目录名写成 xschemes         → does not contain a scheme named ...
  · scheme 的 BlueprintIdentifier 对不上 target
  · Info.plist 缺键 / plist / XML / YAML 格式错
  · 工作流 YAML 里断言的路径不存在

用法：
    python verify_project.py                        # 自动找当前目录下的 *.xcodeproj
    python verify_project.py -Root D:\\path\\to\\MyApp-ios
    python verify_project.py -Root . -Entry index.html -Bid com.me.app
"""
from __future__ import annotations

import argparse
import pathlib
import plistlib
import re
import sys
import xml.etree.ElementTree as ET

ap = argparse.ArgumentParser()
ap.add_argument("-Root", default=".")
ap.add_argument("-Entry", default="index.html", help="入口页文件名")
ap.add_argument("-Bid", default="", help="期望的 Bundle ID（默认不校验具体值）")
ap.add_argument("-Display", default="", help="期望的显示名（默认不校验具体值）")
ap.add_argument("-SchemeName", default="", help="期望的自定义 URL scheme（默认不校验）")
args = ap.parse_args()

ROOT = pathlib.Path(args.Root).resolve()
if not ROOT.is_dir():
    print(f"[FAIL] 找不到目录: {ROOT}")
    sys.exit(1)

fails, warns = [], []


def hdr(t):
    print(f"\n=== {t} ===")


def ok(m):
    print(f"  [OK]   {m}")


def bad(m):
    fails.append(m)
    print(f"  [FAIL] {m}")


def warn(m):
    warns.append(m)
    print(f"  [警告] {m}")


def expect(cond, m):
    (ok if cond else bad)(m)
    return cond


# ── 0. 定位工程 ────────────────────────────────────────────────
hdr("目录结构")
xcodeprojs = sorted(p for p in ROOT.glob("*.xcodeproj") if p.is_dir())
if not xcodeprojs:
    bad(f"{ROOT} 下没有 *.xcodeproj")
    print("\n无法继续")
    sys.exit(1)
PBXROOT = xcodeprojs[0]
TARGET = PBXROOT.stem
SRCDIR = ROOT / TARGET
ok(f"工程: {PBXROOT.name}    target: {TARGET}")

pbx_path = PBXROOT / "project.pbxproj"
if not pbx_path.exists():
    bad("project.pbxproj 不存在")
    sys.exit(1)
pbx = pbx_path.read_text(encoding="utf-8")

# ── 1. pbxproj ────────────────────────────────────────────────
hdr("project.pbxproj")
for o, c, name in (("{", "}", "花括号"), ("(", ")", "圆括号")):
    a, b = pbx.count(o), pbx.count(c)
    expect(a == b, f"{name}平衡 {a}/{b}")

defined = set(re.findall(r"^\t\t([A-Fa-f0-9]{24})\b[^\n]*=\s*\{", pbx, re.M))
defined |= set(re.findall(r"^\t\t([A-Fa-f0-9]{24})\s*=", pbx, re.M))
root = re.search(r"rootObject\s*=\s*([A-Fa-f0-9]{24})", pbx)
if root:
    defined.add(root.group(1))
referenced = set(re.findall(r"\b([A-Fa-f0-9]{24})\b", pbx))
missing = sorted(referenced - defined)
if missing:
    bad(f"引用了未定义的对象 ID: {missing}")
    for m in missing[:5]:
        for ln, line in enumerate(pbx.splitlines(), 1):
            if m in line:
                print(f"         第 {ln} 行: {line.strip()[:110]}")
                break
else:
    ok(f"对象引用完整（定义 {len(defined)} / 引用 {len(referenced)}）")

# Sources 阶段必须含全部 .swift
src_block = re.search(r"PBXSourcesBuildPhase section \*/(.*?)/\* End PBXSourcesBuildPhase", pbx, re.S)
src_names = set()
if src_block:
    src_names = {n.strip() for _, n in
                 re.findall(r"([A-Fa-f0-9]{24}) /\* ([^*]+?) in Sources \*/", src_block.group(1))}
swift_on_disk = {p.name for p in SRCDIR.glob("*.swift")}
expect(src_names == swift_on_disk,
       f"Sources 阶段与磁盘 .swift 一致：{sorted(src_names)}"
       + ("" if src_names == swift_on_disk else f" / 磁盘 {sorted(swift_on_disk)}"))

# 每个 .swift 都要有 PBXFileReference（path = 文件名）
for sw in sorted(swift_on_disk):
    expect(re.search(rf"path = {re.escape(sw)};", pbx) is not None,
           f"pbxproj 里有 {sw} 的 PBXFileReference")

# Resources 阶段必须含 WebApp 与 Assets
res_block = re.search(r"PBXResourcesBuildPhase section \*/(.*?)/\* End PBXResourcesBuildPhase", pbx, re.S)
res_entries = [m.strip() for m in re.findall(r"/\* ([^*]+?) \*/", res_block.group(1))] if res_block else []
for need in ("WebApp in Resources", "Assets.xcassets in Resources"):
    expect(need in res_entries, f"Resources 阶段含「{need}」")
print(f"         阶段内容: {res_entries}")

# WebApp 必须是 folder reference
m = re.search(r"([A-Fa-f0-9]{24}) /\* WebApp \*/ = \{isa = PBXFileReference;([^}]*)\}", pbx)
if m:
    expect("lastKnownFileType = folder" in m.group(2),
           "WebApp 是 folder reference（整目录拷进包，不是扁平化）")
else:
    bad("pbxproj 里找不到 WebApp 的 PBXFileReference")

bf = re.search(r"([A-Fa-f0-9]{24}) /\* WebApp in Resources \*/ = \{isa = PBXBuildFile; fileRef = ([A-Fa-f0-9]{24})", pbx)
wapp_ref = re.search(r"([A-Fa-f0-9]{24}) /\* WebApp \*/ = \{isa = PBXFileReference", pbx)
if bf and wapp_ref:
    expect(bf.group(2) == wapp_ref.group(1),
           f"WebApp in Resources 的 fileRef 指向 {bf.group(2)}（应为 {wapp_ref.group(1)}）")

# 关键 build settings
checks = [("IPHONEOS_DEPLOYMENT_TARGET", None), ("INFOPLIST_FILE", TARGET),
          ("ASSETCATALOG_COMPILER_APPICON_NAME", "AppIcon"), ("SDKROOT", "iphoneos"),
          ("SWIFT_VERSION", "5.0"), ("PRODUCT_BUNDLE_IDENTIFIER", args.Bid or None)]
for k, v in checks:
    if v is None:
        expect(re.search(rf"{k} = \S", pbx) is not None, f"{k} 已设置")
    else:
        expect(re.search(rf"{k} = {re.escape(v)}", pbx) is not None, f"{k} = {v}")
expect('CODE_SIGN_IDENTITY = ""' in pbx, 'CODE_SIGN_IDENTITY = ""（关签名）')
expect('PRODUCT_NAME = "$(TARGET_NAME)"' in pbx, 'PRODUCT_NAME = $(TARGET_NAME)')
expect(f'CODE_SIGN_ENTITLEMENTS = {TARGET}/{TARGET}.entitlements;' in pbx,
       f"CODE_SIGN_ENTITLEMENTS = {TARGET}/{TARGET}.entitlements")
expect(f'INFOPLIST_FILE = {TARGET}/Info.plist;' in pbx, f"INFOPLIST_FILE = {TARGET}/Info.plist")

# scheme 位置与 BlueprintIdentifier
scheme_dir = PBXROOT / "xcshareddata" / "xcschemes"
scheme_path = scheme_dir / f"{TARGET}.xcscheme"
if not scheme_path.exists():
    bad(f"缺共享 scheme: {scheme_path.relative_to(ROOT)}"
        "   ← 必须是 xcshareddata/xcschemes/（注意是 xcschemes）")
    wrong = PBXROOT / "xcshareddata" / "xschemes"
    if wrong.exists():
        bad("发现拼错的目录 xcshareddata/xschemes/（会导致 does not contain a scheme named）")
else:
    ok("scheme 位于 xcshareddata/xcschemes/")
    sx = scheme_path.read_text(encoding="utf-8")
    tid = re.search(rf"([A-Fa-f0-9]{{24}}) /\* {re.escape(TARGET)} \*/ = \{{\s*isa = PBXNativeTarget", pbx)
    bp = set(re.findall(r'BlueprintIdentifier = "([A-Fa-f0-9]{24})"', sx))
    if tid and bp == {tid.group(1)}:
        ok(f"scheme 的 BlueprintIdentifier 与 target 一致 ({tid.group(1)})")
    else:
        bad(f"scheme 指向 {bp}，target 是 {tid.group(1) if tid else '?'}")
    expect(f'BlueprintName = "{TARGET}"' in sx, f'scheme 的 BlueprintName = {TARGET}')
    expect(f'container:{PBXROOT.name}' in sx, f"scheme 的 ReferencedContainer = {PBXROOT.name}")

# ── 2. plist ──────────────────────────────────────────────────
hdr("plist 文件")
ent = SRCDIR / f"{TARGET}.entitlements"
info = SRCDIR / "Info.plist"
for p in (info, ent):
    if not p.exists():
        bad(f"缺 {p.relative_to(ROOT)}")
        continue
    try:
        d = plistlib.loads(p.read_bytes())
        ok(f"{p.relative_to(ROOT)} 可解析（{len(d)} 键）")
        if p is info:
            for need in ("CFBundleIdentifier", "CFBundleExecutable", "CFBundleShortVersionString",
                         "CFBundleVersion", "CFBundleDisplayName", "UIRequiredDeviceCapabilities",
                         "UISupportedInterfaceOrientations"):
                if need not in d:
                    bad(f"Info.plist 缺 {need}")
            if args.Display and d.get("CFBundleDisplayName") != args.Display:
                bad(f"Info.plist 显示名 {d.get('CFBundleDisplayName')!r} ≠ {args.Display!r}")
            elif d.get("CFBundleDisplayName"):
                ok(f"显示名 = {d['CFBundleDisplayName']}")
            if "MinimumOSVersion" in d:
                warn(f"Info.plist 显式写了 MinimumOSVersion={d['MinimumOSVersion']}"
                     "（通常交给 Xcode 从 IPHONEOS_DEPLOYMENT_TARGET 注入）")
            else:
                ok("MinimumOSVersion 由 Xcode 注入（预期行为）")
            ori = d.get("UISupportedInterfaceOrientations", [])
            ok(f"方向: {ori}")
    except Exception as e:
        bad(f"{p.relative_to(ROOT)} 解析失败: {e}")

strings = SRCDIR / "zh-Hans.lproj" / "InfoPlist.strings"
if strings.exists():
    try:
        t = strings.read_text(encoding="utf-8")
        expect('"CFBundleDisplayName"' in t, "InfoPlist.strings 含 CFBundleDisplayName")
    except Exception as e:
        bad(f"InfoPlist.strings 不是合法 UTF-8: {e}")
else:
    warn("没有 zh-Hans.lproj/InfoPlist.strings（不影响运行）")

# ── 3. XML / YAML ─────────────────────────────────────────────
hdr("scheme XML 与工作流 YAML")
if scheme_path.exists():
    try:
        ET.parse(scheme_path)
        ok("xcscheme XML 合法")
    except Exception as e:
        bad(f"xcscheme XML 错误: {e}")

wf = ROOT / ".github" / "workflows" / "build-ipa.yml"
wft = wf.read_text(encoding="utf-8") if wf.exists() else ""
if not wf.exists():
    bad("缺 .github/workflows/build-ipa.yml")
else:
    try:
        import yaml
        y = yaml.safe_load(wft)
        ok(f"工作流 YAML 合法（jobs: {list(y['jobs'])}，"
           f"matrix: {y['jobs']['build']['strategy']['matrix']}）")
        steps = [s.get("name") or s.get("uses") for s in y["jobs"]["build"]["steps"]]
        print(f"         步骤: {steps}")
    except ImportError:
        warn("无 pyyaml，跳过 YAML 结构化校验")
    except Exception as e:
        bad(f"工作流 YAML 错误: {e}")

    # 工作流里的名字必须与工程一致
    expect(f"-project {PBXROOT.name}" in wft, f"工作流用了 -project {PBXROOT.name}")
    expect(f"-scheme {TARGET}" in wft, f"工作流用了 -scheme {TARGET}")
    for rel in (f"{TARGET}/WebApp", PBXROOT.name, f"{TARGET}/Info.plist"):
        expect((ROOT / rel).exists(), f"工作流引用的路径存在: {rel}")

    kl = re.search(r"for f in ([^\n]*?); do", wft)
    if kl:
        names = [n for n in kl.group(1).replace("\\", " ").split() if n]
        miss = [n for n in names if not (SRCDIR / "WebApp" / n).exists()]
        expect(not miss, f"工作流断言的关键 H5 文件都在"
                         + (f" — 缺: {miss}" if miss else f"（{len(names)} 个）"))

# ── 4. WebApp 资源 ────────────────────────────────────────────
hdr("WebApp 资源")
wa = SRCDIR / "WebApp"
if not wa.exists():
    bad("WebApp 目录不存在")
else:
    files = [p for p in wa.rglob("*") if p.is_file()]
    ext = {}
    for f in files:
        ext[f.suffix.lower()] = ext.get(f.suffix.lower(), 0) + 1
    ok(f"{len(files)} 个文件, {sum(p.stat().st_size for p in files) / 1048576:.2f} MB")
    print("         " + "  ".join(f"{k or '(无)'}:{v}" for k, v in sorted(ext.items())))
    expect((wa / args.Entry).exists(), f"入口页 {args.Entry}")
    leftovers = [p.name for p in files if p.suffix.lower() in (".bak", ".orig")]
    expect(not leftovers, f"无 .bak/.orig 残留{'' if not leftovers else ': ' + str(leftovers[:5])}")
    cn = [p.relative_to(wa).as_posix() for p in files if any(ord(ch) > 127 for ch in p.name)]
    if cn:
        warn(f"含非 ASCII 文件名的资源 {len(cn)} 个"
             "（Scheme handler 会做百分号解码，仍建议真机确认）")
        for n in cn[:5]:
            print(f"           {n}")
    # 入口页里的绝对路径引用（相对根的资源要用 /xxx 才走得通自定义 scheme）
    try:
        ent_txt = (wa / args.Entry).read_text(encoding="utf-8", errors="replace")
        if 'viewport-fit=cover' not in ent_txt:
            warn("入口页 viewport 里没有 viewport-fit=cover（刘海机型会被切边，H5 需自行适配）")
    except Exception:
        pass

# ── 5. 图标 ───────────────────────────────────────────────────
hdr("AppIcon")
ic = SRCDIR / "Assets.xcassets" / "AppIcon.appiconset"
png = ic / "AppIcon-1024.png"
if png.exists():
    try:
        from PIL import Image
        with Image.open(png) as im:
            expect(im.size == (1024, 1024), f"AppIcon-1024.png 尺寸 {im.size}")
            expect(im.mode == "RGB", f"图标模式 {im.mode}（iOS 要求无 alpha 的 RGB）")
    except ImportError:
        warn("无 PIL，跳过图标检查")
    js = (ic / "Contents.json").read_text(encoding="utf-8")
    expect('"size" : "1024x1024"' in js, "AppIcon Contents.json 声明 1024x1024")
else:
    bad(f"缺 {png.relative_to(ROOT)}")

# ── 6. Swift 粗查 ─────────────────────────────────────────────
hdr("Swift 源文件")
sw_all = ""
for sw in sorted(SRCDIR.glob("*.swift")):
    t = sw.read_text(encoding="utf-8")
    sw_all += t + "\n"
    a, b = t.count("{"), t.count("}")
    expect(a == b, f"{sw.name}: {len(t.splitlines())} 行, 花括号 {a}/{b}"
                   + ("" if a == b else "  不平衡!"))
for need in ("@main", "WKWebView", "setURLSchemeHandler", "WKNavigationDelegate"):
    expect(need in sw_all, f"Swift 代码含 {need}")
if "WKURLSchemeHandler" in sw_all:
    sm = re.search(r'static let scheme = "([^"]*)"', sw_all)
    expect(sm is not None, "定了自定义 scheme 常量")
    if sm and args.SchemeName:
        expect(sm.group(1) == args.SchemeName,
               f'scheme = "{sm.group(1)}"（期望 {args.SchemeName}）')
    elif sm:
        ok(f'scheme = "{sm.group(1)}"')
if re.search(r'forResource: "WebApp"', sw_all):
    ok("从 bundle 复制 WebApp 到 Documents 的逻辑存在")
else:
    warn("没找到 WebApp 复制逻辑")

# ── 汇总 ──────────────────────────────────────────────────────
print("\n" + "=" * 58)
if warns:
    print(f"警告 {len(warns)} 条：")
    for w in warns:
        print("  -", w)
if fails:
    print(f"失败 {len(fails)} 条：")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("结果：全部通过")
