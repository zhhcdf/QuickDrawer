# Fast latency measurement (2026-10-29): how long does the assistant page take to
# come back after switching away, and how long does a provider switch take?
# Uses a small sampled region so the pixel loop does not distort timings.

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_helpers.ps1')
$resultPath = Join-Path $PSScriptRoot 'reentry-speed.txt'

function Get-FastInk([int]$x, [int]$y, [int]$w, [int]$h) {
    if ($w -le 0 -or $h -le 0) { return 0.0 }
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size($w, $h)))
    $ink = 0; $n = 0
    for ($yy = 0; $yy -lt $h; $yy += 4) {
        for ($xx = 0; $xx -lt $w; $xx += 4) {
            $c = $bmp.GetPixel($xx, $yy)
            $l = 0.299 * $c.R + 0.587 * $c.G + 0.114 * $c.B
            if ($l -lt 200) { $ink++ }
            $n++
        }
    }
    $g.Dispose(); $bmp.Dispose()
    if ($n -eq 0) { return 0.0 }
    return (100.0 * $ink / $n)
}

function Get-ViewRect {
    for ($i = 0; $i -lt 20; $i++) {
        $d = Get-DrawerWindow
        if ($d) {
            $v = Find-Ctl $d 'AssistantView'
            if ($v) {
                $r = $v.Current.BoundingRectangle
                if ($r.Width -gt 100 -and $r.Height -gt 100) { return $r }
            }
        }
        Start-Sleep -Milliseconds 150
    }
    return $null
}

function Time-UntilInk($rect, [double]$target, [int]$budgetMs = 15000) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $last = 0.0
    while ($sw.ElapsedMilliseconds -lt $budgetMs) {
        $last = Get-FastInk $rect.X ($rect.Y + 40) ([int]$rect.Width) 240
        if ($last -ge $target) { return @([int]$sw.ElapsedMilliseconds, $last) }
    }
    return @(-1, $last)
}

try {
    Say '=== reentry speed ==='
    Backup-State

    $app = Get-App
    if (-not $app) { Start-App | Out-Null; Start-Sleep -Milliseconds 1800 }
    Ensure-DrawerOpen | Out-Null
    $drawer = Get-DrawerWindow
    if (-not $drawer) { Say 'FAIL: drawer not found'; Flush; exit 1 }

    $cfg = Read-Config
    if ($cfg.dock.pinPanel -eq $true) {
        $pin = Find-Ctl $drawer 'PinPanel'
        if ($pin) { Click-El $pin; Start-Sleep -Milliseconds 600 }
    }

    Click-Tab 'TabAssistant'
    Wait-Diag 'page shown (provider=' 20000 | Out-Null
    Start-Sleep -Milliseconds 3000
    $vr = Get-ViewRect
    if (-not $vr) { Say 'FAIL: no view rect'; Flush; exit 1 }
    $rect = [pscustomobject]@{ X = [int]$vr.X; Y = [int]$vr.Y; Width = [int]$vr.Width; Height = [int]$vr.Height }
    Say ("view = {0},{1} {2}x{3}" -f $rect.X, $rect.Y, $rect.Width, $rect.Height)

    $baseInk = Get-FastInk $rect.X ($rect.Y + 40) $rect.Width 240
    Say ("baseline ink = {0}%" -f [math]::Round($baseInk, 2))
    $target = [math]::Max(0.4, $baseInk * 0.6)

    for ($round = 1; $round -le 3; $round++) {
        Click-Tab 'TabNotes'
        Start-Sleep -Milliseconds 1200
        $navA = @(Select-String -LiteralPath $diagPath -Pattern 'navigate ' -SimpleMatch -ErrorAction SilentlyContinue).Count

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Click-Tab 'TabAssistant'
        $clickMs = [int]$sw.ElapsedMilliseconds
        $res = Time-UntilInk $rect $target 15000
        $navB = @(Select-String -LiteralPath $diagPath -Pattern 'navigate ' -SimpleMatch -ErrorAction SilentlyContinue).Count
        Say ("round {0}: click took {1} ms, paint after {2} ms (ink {3}%), navigations delta {4}" -f $round, $clickMs, $res[0], [math]::Round($res[1], 2), ($navB - $navA))
    }

    # provider switch cost (same single WebView2 -> real navigation)
    foreach ($chip in @('ChipKimi', 'ChipDeepSeek')) {
        $navA = @(Select-String -LiteralPath $diagPath -Pattern 'navigate ' -SimpleMatch -ErrorAction SilentlyContinue).Count
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Click-Tab $chip
        $res = Time-UntilInk $rect $target 25000
        $navB = @(Select-String -LiteralPath $diagPath -Pattern 'navigate ' -SimpleMatch -ErrorAction SilentlyContinue).Count
        Say ("switch {0}: first paint after {1} ms (ink {2}%), navigations delta {3}" -f $chip, $res[0], [math]::Round($res[1], 2), ($navB - $navA))
        Start-Sleep -Milliseconds 2500
    }

    Say '=== done ==='
}
catch {
    Say ('ERROR: ' + $_.Exception.Message)
}
finally {
    Flush
    Stop-App
    Restore-State
    Start-App | Out-Null
    Say 'app restarted'
    Flush
}
