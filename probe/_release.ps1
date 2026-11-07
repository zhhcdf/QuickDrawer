<#
.SYNOPSIS
    QuickDrawer 一键发布：版本号 → 构建 → 发布 → 打包 → 校验和 → 提交 → 推送 → GitHub Release → 端到端验证。

.DESCRIPTION
    把 2026-11-07 首次发布时手工做的每一步固化下来，避免漏项。流程顺序是有原因的，
    每一步的注释里写了为什么不能调换。

    脚本在以下任一情况会直接失败退出（不会半途留下坏状态）：
      - 工作区有未提交改动 / 不在 main 分支 / 版本号格式不对
      - CHANGELOG.md 里没有该版本的小节（发布说明只能来自这里，不自动编造）
      - 该版本的 tag 或 Release 已存在
      - 发布目录在当前工作区内（DSH 文件沙箱会给工作区加 ACE，导致产物写不了 %APPDATA%）

.PARAMETER Version
    要发布的版本号，三段式，例如 1.0.1。脚本会同步改三处：
    csproj 的 Version / AssemblyVersion / FileVersion、README 的 **版本**、CHANGELOG 的小节标题。

.PARAMETER DryRun
    只做校验并打印计划，不改任何文件、不构建、不提交、不推送、不创建 Release。

.EXAMPLE
    .\probe\_release.ps1 -Version 1.0.1 -DryRun

.EXAMPLE
    .\probe\_release.ps1 -Version 1.0.1

.NOTES
    2026-11-07 首次发布踩到的坑（都已固化进脚本）：
      1. winget 装 gh 会挂在未提权的 UAC 上 → gh 用免安装 zip 放在 D:\software\gh。
      2. gh / git 是 Go 程序，只认 HTTP_PROXY / HTTPS_PROXY 环境变量，不读系统 IE 代理设置。
         脚本会自动探测系统代理是否在监听，在监听才注入环境变量（代理关掉时注入会反而连不上）。
      3. gh auth login --web 需要一个真交互式终端，在非交互环境里会打印完设备码就静默退出，
         且不留下任何配置目录 → 登录态必须事先用 --with-token 建立好，脚本只校验不代劳。
      4. dotnet publish 前必须先停掉运行中的实例，否则 QuickDrawer.exe 被占用导致 MSB3027/MSB3021，
         而 bash 里接了 | tail 时退出码仍是 0，会被误判成成功。
      5. git push 退出码 0 只说明对象传上去了；真正要确认的是"别人从 Release 页面能不能下到
         和本地逐字节相同的文件"，所以最后一步必须从公开 URL 匿名下载一次并比 SHA256。
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [string]$Root = 'D:\Documents\DeepSeek\快捷桌面项目',
    [string]$PublishDir = 'D:\software\QuickDrawer-publish-net48',
    [string]$GhExe = 'D:\software\gh\gh.exe',
    [string]$Repo = 'zhhcdf/QuickDrawer',

    [switch]$DryRun,
    [switch]$NoPush,
    [bool]$Launch = $true
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# 全中文输出在 Windows PowerShell 5.1 的 GBK 控制台里会显示成问号，统一成 UTF-8
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$script:StepNo = 0
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Step {
    param([string]$Text)
    $script:StepNo++
    Write-Host ''
    Write-Host ("[{0}/{1}] {2}" -f $script:StepNo, 9, $Text) -ForegroundColor Cyan
}

function Info  { param([string]$Text) Write-Host "      $Text" }
function Ok    { param([string]$Text) Write-Host "      OK  $Text" -ForegroundColor Green }
function Warn  { param([string]$Text) Write-Host "      !!  $Text" -ForegroundColor Yellow }

function Die {
    param([string]$Text)
    Write-Host ''
    Write-Host "FAILED: $Text" -ForegroundColor Red
    exit 1
}

function Assert-LastExit {
    param([string]$What)
    if ($LASTEXITCODE -ne 0) { Die "$What 失败（exit=$LASTEXITCODE）" }
}

