# -*- coding: utf-8 -*-
"""校验个税 iOS IPA：结构 / Info.plist / arm64 / 未签名 / H5 资源是否进包"""
import plistlib, sys, zipfile, pathlib, collections

ipa = pathlib.Path(sys.argv[1] if len(sys.argv) > 1
                   else r"D:\dsh-scratch\ios-tax\out\个人所得税-unsigned-macos-15.ipa")

with zipfile.ZipFile(ipa) as z:
    names = z.namelist()
    app = next(n.split("/")[1] for n in names if n.startswith("Payload/") and n.count("/") > 1)
    base = f"Payload/{app}/"

    print(f"IPA      : {ipa.name}  ({ipa.stat().st_size / 1048576:.2f} MB)")
    print(f"App 包名 : {app}")
    print(f"条目总数 : {len(names)}")

    d = plistlib.loads(z.read(base + "Info.plist"))

    # ---------- 1. Info.plist ----------
    print("\n=== Info.plist 关键项 ===")
    for k in ("CFBundleIdentifier", "CFBundleDisplayName", "CFBundleName",
              "CFBundleShortVersionString", "CFBundleVersion", "MinimumOSVersion",
              "UIDeviceFamily", "CFBundleSupportedPlatforms", "UISupportedInterfaceOrientations"):
        v = d.get(k, "缺失")
        print(f"  {k:<34} {v}")
    icon_set = "CFBundleIcons" in d
    print(f"  {'CFBundleIcons':<34} {'已注入' if icon_set else '缺失'}")

    # ---------- 2. H5 资源 ----------
    print("\n=== H5 资源进包情况（folder reference 是否生效）===")
    wa = f"{base}WebApp/"
    wa_files = [n for n in names if n.startswith(wa) and not n.endswith("/")]
    ext = collections.Counter(pathlib.PurePosixPath(n).suffix.lower() for n in wa_files)
    print(f"  WebApp 内文件数: {len(wa_files)}   （本地预期 122）")
    print(f"  类型分布: {dict(ext)}")
    need = ["index.html", "shuiming.html", "login.html", "shouye.html",
            "nashui_edit.html", "xiangqing.html",
            "js/local_api.js", "js/ui_kit.js", "js/ui_editor.js", "js/sdtab.js",
            "css/sdtheme.css", "css/nav.css"]
    miss = [n for n in need if (wa + n) not in names]
    for n in need:
        print(f"    {'OK  ' if (wa + n) in names else '缺失'} {n}")
    bak = [n for n in wa_files if n.endswith((".bak", ".orig"))]
    print(f"  .bak/.orig 残留: {len(bak)}  （应为 0）")

    # 关键 JS 内容抽查：fetch 拦截必须还在
    la = z.read(wa + "js/local_api.js").decode("utf-8", "replace")
    print(f"  local_api.js 大小: {len(la)} 字符, fetch 拦截: "
          f"{'存在' if 'window.fetch = function' in la else '丢失!'}")
    print(f"  local_api.js TAX_VERSION: "
          f"{la.split('TAX_VERSION')[1][:18].strip() if 'TAX_VERSION' in la else '未找到'}")

    # ---------- 3. 二进制架构 ----------
    print("\n=== 主程序 ===")
    exe_name = d.get("CFBundleExecutable") or app.rsplit(".", 1)[0]
    exe_path = base + exe_name
    if exe_path in names:
        exe = z.read(exe_path)
        magic = int.from_bytes(exe[:4], "little")
        cpu = exe[4:8]
        cpu_sub = exe[8:12]
        print(f"  {exe_name}  {len(exe)} B")
        print(f"  Mach-O magic : 0x{magic:08X}  "
              f"({'64 位小端 (MH_MAGIC_64)' if magic == 0xFEEDFACF else '非预期'})")
        print(f"  cputype/cpusub: {' '.join(f'{b:02X}' for b in cpu)} / "
              f"{' '.join(f'{b:02X}' for b in cpu_sub)}  "
              f"({'arm64' if cpu == b'\x0c\x00\x00\x01' else '非 arm64'})")
        arm64_ok = cpu == b"\x0c\x00\x00\x01"
    else:
        print(f"  找不到可执行文件 {exe_path}")
        arm64_ok = False

    # ---------- 4. 签名状态 ----------
    print("\n=== 签名状态（自签要求：必须无签名）===")
    for probe, want in (("_CodeSignature/", "不存在"),
                        ("embedded.mobileprovision", "不存在"),
                        ("CodeResources", "不存在")):
        hit = [n for n in names if n.startswith(base) and probe in n]
        print(f"  {probe:<28} {'存在 -> 异常!' if hit else '不存在 ✓'}  （期望{want}）")

    # ---------- 5. 图标 ----------
    print("\n=== 图标 ===")
    for n in sorted(n for n in names if n.startswith(base) and "AppIcon" in n):
        print(f"  {n.replace(base, ''):<32} {z.getinfo(n).file_size} B")

    # ---------- 汇总 ----------
    print("\n" + "=" * 56)
    problems = []
    if len(wa_files) < 120:
        problems.append(f"WebApp 只进了 {len(wa_files)} 个文件（预期 122）")
    if miss:
        problems.append(f"缺关键文件: {miss}")
    if bak:
        problems.append(f"进了 {len(bak)} 个 .bak/.orig")
    if "window.fetch = function" not in la:
        problems.append("local_api.js 的 fetch 拦截丢失")
    if not icon_set:
        problems.append("Info.plist 没有 CFBundleIcons")
    if d.get("CFBundleIdentifier") != "com.example.geshui":
        problems.append(f"Bundle ID 是 {d.get('CFBundleIdentifier')}")
    if not arm64_ok:
        problems.append("主程序不是 arm64")
    if problems:
        for p in problems:
            print("  [问题]", p)
        sys.exit(1)
    print("结果：全部通过 —— 可以拿去全能签签名了")
