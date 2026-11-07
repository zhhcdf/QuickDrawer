# Diagnostic probe (2026-10-29): does leaving/returning to the assistant page
# reload the web page?  Measures NavigationStarting hits in diag.log and the
# time until the page repaints after switching back.
# ASCII only; paths derive from $PSScriptRoot.

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_helpers.ps1')
$resultPath = Join-Path $PSScriptRoot 'reentry-result.txt'

function Count-Diag([string]$pattern) {
    if (-not (Test-Path -LiteralPath $diagPath)) { return 0 }
    return @(Select-String -LiteralPath $diagPath -Pattern $pattern -SimpleMatch -ErrorAction SilentlyContinue).Count
}

function Last-DiagLine {
    if (-not (Test-Path -LiteralPath $diagPath)) { return '' }
    return (Get-Content -LiteralPath $diagPath -Tail 1)
}

try {
    Say '=== reentry probe ==='
    Backup-State

    $app = Get-App
    if (-not $app) {
        Start-App
        Start-Sleep -Milliseconds 1800
        $app = Get-App
    }
    if (-not $app) { Say 'FAIL: app did not start'; Flush; exit 1 }

    Ensure-DrawerOpen | Out-Null
    $drawer = Get-DrawerWindow
    if (-not $drawer) { Say 'FAIL: drawer window not found'; Flush; exit 1 }

    $cfg = Read-Config
    Say ("dock width = {0}  pinPanel = {1}" -f $cfg.dock.width, $cfg.dock.pinPanel)
    if ($cfg.dock.pinPanel -eq $true) {
        $pin = Find-Ctl $drawer 'PinPanel'
        if ($pin) { Click-El $pin; Start-Sleep -Milliseconds 600; Say 'unpinned panel (so auto-hide does not interfere)' }
    }

    # --- first entry ---
    $navBefore = Count-Diag 'navigate '
    Click-Tab 'TabAssistant'
    $shown = Wait-Diag 'page shown (provider=' 20000
    Say ("first entry: page shown = {0}" -f $shown)

    $vr = $null
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 250
        $v = Find-Ctl (Get-DrawerWindow) 'AssistantView'
        if ($v) { $r = $v.Current.BoundingRectangle; if ($r.Width -gt 100 -and $r.Height -gt 100) { $vr = $r; break } }
    }
    if (-not $vr) { Say 'FAIL: assistant view never appeared'; Flush; exit 1 }
    $rect = [pscustomobject]@{ X = [int]$vr.X; Y = [int]$vr.Y; Width = [int]$vr.Width; Height = [int]$vr.Height }
    Say ("view rect = {0},{1} {2}x{3}" -f $rect.X, $rect.Y, $rect.Width, $rect.Height)

    # wait for real content (ink ratio > 0.5%)
    $baseline = 0.0
    $t0 = Get-Date
    for ($i = 0; $i -lt 60; $i++) {
        $st = Get-InkStats $rect
        if ($st -and $st.Ink -gt 0.5) { $baseline = $st.Ink; break }
        Start-Sleep -Milliseconds 250
    }
    $loadMs = [int]((Get-Date) - $t0).TotalMilliseconds
    $navAfterFirst = Count-Diag 'navigate '
    Say ("first paint after {0} ms, ink = {1}%  navigations = {2} (delta {3})" -f $loadMs, $baseline, $navAfterFirst, ($navAfterFirst - $navBefore))

    # --- leave and return, twice ---
    for ($round = 1; $round -le 2; $round++) {
        $navA = Count-Diag 'navigate '
        Click-Tab 'TabNotes'
        Start-Sleep -Milliseconds 1500
        $notesRect = $null
        $nl = Find-Ctl (Get-DrawerWindow) 'NotesList'
        if ($nl) { $nr = $nl.Current.BoundingRectangle; $notesRect = [pscustomobject]@{ X = [int]$nr.X; Y = [int]$nr.Y; Width = [int]$nr.Width; Height = [int]$nr.Height } }
        $notesInk = if ($notesRect) { (Get-InkStats $notesRect).Ink } else { -1 }
        Say ("round {0}: left page, notes ink = {1}%" -f $round, $notesInk)

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Click-Tab 'TabAssistant'
        $paintMs = -1
        for ($i = 0; $i -lt 60; $i++) {
            $st2 = Get-InkStats $rect
            if ($st2 -and $st2.Ink -gt [math]::Max(0.5, $baseline * 0.5)) { $paintMs = [int]$sw.ElapsedMilliseconds; break }
            Start-Sleep -Milliseconds 100
        }
        $sw.Stop()
        $navB = Count-Diag 'navigate '
        Say ("round {0}: back after {1} ms, ink threshold reached at {2} ms, navigations delta = {3}" -f $round, [int]$sw.ElapsedMilliseconds, $paintMs, ($navB - $navA))
        Say ("round {0}: last diag line = {1}" -f $round, (Last-DiagLine))
    }

    # --- leave via auto-hide (panel closed) then reopen ---
    $navA2 = Count-Diag 'navigate '
    Click-Tab 'TabNotes'
    [U4]::MoveTo(120, 900)
    Start-Sleep -Milliseconds 3600
    $hidden = -not (Get-DrawerRectNow)
    Say ("auto-hide closed the panel = {0}" -f $hidden)
    [U4]::HotkeyWinAltN()
    for ($i = 0; $i -lt 20; $i++) { Start-Sleep -Milliseconds 200; if (Get-DrawerRectNow) { break } }
    $drawer2 = Get-DrawerWindow
    if ($drawer2) { Click-Tab 'TabAssistant' } else { Say 'panel did not reopen' }
    Start-Sleep -Milliseconds 2500
    $navB2 = Count-Diag 'navigate '
    Say ("after reopen: navigations delta = {0}" -f ($navB2 - $navA2))

    Say '=== done ==='
}
catch {
    Say ('ERROR: ' + $_.Exception.Message)
    Say ($_.ScriptStackTrace)
}
finally {
    Flush
    Stop-App
    Restore-State
    Start-App | Out-Null
    Say 'app restarted'
    Flush
}
