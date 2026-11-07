# Memory / process footprint of resident assistant sites (2026-10-29).
#
# WebView2 keeps its browser, GPU and renderer processes OUTSIDE the host process,
# so measuring QuickDrawer's own working set proves nothing. This script samples
# the msedgewebview2 process family after each site is opened, so the cost of a
# resident site can be attributed and reported honestly.
#
# ASCII only; paths derive from $PSScriptRoot.

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_helpers.ps1')
$resultPath = Join-Path $PSScriptRoot 'resident-mem.txt'

function Get-WebView2Stats {
    $procs = @(Get-Process msedgewebview2 -ErrorAction SilentlyContinue)
    $sum = 0
    foreach ($p in $procs) { $sum += $p.WorkingSet64 }
    return [pscustomobject]@{ Count = $procs.Count; TotalMb = [int]($sum / 1MB) }
}

function Get-AppWs {
    $p = Get-Process QuickDrawer -ErrorAction SilentlyContinue
    if (-not $p) { return 0 }
    return [int]($p.WorkingSet64 / 1MB)
}

function Sample([string]$stage) {
    $w = Get-WebView2Stats
    $host0 = Get-AppWs
    Say ("{0,-14} host={1,4}MB  webview2={2,3} procs {3,4}MB" -f $stage, $host0, $w.Count, $w.TotalMb)
    return $w.TotalMb
}

function Click-Chip([string]$name) {
    $d = Get-DrawerWindow
    if (-not $d) { return $false }
    $el = Find-Ctl $d $name
    if (-not $el) { return $false }
    Click-El $el 0.5
    return $true
}

function Wait-AssistantDiag([string]$pattern, [int]$timeoutMs = 20000) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        foreach ($ln in @(Read-DiagTail 80)) {
            if ($ln -match [regex]::Escape($pattern)) { return $true }
        }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

Stop-App
Start-Sleep -Milliseconds 700
Start-App
Ensure-DrawerOpen | Out-Null
[U4]::MoveTo(1780, 400)

$cfg = Read-Config
if ($cfg.dock.pinPanel -eq $true) {
    $d = Get-DrawerWindow
    $pin = Find-Ctl $d 'PinPanel'
    if ($pin) { Click-El $pin 0.5; Start-Sleep -Milliseconds 600 }
    Say 'unpinned the panel for the run'
}

$base = Sample 'app only'
$before = Get-Content -LiteralPath $diagPath | Select-String -Pattern '\[assistant\] navigate http' | Measure-Object
Say ("navigate lines at start = {0}" -f $before.Count)

Click-Tab 'TabAssistant' | Out-Null
Start-Sleep -Seconds 5
$one = Sample 'deepseek'

Click-Chip 'ChipKimi' | Out-Null
Start-Sleep -Seconds 5
$two = Sample 'kimi'

Click-Chip 'ChipGlm' | Out-Null
Start-Sleep -Seconds 6
$three = Sample 'chatglm'

# Make sure every provider is resident before measuring: the first visit to a site
# legitimately creates it (and navigates once), and that must not be counted here.
Click-Chip 'ChipDeepSeek' | Out-Null
Start-Sleep -Seconds 4
Click-Chip 'ChipKimi' | Out-Null
Start-Sleep -Milliseconds 1500
# Let the last creation settle before counting: diag lines are written slightly after
# the click returns, and counting too early makes the creation look like a reload.
Start-Sleep -Milliseconds 900

# All three sites are resident now, so every further switch must be navigation-free.
# (Measure the delta only here: the very first visit to a site creates it, and that
#  first creation legitimately navigates once.)
$navBefore = @(Get-Content -LiteralPath $diagPath | Select-String -Pattern '\[assistant\] navigate http').Count
Click-Chip 'ChipDeepSeek' | Out-Null
Start-Sleep -Milliseconds 1800
Click-Chip 'ChipKimi' | Out-Null
Start-Sleep -Milliseconds 1800
Click-Chip 'ChipGlm' | Out-Null
Start-Sleep -Milliseconds 1800
$navAfter = @(Get-Content -LiteralPath $diagPath | Select-String -Pattern '\[assistant\] navigate http').Count
Say ("navs: before={0} after={1} (+{2})" -f $navBefore, $navAfter, ($navAfter - $navBefore))
Check 'switching among resident sites adds no navigation' (($navAfter - $navBefore) -eq 0)

$siteCount = @(Get-Content -LiteralPath $diagPath | Select-String -Pattern 'site created:').Count
Say ("site created lines = {0}" -f $siteCount)

Say ("cost: deepseek=+{0}MB kimi=+{1}MB chatglm=+{2}MB (webview2 total)" -f ($one - $base), ($two - $one), ($three - $two))
Check 'three resident sites cost more than one' ($three -gt $one)

Flush
