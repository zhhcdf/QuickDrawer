# Verify the 2026-11-01 (fourth) request: the selection popup must
#   1) hide itself when the pointer never docks on it within 2 seconds,
#   2) stay visible while the pointer is docked on it,
#   3) hide again as soon as the pointer leaves.
# ASCII only; paths derive from $PSScriptRoot.

. (Join-Path $PSScriptRoot '_helpers.ps1')

# _helpers.ps1 keeps IsWindowVisible private, so declare a tiny public wrapper.
# FindWindowW also matches HIDDEN windows, so "window exists" is NOT "window
# visible" -- every assertion below goes through this helper.
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class PopupVis {
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
}
"@

$token = 'QD-AH-' + (Get-Date -Format 'HHmmss')
$sourceScript = Join-Path $PSScriptRoot 'sel-source.ps1'
$popupTitle = 'QuickDrawer Selection'

$script:fail = 0
$script:sourceProc = $null

function Get-DiagCount {
    if (-not (Test-Path -LiteralPath $diagPath)) { return 0 }
    return @(Get-Content -LiteralPath $diagPath -ErrorAction SilentlyContinue).Count
}

function Get-DiagSince([int]$from) {
    if (-not (Test-Path -LiteralPath $diagPath)) { return @() }
    $all = @(Get-Content -LiteralPath $diagPath -ErrorAction SilentlyContinue)
    if ($from -ge $all.Count) { return @() }
    return @($all[$from..($all.Count - 1)])
}

function Test-PopupVisible {
    $h = [U4]::FindByTitle($popupTitle)
    if ($h -eq [IntPtr]::Zero) { return $false }
    return [PopupVis]::IsWindowVisible($h)
}

function Wait-PopupVisible([int]$timeoutMs) {
    $deadline = (Get-Date).AddMilliseconds($timeoutMs)
    while ((Get-Date) -lt $deadline) {
        if (Test-PopupVisible) { return $true }
        Start-Sleep -Milliseconds 40
    }
    return $false
}

function Wait-PopupHidden([int]$timeoutMs) {
    $deadline = (Get-Date).AddMilliseconds($timeoutMs)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-PopupVisible)) { return $true }
        Start-Sleep -Milliseconds 40
    }
    return $false
}