# ---------------------------------------------------------------------------
# 读 / 写文本：保留原换行风格，不让一次改版本号把整个文件变成全文件 diff
# ---------------------------------------------------------------------------
function Read-TextFile {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text = $script:Utf8NoBom.GetString($bytes, $(if ($bom) { 3 } else { 0 }), $(if ($bom) { $bytes.Length - 3 } else { $bytes.Length }))
    [pscustomobject]@{ Text = $text; Bom = $bom }
}

function Write-TextFile {
    param([string]$Path, [string]$Text, [bool]$Bom)
    $enc = if ($Bom) { New-Object System.Text.UTF8Encoding($true) } else { $script:Utf8NoBom }
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

# ---------------------------------------------------------------------------
# 代理：只在系统代理确实在监听时注入环境变量
#   gh / git 是 Go 程序，只读环境变量，不读 HKCU 的 WinINET 设置；
#   但代理关掉之后还硬注入，反而会 connectex: target machine actively refused。
# ---------------------------------------------------------------------------
function Resolve-Proxy {
    if ($env:HTTPS_PROXY) { return $env:HTTPS_PROXY }

    $reg = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    if (-not $reg -or $reg.ProxyEnable -ne 1 -or -not $reg.ProxyServer) { return $null }

    $server = [string]$reg.ProxyServer
    if ($server -like '*=*') {
        # 形如 "http=127.0.0.1:3067;https=127.0.0.1:3067"
        $map = @{}
        foreach ($part in $server.Split(';')) {
            $kv = $part.Split('=', 2)
            if ($kv.Count -eq 2) { $map[$kv[0].Trim().ToLower()] = $kv[1].Trim() }
        }
        $server = if ($map.ContainsKey('https')) { $map['https'] } elseif ($map.ContainsKey('http')) { $map['http'] } else { '' }
    }
    $server = $server -replace '^https?://', ''
    if (-not $server) { return $null }

    $hostPart = $server.Split(':')[0]
    $portPart = if ($server.Contains(':')) { [int]$server.Split(':')[1] } else { 8080 }

    $alive = $false
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $alive = $client.ConnectAsync($hostPart, $portPart).Wait(1200)
        $client.Close()
    } catch { $alive = $false }

    if (-not $alive) {
        Warn "系统代理 $server 未在监听，按直连处理"
        return $null
    }

    $url = "http://$server"
    $env:HTTP_PROXY = $url
    $env:HTTPS_PROXY = $url
    Info "使用系统代理 $url"
    return $url
}

function Assert-Gh {
    if (-not (Test-Path $GhExe)) {
        Die "找不到 gh：$GhExe`n      下载 https://github.com/cli/cli/releases 的 windows_amd64.zip，解压把 gh.exe 放进去。"
    }
    $null = Resolve-Proxy
    & $GhExe auth status 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Die "gh 未登录。先执行（token 从 https://github.com/settings/tokens 生成，勾 repo + workflow）：`n      `$tok | & `"$GhExe`" auth login --hostname github.com --git-protocol https --with-token"
    }
    $who = (& $GhExe api user --jq '.login' 2>$null)
    Assert-LastExit 'gh api user'
    Ok "gh 已登录：$($who.Trim())"
}

# ---------------------------------------------------------------------------
# 1. 前置校验
# ---------------------------------------------------------------------------
function Assert-Preconditions {
    Step '前置校验：版本号 / 分支 / 工作区 / 发布目录位置'

    if ($Version -notmatch '^\d+\.\d+\.\d+$') {
        Die "版本号必须是三段式（如 1.0.1），收到：$Version"
    }
    if (-not (Test-Path (Join-Path $Root 'QuickDrawer.sln'))) {
        Die "Root 不是 QuickDrawer 仓库：$Root"
    }

    $head = (Get-Content (Join-Path $Root '.git\HEAD') -Raw).Trim()
    if ($head -notmatch 'refs/heads/(.+)$') { Die "HEAD 不是分支引用：$head" }
    $branch = $Matches[1].Trim()
    if ($branch -ne 'main') { Die "当前分支是 $branch，发布只允许在 main 上" }
    Ok "分支 main"

    $dirty = & git -C $Root -c core.quotepath=false status --porcelain
    Assert-LastExit 'git status'
    if ($dirty) {
        Write-Host $dirty
        Die '工作区有未提交改动，先提交或还原再发布（发布脚本自己要改版本号，混着别人的改动没法区分）'
    }
    Ok '工作区干净'

    # 发布目录必须在工作区之外。DSH 会给工作区根加 inherited=False 的 ACE，
    # 从工作区子树启动的进程写不了 %APPDATA%，日志 delta=0，助手页报 COMException 0x800700AA。
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $pubFull = [System.IO.Path]::GetFullPath($PublishDir).TrimEnd('\')
    if ($pubFull.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase) -or $pubFull -eq $rootFull) {
        Die "发布目录不能在工作区内：$pubFull`n      工作区上的 ACL 会让产物写不了 %APPDATA%。请用工作区外的目录。"
    }
    Ok "发布目录在工作区外：$pubFull"

    foreach ($tool in @('dotnet', 'git')) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { Die "找不到命令：$tool" }
    }
    Ok 'dotnet / git 可用'

    Assert-Gh

    # 该版本是否已经发过
    & $GhExe api "repos/$Repo/releases/tags/v$Version" 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Die "Release v$Version 已存在，不能重复发布。要重发请先删掉旧 Release 和 tag。" }
    $tags = & git -C $Root tag --list "v$Version"
    if ($tags) { Die "本地已有 tag v$Version" }
    Ok "v$Version 未发布过"
}

