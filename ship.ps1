# ============================================================
#  ship.ps1 —— 个税 iOS 工程：上传 GitHub → 云端编译 → 下载 IPA
#  不依赖 git，全部走 GitHub REST API
#
#  用法：
#     $env:GH_TOKEN = "ghp_xxx";  .\ship.ps1
#     .\ship.ps1 -Token "ghp_xxx"
#  可选：
#     -RepoName 仓库名（默认 geshui-ios）
#     -OutDir   下载目录（默认 D:\dsh-scratch\ios-tax\out）
# ============================================================
[CmdletBinding()]
param(
    [string]$Token = $env:GH_TOKEN,
    [string]$RepoName = 'geshui-ios',
    [string]$Root = 'D:\dsh-scratch\ios-tax\iPhoneTax',
    [string]$OutDir = 'D:\dsh-scratch\ios-tax\out',
    [switch]$Public,
    [int]$TimeoutMin = 35
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Say  ([string]$m) { Write-Host $m }
function OK   ([string]$m) { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Warn ([string]$m) { Write-Host "  [警告] $m" -ForegroundColor Yellow }
function Die  ([string]$m) { Write-Host "  [失败] $m" -ForegroundColor Red; exit 1 }

$script:Base = 'https://api.github.com'
$script:Hdr = @{
    Authorization          = "Bearer $Token"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = 'dsh-ship'
}

function Invoke-GH {
    param([string]$Method = 'GET', [string]$Path, $Body, [switch]$Allow404)
    $uri = if ($Path -like 'http*') { $Path } else { "$script:Base$Path" }
    $req = @{ Method = $Method; Uri = $uri; Headers = $script:Hdr; TimeoutSec = 120 }
    if ($null -ne $Body) {
        $req.Body = ($Body | ConvertTo-Json -Depth 10 -Compress)
        $req.ContentType = 'application/json; charset=utf-8'
    }
    try { return Invoke-RestMethod @req } catch {
        $code = $null
        try { $code = [int]$_.Exception.Response.StatusCode } catch {}
        # GitHub 对「空仓库里不存在的分支」返回 409 而不是 404，两个都当"不存在"处理
        if ($Allow404 -and ($code -eq 404 -or $code -eq 409)) { return $null }
        $detail = ''
        try {
            $s = $_.Exception.Response.GetResponseStream()
            $detail = (New-Object System.IO.StreamReader($s)).ReadToEnd()
        } catch {}
        throw "GitHub API $Method $Path 失败 (HTTP $code)`n$detail"
    }
}

Say ""
Say "======================================================"
Say " 个税 iOS 工程 -> GitHub -> macOS 云端编译 -> 未签名 IPA"
Say "======================================================"

if (-not $Token) {
    Say ""
    Say "缺少 Token。生成（只勾 repo + workflow）："
    Say "    https://github.com/settings/tokens/new?scopes=repo,workflow&description=geshui-ios"
    Say '然后： $env:GH_TOKEN = "把token粘这里"; .\ship.ps1'
    Die "未提供 Token"
}
if (-not (Test-Path $Root)) { Die "找不到工程目录: $Root" }

# ---------- 1 ----------
Say ""
Say "[1/6] 校验 Token"
$me = Invoke-GH -Path '/user'
$owner = $me.login
OK "登录身份: $owner"

# ---------- 2 ----------
Say ""
Say "[2/6] 准备仓库 $owner/$RepoName"
$repo = Invoke-GH -Path "/repos/$owner/$RepoName" -Allow404
if ($repo) {
    OK "仓库已存在，直接复用"
} else {
    $repo = Invoke-GH -Method POST -Path '/user/repos' -Body @{
        name        = $RepoName
        description = '个人所得税 H5 -> iOS WKWebView shell (hand-written Xcode project, unsigned IPA via GitHub Actions).'
        private     = (-not $Public)
        auto_init   = $false
        has_issues  = $false
        has_wiki    = $false
    }
    OK "已创建$(if ($Public) {'公开'} else {'私有'})仓库"
}
$branch = if ($repo.default_branch) { $repo.default_branch } else { 'main' }
Say "      https://github.com/$owner/$RepoName"

# ---------- 3 ----------
Say ""
Say "[3/6] 上传工程文件"
$refExists = $null -ne (Invoke-GH -Path "/repos/$owner/$RepoName/git/ref/heads/$branch" -Allow404)
if (-not $refExists) {
    $readme = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
        "# $RepoName`n`n个人所得税 H5 的 iOS 外壳工程（手写 Xcode 工程，无第三方依赖）。`n"))
    Invoke-GH -Method PUT -Path "/repos/$owner/$RepoName/contents/README.md" -Body @{
        message = 'init'; content = $readme; branch = $branch
    } | Out-Null
    OK "已建立 $branch 分支"
}