function Get-SourceEdit([IntPtr]$hwnd) {
    $win = $AE::FromHandle($hwnd)
    if ($null -eq $win) { return $null }
    $hit = Find-All-Of $win $CTL::Edit | Select-Object -First 1
    if ($null -ne $hit) { return $hit }
    $all = $win.FindAll($CTS::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($el in $all) {
        if ($el.Current.ClassName -like '*EDIT*') { return $el }
    }
    return $null
}

function Invoke-DragSelect([int]$ax1, [int]$ay1, [int]$ax2) {
    [U4]::MoveTo($ax1, $ay1)
    Start-Sleep -Milliseconds 150
    [U4]::LeftDown()
    Start-Sleep -Milliseconds 90
    for ($i = 1; $i -le 12; $i++) {
        $x = [int]($ax1 + (($ax2 - $ax1) * $i / 12))
        [U4]::MoveTo($x, $ay1)
        Start-Sleep -Milliseconds 25
    }
    [U4]::LeftUp()
}

function Stop-Source {
    if ($script:sourceProc) {
        Stop-Process -Id $script:sourceProc.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 400
        $script:sourceProc = $null
    }
}

try {
    Backup-State
    Stop-App
    Start-App | Out-Null
    if (-not (Ensure-DrawerOpen)) { throw 'drawer did not open' }
    $dr = Get-DrawerRectNow
    Say ("drawer rect={0}" -f $(if ($dr) { ($dr -join ',') } else { 'none' }))

    $script:sourceProc = Start-Process -FilePath (Get-Process -Id $PID).Path `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $sourceScript, '-Text', $token) -PassThru

    $dhwnd = [IntPtr]::Zero
    for ($w = 0; $w -lt 30; $w++) {
        Start-Sleep -Milliseconds 200
        $dhwnd = [U4]::FindByTitle('QD Sel Source')
        if ($dhwnd -ne [IntPtr]::Zero) { break }
    }
    Check 'source window found' ($dhwnd -ne [IntPtr]::Zero)
    if ($dhwnd -eq [IntPtr]::Zero) { throw 'source window not found' }
    [void][U4]::SetForegroundWindow($dhwnd)
    Start-Sleep -Milliseconds 600

    $edit = Get-SourceEdit $dhwnd
    if ($null -eq $edit) { throw 'source edit not found' }
    $er = $edit.Current.BoundingRectangle
    Say ("edit rect={0},{1} {2}x{3}" -f [int]$er.X, [int]$er.Y, [int]$er.Width, [int]$er.Height)

    # ---------------------------------------------------------- round 1
    # Drag and then leave the pointer exactly where the drag ended: the popup
    # opens 8px right / 12px below the cursor, so the cursor stays outside it.
    $mark1 = Get-DiagCount
    Invoke-DragSelect ([int]($er.X + 6)) ([int]($er.Y + 12)) ([int]($er.X + 190))
    $shown = Wait-PopupVisible 4000
    Check 'popup appeared after the drag' $shown
    if (-not $shown) { throw 'popup did not appear' }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Milliseconds 1000
    $stillAt1s = Test-PopupVisible
    Check 'popup still visible 1.0s after showing (deadline is 2s)' $stillAt1s
    Say ("pointer left at the drag end, popup visible at +{0} ms" -f $sw.ElapsedMilliseconds)

    $hidden = Wait-PopupHidden 3000
    $hideMs = $sw.ElapsedMilliseconds
    Say ("popup auto hidden after {0} ms" -f $hideMs)
    Check 'popup hid itself when the pointer never docked' $hidden
    Check 'the hide happened around the 2s deadline, not instantly' ($hideMs -ge 1700 -and $hideMs -le 3000)

    $lines1 = Get-DiagSince $mark1
    $noHover = @($lines1 | Where-Object { $_ -like '*popup auto hidden (no hover within 2s)*' })
    foreach ($l in $noHover) { Say ("diag: {0}" -f $l) }
    Check 'diag records the no-hover auto hide' ($noHover.Count -ge 1)

    # ---------------------------------------------------------- round 2
    [U4]::MoveTo([int]($er.X + 6), [int]($er.Y + 12))
    Start-Sleep -Milliseconds 200
    $mark2 = Get-DiagCount
    Invoke-DragSelect ([int]($er.X + 6)) ([int]($er.Y + 12)) ([int]($er.X + 190))
    $shown2 = Wait-PopupVisible 4000
    Check 'popup appeared again on the second drag' $shown2
    if (-not $shown2) { throw 'popup did not reappear' }

    $ph = [U4]::FindByTitle($popupTitle)
    $pr = [U4]::GetRect($ph)
    $cx = [int](($pr[0] + $pr[2]) / 2)
    $cy = [int](($pr[1] + $pr[3]) / 2)
    Say ("popup rect={0},{1},{2},{3} docking pointer at {4},{5}" -f $pr[0], $pr[1], $pr[2], $pr[3], $cx, $cy)
    [U4]::MoveTo($cx, $cy)

    # 4s: twice the deadline. A broken "hover" rule would have hidden it at 2s.
    Start-Sleep -Milliseconds 4000
    $docked = Test-PopupVisible
    Check 'popup stays visible while the pointer is docked (4s)' $docked
    $dockLines = Get-DiagSince $mark2
    $trimWhileDocked = @($dockLines | Where-Object { $_ -like '*popup auto hidden*' })
    foreach ($l in $trimWhileDocked) { Say ("diag while docked: {0}" -f $l) }
    Check 'no auto hide while the pointer is docked' ($trimWhileDocked.Count -eq 0)

    # Leave: the next 80ms tick must collapse it.
    [U4]::MoveTo(300, 500)
    $leftOk = Wait-PopupHidden 2000
    Check 'popup hides as soon as the pointer leaves' $leftOk
    $lines3 = Get-DiagSince $mark2
    $byLeave = @($lines3 | Where-Object { $_ -like '*popup auto hidden (pointer left)*' })
    foreach ($l in $byLeave) { Say ("diag: {0}" -f $l) }
    Check 'diag records the pointer-left auto hide' ($byLeave.Count -ge 1)
}
finally {
    Stop-Source
    Stop-App
    Restore-State
    Say ("RESULT: {0} ({1} failed assertions)" -f $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' }), $script:fail)
    Flush
}