# ---------------------------------------------------------------------------
# 2. CHANGELOG 必须有对应小节（发布说明的唯一来源）
# ---------------------------------------------------------------------------
function Get-ChangelogSection {
    param([string]$Version)
    $path = Join-Path $Root 'CHANGELOG.md'
    if (-not (Test-Path $path)) { Die "找不到 $path" }

    $raw = (Read-TextFile $path).Text -replace "`r`n", "`n"
    $lines = $raw -split "`n"

    $startPattern = '^##\s*\[' + [regex]::Escape($Version) + '\]'
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $startPattern) { $start = $i; break }
    }
    if ($start -lt 0) {
        Die "CHANGELOG.md 里没有 ## [$Version] 小节。`n      发布说明只从 CHANGELOG 取，不自动编造。请先写好这一节再发布。"
    }

    $end = $lines.Count
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^##\s') { $end = $i; break }
    }

    $body = ($lines[$start..($end - 1)] -join "`n").Trim()
    if ($body.Length -lt 40) { Die "CHANGELOG 的 [$Version] 小节内容太短（$($body.Length) 字符），疑似占位。" }
    return $body
}

# ---------------------------------------------------------------------------
# 3. 改版本号：三处必须同步
# ---------------------------------------------------------------------------
function Update-VersionFiles {
    Step "改版本号到 $Version（csproj / README / CHANGELOG 标题）"

    $csprojPath = Join-Path $Root 'src\QuickDrawer\QuickDrawer.csproj'
    $csproj = Read-TextFile $csprojPath

    $pairs = @(
        @{ Name = 'Version';        Pattern = '<Version>\d+\.\d+\.\d+</Version>';               Repl = "<Version>$Version</Version>" },
        @{ Name = 'AssemblyVersion'; Pattern = '<AssemblyVersion>\d+\.\d+\.\d+\.\d+</AssemblyVersion>'; Repl = "<AssemblyVersion>$Version.0</AssemblyVersion>" },
        @{ Name = 'FileVersion';    Pattern = '<FileVersion>\d+\.\d+\.\d+\.\d+</FileVersion>';   Repl = "<FileVersion>$Version.0</FileVersion>" }
    )
    $newCsproj = $csproj.Text
    foreach ($p in $pairs) {
        $count = ([regex]::Matches($newCsproj, $p.Pattern)).Count
        if ($count -ne 1) { Die "csproj 里 <$($p.Name)> 匹配到 $count 处（应为 1 处）" }
        $newCsproj = [regex]::Replace($newCsproj, $p.Pattern, $p.Repl)
        Ok "csproj $($p.Name) = $($p.Repl -replace '<[^>]+>', '')"
    }

    $readmePath = Join-Path $Root 'README.md'
    $readme = Read-TextFile $readmePath
    $readmePattern = '\*\*版本\*\*：\d+\.\d+\.\d+'
    if (([regex]::Matches($readme.Text, $readmePattern)).Count -ne 1) { Die 'README.md 里 **版本**：X.Y.Z 匹配不到唯一一处' }
    $newReadme = [regex]::Replace($readme.Text, $readmePattern, "**版本**：$Version")
    Ok "README **版本**：$Version"

    $changelogPath = Join-Path $Root 'CHANGELOG.md'
    $cl = Read-TextFile $changelogPath
    $clPattern = '^##\s*\[' + [regex]::Escape($Version) + '\]\s*—\s*\d{4}-\d{2}-\d{2}'
    if (([regex]::Matches($cl.Text, $clPattern, 'Multiline')).Count -ne 1) {
        Die "CHANGELOG.md 的 ## [$Version] — YYYY-MM-DD 标题匹配不到唯一一处（日期格式必须是 2026-11-07 这种）"
    }
    Ok "CHANGELOG 小节标题已就位"

    if ($DryRun) { Info '（DryRun：不写盘）'; return }

    Write-TextFile $csprojPath $newCsproj $csproj.Bom
    Write-TextFile $readmePath $newReadme $readme.Bom
    Ok '版本号已写入'
}