$files = Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
    Where-Object { $_.FullName -notmatch '\\\.git\\' } |
    ForEach-Object { [pscustomobject]@{
        Rel = $_.FullName.Substring($Root.Length + 1).Replace('\', '/'); Full = $_.FullName
    } }

$total = ($files | ForEach-Object { (Get-Item $_.Full).Length } | Measure-Object -Sum).Sum
Say "      共 $($files.Count) 个文件，$([math]::Round($total/1MB,2)) MB"
Say "      （其中 WebApp 是 H5 资源，已排除 *.bak / *.orig / _selfcheck / tools）"

$nUp = 0; $nSkip = 0; $i = 0
foreach ($f in $files) {
    $i++
    $apiPath = "/repos/$owner/$RepoName/contents/$($f.Rel)"
    $existing = Invoke-GH -Path $apiPath -Allow404
    $bytes = [System.IO.File]::ReadAllBytes($f.Full)

    if ($existing -and $existing.sha) {
        $same = $false
        try {
            $remote = [Convert]::FromBase64String(($existing.content -replace '\s', ''))
            if ($remote.Length -eq $bytes.Length) {
                $same = $true
                for ($k = 0; $k -lt $bytes.Length; $k++) {
                    if ($remote[$k] -ne $bytes[$k]) { $same = $false; break }
                }
            }
        } catch { $same = $false }
        if ($same) { $nSkip++; continue }
        Invoke-GH -Method PUT -Path $apiPath -Body @{
            message = "update $($f.Rel)"; content = [Convert]::ToBase64String($bytes)
            branch = $branch; sha = $existing.sha
        } | Out-Null
        Say ("        ~ {0}" -f $f.Rel)
    } else {
        Invoke-GH -Method PUT -Path $apiPath -Body @{
            message = "add $($f.Rel)"; content = [Convert]::ToBase64String($bytes); branch = $branch
        } | Out-Null
    }
    $nUp++
    if ($i % 25 -eq 0) { Say "        ...已处理 $i / $($files.Count)" }
}
OK "上传完成：新增/更新 $nUp，内容未变跳过 $nSkip"

# ---------- 4 ----------
Say ""
Say "[4/6] 触发工作流"
$wf = Invoke-GH -Path "/repos/$owner/$RepoName/actions/workflows/build-ipa.yml" -Allow404
if (-not $wf) {
    Warn "GitHub 尚未识别工作流，等 10 秒重试"
    Start-Sleep -Seconds 10
    $wf = Invoke-GH -Path "/repos/$owner/$RepoName/actions/workflows/build-ipa.yml" -Allow404
    if (-not $wf) { Die "工作流未被识别。检查 .github/workflows/build-ipa.yml 是否上传成功、Token 是否有 workflow 权限" }
}
OK "工作流已识别: $($wf.name)"

$before = (Invoke-GH -Path "/repos/$owner/$RepoName/actions/runs?per_page=1").workflow_runs
$lastId = if ($before) { $before[0].id } else { 0 }

Invoke-GH -Method POST -Path "/repos/$owner/$RepoName/actions/workflows/build-ipa.yml/dispatches" `
    -Body @{ ref = $branch } | Out-Null
OK "已触发（ref=$branch）"

# ---------- 5 ----------
Say ""
Say "[5/6] 等待 macOS 编译（两个镜像并行，正常 4-8 分钟，最长 $TimeoutMin 分钟）"
$deadline = (Get-Date).AddMinutes($TimeoutMin)
$run = $null; $lastShown = ''
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 12
    $runs = (Invoke-GH -Path "/repos/$owner/$RepoName/actions/runs?per_page=5").workflow_runs
    $run = $runs | Where-Object { $_.id -gt $lastId } | Sort-Object id -Descending | Select-Object -First 1
    if (-not $run) { Say "      ... 等待排队"; continue }
    $shown = "$($run.status) / $($run.conclusion)"
    if ($shown -ne $lastShown) { Say "      $shown"; $lastShown = $shown }
    if ($run.status -eq 'completed') { break }
}
Say ""
if (-not $run -or $run.status -ne 'completed') {
    Die "等待超时。手动看日志: https://github.com/$owner/$RepoName/actions"
}
if ($run.conclusion -ne 'success') {
    Warn "工作流结论: $($run.conclusion)"
    Say "      日志: $($run.html_url)"
    Say "      把带 error / FAILED / ::error:: 的那几行发我。"
    exit 1
}
OK "编译成功"
Say "      日志: $($run.html_url)"

# ---------- 6 ----------
Say ""
Say "[6/6] 下载产物"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$arts = (Invoke-GH -Path "/repos/$owner/$RepoName/actions/runs/$($run.id)/artifacts").artifacts
if (-not $arts) { Die "没有 artifact" }

$got = 0
foreach ($a in $arts) {
    if ($a.expired) { Warn "$($a.name) 已过期"; continue }
    $zipPath = Join-Path $OutDir "$($a.name).zip"
    Say "      下载 $($a.name)  ($([math]::Round($a.size_in_bytes/1MB,2)) MB)"

    $hc = [System.Net.Http.HttpClient]::new()
    $hc.DefaultRequestHeaders.Authorization =
        [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Token)
    $hc.DefaultRequestHeaders.UserAgent.ParseAdd('dsh-ship')
    try {
        $resp = $hc.GetAsync($a.archive_download_url,
            [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $resp.EnsureSuccessStatusCode() | Out-Null
        $fs = [System.IO.File]::Create($zipPath)
        try { $resp.Content.CopyToAsync($fs).GetAwaiter().GetResult() } finally { $fs.Dispose() }
    } finally { $hc.Dispose() }

    Expand-Archive -LiteralPath $zipPath -DestinationPath (Join-Path $OutDir $a.name) -Force
    $ipa = Get-ChildItem -Path (Join-Path $OutDir $a.name) -Recurse -Filter *.ipa | Select-Object -First 1
    if ($ipa) {
        # 产物优先用 macos-15（较新的 SDK），另一版留作备选，避免出现同名重复文件
        $isPrimary = $a.name -match 'macos-15' -or -not ($arts | Where-Object { $_.name -match 'macos-15' })
        if ($isPrimary) { $final = Join-Path $OutDir '个人所得税-iOS-unsigned.ipa' }
        else            { $final = Join-Path $OutDir '个人所得税-iOS-unsigned-macos14备选.ipa' }
        Copy-Item $ipa.FullName $final -Force
        $h = (Get-FileHash $final -Algorithm SHA256).Hash
        OK "IPA: $final  ($([math]::Round((Get-Item $final).Length/1MB,2)) MB)"
        Say "      SHA256 $h"
        $got++
    }
}
if ($got -eq 0) { Die "没有解出 .ipa" }

Say ""
Say "======================================================"
Say " 完成。IPA 在: $OutDir"
Say " 下一步：全能签签名安装"
Say "======================================================"
Say ""