# ---------------------------------------------------------------------------
# 4. 构建
# ---------------------------------------------------------------------------
function Invoke-Build {
    Step '构建 Release'
    Push-Location $Root
    try {
        $out = & dotnet build 'src\QuickDrawer\QuickDrawer.csproj' -c Release -v q --nologo 2>&1
        $code = $LASTEXITCODE
        $out | Where-Object { $_ -match 'warning|error|警告|错误' } | ForEach-Object { Info $_ }
        if ($code -ne 0) { $out | Write-Host; Die "dotnet build 失败（exit=$code）" }
        $warnCount = ($out | Select-String -Pattern '^\s*\d+\s*(个)?警告' -AllMatches).Count
        Ok "构建成功（exit=0，无 error）"
    } finally { Pop-Location }
}

# ---------------------------------------------------------------------------
# 5. 停实例（否则 QuickDrawer.exe 被占用，publish 报 MSB3027/MSB3021）
# ---------------------------------------------------------------------------
function Stop-RunningInstance {
    Step '停掉运行中的实例'
    $p = Get-Process QuickDrawer -ErrorAction SilentlyContinue
    if (-not $p) { Info '没有运行中的实例'; return }
    foreach ($proc in $p) {
        Info "结束 PID $($proc.Id)（$($proc.Path)）"
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }
    for ($i = 0; $i -lt 40; $i++) {
        if (-not (Get-Process QuickDrawer -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 250
    }
    if (Get-Process QuickDrawer -ErrorAction SilentlyContinue) { Die '实例仍在运行，无法发布（exe 被占用）' }
    Ok '已停止'
}

# ---------------------------------------------------------------------------
# 6. 发布
# ---------------------------------------------------------------------------
function Invoke-Publish {
    Step "发布到 $PublishDir"
    Push-Location $Root
    try {
        $out = & dotnet publish 'src\QuickDrawer\QuickDrawer.csproj' -c Release -f net48 -o $PublishDir --nologo 2>&1
        $code = $LASTEXITCODE
        if ($code -ne 0 -or ($out -match 'error')) { $out | Write-Host; Die "dotnet publish 失败（exit=$code）" }
    } finally { Pop-Location }

    $exe = Join-Path $PublishDir 'QuickDrawer.exe'
    if (-not (Test-Path $exe)) { Die "发布后找不到 $exe" }

    $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($exe)
    Info ("exe = {0:N0} 字节 / {1}" -f (Get-Item $exe).Length, (Get-Item $exe).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))
    Info "FileVersion = $($info.FileVersion)   ProductVersion = $($info.ProductVersion)"

    # 版本号必须真的进了二进制，否则发出去的还是旧号
    if ($info.FileVersion -ne "$Version.0") {
        Die "FileVersion 是 $($info.FileVersion)，期望 $Version.0 —— 版本号没进产物"
    }
    Ok "FileVersion = $Version.0"

    $stats = Get-ChildItem $PublishDir -Recurse -File | Measure-Object -Property Length -Sum
    Info ("发布产物 {0} 个文件 / {1:N0} 字节（{2:N2} MB）" -f $stats.Count, $stats.Sum, ($stats.Sum / 1MB))
    Ok '发布完成'
}

# ---------------------------------------------------------------------------
# 7. 打包 + 校验和
# ---------------------------------------------------------------------------
function New-ReleaseAssets {
    Step '生成 zip 与 SHA256SUMS'
    $assetDir = Join-Path $env:TEMP "qd_release_v$Version"
    if (Test-Path $assetDir) { Remove-Item $assetDir -Recurse -Force }
    New-Item -ItemType Directory -Path $assetDir -Force | Out-Null

    $zip = Join-Path $assetDir "QuickDrawer-$Version-win-x64.zip"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory($PublishDir, $zip, [System.IO.Compression.CompressionLevel]::Optimal, $true)

    $hash = (Get-FileHash $zip -Algorithm SHA256).Hash
    $zipName = [System.IO.Path]::GetFileName($zip)
    $sums = Join-Path $assetDir 'SHA256SUMS.txt'
    # 两个空格是 sha256sum 的标准分隔符，别写成制表符
    [System.IO.File]::WriteAllText($sums, "$hash  $zipName`n", $script:Utf8NoBom)

    Info ("zip     = {0:N0} 字节" -f (Get-Item $zip).Length)
    Info "sha256  = $hash"
    Ok "资产目录 $assetDir"

    return [pscustomobject]@{ Dir = $assetDir; Zip = $zip; Sums = $sums; Hash = $hash; ZipName = $zipName }
}

# ---------------------------------------------------------------------------
# 8. 提交 + 推送
# ---------------------------------------------------------------------------
function Invoke-GitCommitPush {
    param([string]$Version)

    Step '提交版本号并推送'
    $changed = & git -C $Root -c core.quotepath=false status --porcelain
    Assert-LastExit 'git status'
    if (-not $changed) {
        Warn '没有文件改动，跳过提交'
        return
    }
    Write-Host $changed
    & git -C $Root -c core.quotepath=false add -A
    Assert-LastExit 'git add'
    & git -C $Root -c core.quotepath=false commit -m "发布 $Version"
    Assert-LastExit 'git commit'
    Ok '已提交'

    if ($NoPush) { Warn '（-NoPush：不推送）'; return }
    & git -C $Root -c core.quotepath=false push origin main 2>&1 | ForEach-Object { Info $_ }
    Assert-LastExit 'git push'
    Ok '已推送'

    # push 退出码 0 只说明对象传上去了，还要核对远端 HEAD 与本地一致
    $localSha = (& git -C $Root rev-parse HEAD).Trim()
    $remoteSha = (& $GhExe api "repos/$Repo/commits/main" --jq '.sha' 2>$null)
    Assert-LastExit 'gh api commits/main'
    $remoteSha = $remoteSha.Trim()
    if ($localSha -ne $remoteSha) { Die "远端 HEAD($remoteSha) 与本地($localSha) 不一致" }
    Ok "远端 HEAD = $localSha"
}

# ---------------------------------------------------------------------------
# 9. 创建 Release
# ---------------------------------------------------------------------------
function Publish-GitHubRelease {
    param([string]$Version, $Assets, [string]$Notes)

    Step "创建 GitHub Release v$Version"
    if ($NoPush) { Warn '（-NoPush：不创建 Release）'; return $null }

    $notesFile = Join-Path $Assets.Dir 'release_notes.md'
    [System.IO.File]::WriteAllText($notesFile, $Notes, $script:Utf8NoBom)

    $null = Resolve-Proxy
    $out = & $GhExe release create "v$Version" `
        "$($Assets.Zip)#QuickDrawer $Version (win-x64, 绿色免安装)" `
        "$($Assets.Sums)#SHA256 校验值" `
        --repo $Repo `
        --title "QuickDrawer $Version" `
        --notes-file $notesFile `
        --latest 2>&1
    $code = $LASTEXITCODE
    $out | ForEach-Object { Info $_ }
    if ($code -ne 0) { Die "gh release create 失败（exit=$code）" }
    Ok 'Release 已创建'
    return "https://github.com/$Repo/releases/tag/v$Version"
}

# ---------------------------------------------------------------------------
# 10. 端到端验证：从公开 URL 匿名下载并比 SHA256
# ---------------------------------------------------------------------------
function Test-EndToEnd {
    param([string]$Version, $Assets, [string]$ReleaseUrl)

    Step '端到端验证：匿名下载 Release 附件并比 SHA256'
    if ($NoPush) { Warn '（-NoPush：跳过）'; return }

    $url = "https://github.com/$Repo/releases/download/v$Version/$($Assets.ZipName)"
    $tmp = Join-Path $env:TEMP "qd_verify_$Version.zip"
    if (Test-Path $tmp) { Remove-Item $tmp -Force }

    try {
        Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 180
    } catch {
        Die "下载失败：$url`n      $($_.Exception.Message)"
    }

    $remoteHash = (Get-FileHash $tmp -Algorithm SHA256).Hash
    $remoteSize = (Get-Item $tmp).Length
    Info "下载 $remoteSize 字节"
    Info "sha256 = $remoteHash"

    if ($remoteHash -ne $Assets.Hash) {
        Die "SHA256 不一致！本地 $($Assets.Hash) vs 远端 $remoteHash"
    }
    Ok '与本地逐字节一致'

    # 顺带核对附件确实处于 uploaded 状态
    $st = (& $GhExe release view "v$Version" --repo $Repo --json tagName,isDraft,isPrerelease,assets 2>$null)
    Assert-LastExit 'gh release view'
    $meta = $st | ConvertFrom-Json
    Info ("tag={0} draft={1} prerelease={2}" -f $meta.tagName, $meta.isDraft, $meta.isPrerelease)
    foreach ($a in $meta.assets) { Info ("附件 {0} {1} 字节" -f $a.name, $a.size) }
    if ($meta.assets.Count -ne 2) { Warn "附件数量是 $($meta.assets.Count)，期望 2" }

    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    Ok "Release 地址 $ReleaseUrl"
}

# ===========================================================================
# 主流程
# ===========================================================================
Write-Host ''
Write-Host "QuickDrawer 发布脚本 — 目标版本 $Version" -ForegroundColor White
if ($DryRun) { Write-Host '   *** DryRun：只校验，不改任何东西 ***' -ForegroundColor Yellow }
Write-Host "   仓库   $Root"
Write-Host "   产物   $PublishDir"
Write-Host "   gh     $GhExe"
Write-Host "   远端   $Repo"

Assert-Preconditions
$notes = Get-ChangelogSection -Version $Version
Info "CHANGELOG 小节 $($notes.Length) 字符"

if ($DryRun) {
    Step 'DryRun：后续步骤将执行（此处不执行）'
    Info '改版本号 → 构建 → 停实例 → 发布 → 打包 → 提交 → 推送 → 创建 Release → 端到端验证'
    Write-Host ''
    Write-Host 'DryRun 通过，没有做任何改动。' -ForegroundColor Green
    exit 0
}

Update-VersionFiles
Invoke-Build
Stop-RunningInstance
Invoke-Publish
$assets = New-ReleaseAssets
Invoke-GitCommitPush -Version $Version
$releaseUrl = Publish-GitHubRelease -Version $Version -Assets $assets -Notes $notes
Test-EndToEnd -Version $Version -Assets $assets -ReleaseUrl $releaseUrl

if ($Launch) {
    Step '重新启动应用'
    $exe = Join-Path $PublishDir 'QuickDrawer.exe'
    Start-Process -FilePath $exe -WorkingDirectory $PublishDir | Out-Null
    Start-Sleep -Seconds 3
    $p = Get-Process QuickDrawer -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p) { Ok "已启动 PID $($p.Id)（$Version）" } else { Warn '进程没起来，手动检查一下' }
}

Write-Host ''
Write-Host "发布完成：$Version" -ForegroundColor Green
if ($releaseUrl) { Write-Host "  $releaseUrl" -ForegroundColor Green }
Write-Host ''
