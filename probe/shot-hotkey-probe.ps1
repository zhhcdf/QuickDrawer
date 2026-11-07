# Verification for the 2026-11-01 (seventh) change: the screenshot feature got
# its own global hotkey, separate from the toggle hotkey.
#
#   A) startup registers the shot hotkey and logs it;
#   B) pressing it really opens the frame overlay and tags the log with the
#      "hotkey" source;
#   C) the settings page shows it, and the "off" button clears it from the
#      config and stops registering it;
#   D) the two hotkeys may not share one combination.
#
# ASCII only; paths derive from $PSScriptRoot.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '_helpers.ps1')

$AE = [System.Windows.Automation.AutomationElement]
$CTS = [System.Windows.Automation.TreeScope]
$CTL = [System.Windows.Automation.ControlType]

$script:fail = 0

# FindWindowW(null, title) also matches a hidden window (appendix D #161): Hide()
# only flips SW_HIDE and the HWND stays around, so title lookup says "present"
# long after the overlay is gone. Visibility has to be asked explicitly.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Vis {
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr h);
}
'@

function Test-VisibleTitle([string]$title) {
    $h = [U4]::FindByTitle($title)
    if ($h -eq [IntPtr]::Zero) { return $false }
    return [Vis]::IsWindowVisible($h)
}

# Adding a second global hotkey to a process is invisible from the outside, so
# the product's own log is the only evidence that it happened at all.
function Get-DiagLines {
    if (-not (Test-Path -LiteralPath $diagPath)) { return @() }
    return @(Get-Content -LiteralPath $diagPath -Encoding UTF8)
}

# _helpers.ps1 Get-DrawerWindow filters on a 380..430 px width (appendix D
# #141/#156); find the drawer by process id and height instead.
function Get-DrawerAny {
    $p = Get-Process -Name QuickDrawer -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $p) { return $null }
    $cond = New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $p.Id)
    $wins = @($AE::RootElement.FindAll($CTS::Children, $cond))
    foreach ($w in $wins) {
        $r = $w.Current.BoundingRectangle
        if ($r.Height -gt 500) { return $w }
    }
    return $null
}

# The drawer is considered usable only when it is both in UIA and actually on
# screen: a collapsed panel may still leave a window behind at Left > screen
# width (the panel is moved off screen, not destroyed).
function Get-DrawerOnScreen {
    $w = Get-DrawerAny
    if ($null -eq $w) { return $null }
    $r = $w.Current.BoundingRectangle
    if ($r.Width -lt 100) { return $null }
    if ($r.X -gt 1900) { return $null }
    return $w
}

# An owned window shows up as a descendant of the owner, not as a root child.
function Wait-SettingsWin([int]$timeoutMs) {
    $drawer = Get-DrawerAny
    if ($null -eq $drawer) { return $null }
    $cond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CTL::Window)
    $deadline = (Get-Date).AddMilliseconds($timeoutMs)
    while ((Get-Date) -lt $deadline) {
        $wins = @($drawer.FindAll($CTS::Descendants, $cond))
        foreach ($w in $wins) {
            $r = $w.Current.BoundingRectangle
            if ($r.Width -gt 400 -and $r.Width -lt 600 -and $r.Height -gt 400) { return $w }
        }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

function Get-AppWins {
    $p = Get-Process -Name QuickDrawer -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $p) { return @() }
    $cond = New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $p.Id)
    return @($AE::RootElement.FindAll($CTS::Children, $cond))
}

function Find-AnyById($root, [string]$id) {
    $el = Find-ById $root $id
    if ($null -eq $el) { $el = Find-By-Name $root $id }
    return $el
}

function Open-Settings {
    # Do NOT try to revive a collapsed panel with the toggle hotkey: the panel
    # auto-collapses ~450 ms after the pointer leaves it, so "toggle then sleep"
    # races the watcher and the drawer is gone again by the next line (diag:
    # "auto-hidden after 502ms outside the panel"). Restart the app instead --
    # it always comes up with the panel open and Start-App parks the pointer
    # inside it, which keeps the auto-hide watch quiet.
    if ($null -eq (Get-DrawerOnScreen)) {
        # Both of these print/return objects; swallow them, otherwise they end
        # up in this function's return value and the caller gets a Process
        # instead of the settings window.
        Stop-App | Out-Null
        Start-Sleep -Milliseconds 400
        Start-App | Out-Null
        Start-Sleep -Milliseconds 600
    }
    $opened = $false
    for ($try = 0; $try -lt 10; $try++) {
        if ($null -ne (Get-DrawerOnScreen)) { $opened = $true; break }
        Start-Sleep -Milliseconds 300
    }
    if (-not $opened) { throw 'drawer window did not come back on screen' }

    [U4]::MoveTo(1780, 400)
    Start-Sleep -Milliseconds 500

    $drawer = Get-DrawerOnScreen
    if ($null -eq $drawer) { throw 'drawer window vanished right after the animation' }

    # The panel is a fresh UIA subtree after every show; its children show up a
    # beat later than the window itself. Retry instead of throwing on the first
    # miss, and dump what is actually there when the retries run out.
    $btn = $null
    for ($try = 0; $try -lt 15; $try++) {
        $btn = Find-AnyById $drawer 'MenuButton'
        if ($null -ne $btn) { break }
        Start-Sleep -Milliseconds 300
        $drawer = Get-DrawerOnScreen
        if ($null -eq $drawer) { break }
    }
    if ($null -eq $btn) {
        $r = $drawer.Current.BoundingRectangle
        Say ("drawer rect={0},{1} {2}x{3} name='{4}' class='{5}'" -f `
            [int]$r.X, [int]$r.Y, [int]$r.Width, [int]$r.Height, $drawer.Current.Name, $drawer.Current.ClassName)
        $ids = @()
        foreach ($d in @($drawer.FindAll($CTS::Descendants, [System.Windows.Automation.Condition]::TrueCondition))) {
            $aid = $d.Current.AutomationId
            if ($aid) { $ids += $aid }
            if ($ids.Count -ge 30) { break }
        }
        Say ("drawer automation ids: {0}" -f ($ids -join ', '))
        throw 'menu button missing'
    }
    Click-El $btn 0.5
    Start-Sleep -Milliseconds 700

    $items = @()
    for ($try = 0; $try -lt 20; $try++) {
        Start-Sleep -Milliseconds 200
        $items = @()
        foreach ($win in Get-AppWins) {
            $found = Find-All-Of $win $CTL::MenuItem
            if (@($found).Count -gt 0) { $items += @($found) }
        }
        if (@($items).Count -ge 4) { break }
    }
    if (@($items).Count -lt 4) { throw 'app menu did not open' }

    Click-El @($items)[0] 0.5
    return (Wait-SettingsWin 8000)
}

function Close-Window($win) {
    $pat = $null
    if ($win.TryGetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern, [ref]$pat)) {
        $pat.Close()
    }
}

# A real global hotkey can only be triggered by real key strokes: RegisterHotKey
# is fed by the OS, not by anything we can call from inside the process.
function Send-Hotkey([uint32]$vk) {
    [U4]::KeyDown(0x5B)   # WIN
    Start-Sleep -Milliseconds 60
    [U4]::KeyDown(0x12)   # ALT
    Start-Sleep -Milliseconds 60
    [U4]::KeyTap($vk)
    Start-Sleep -Milliseconds 60
    [U4]::KeyUp(0x12)
    [U4]::KeyUp(0x5B)
}

function Wait-Title([string]$title, [int]$timeoutMs) {
    $deadline = (Get-Date).AddMilliseconds($timeoutMs)
    while ((Get-Date) -lt $deadline) {
        if (Test-VisibleTitle $title) { return $true }
        Start-Sleep -Milliseconds 120
    }
    return $false
}

function Wait-TitleGone([string]$title, [int]$timeoutMs) {
    $deadline = (Get-Date).AddMilliseconds($timeoutMs)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-VisibleTitle $title)) { return $true }
        Start-Sleep -Milliseconds 120
    }
    return $false
}

function Read-ConfigRaw {
    return (Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json)
}

try {
    Backup-State
    Stop-App
    Start-Sleep -Milliseconds 400

    $diagBefore = @(Get-DiagLines).Count
    Start-App
    Start-Sleep -Milliseconds 1800

    # ---------- A) registration at startup ----------
    # The section is only written to disk once something is saved: a config that
    # predates the feature keeps its old keys until then, while the in-memory
    # default still registers the hotkey. So the log, not the file, is the
    # evidence for A; the file is checked later, after the settings page saves.
    $diag1 = @(Get-DiagLines | Select-Object -Skip $diagBefore)
    $reg = $diag1 | Select-String -Pattern 'shot hotkey registered' -SimpleMatch | Select-Object -Last 1
    Say ("diag: {0}" -f $(if ($reg) { $reg.Line.Trim() } else { '(no shot hotkey registration line)' }))
    Check 'startup registers the shot hotkey' ($null -ne $reg)
    if ($null -ne $reg) { Check 'the registered combo ends with S' ($reg.Line.Trim().EndsWith('0x53')) }

    # ---------- B) pressing it opens the frame overlay ----------
    $mark = @(Get-DiagLines).Count
    Send-Hotkey 0x53
    $overlay = Wait-Title 'QuickDrawer Screenshot' 6000
    Say ("shot overlay opened by the hotkey = {0}" -f $overlay)
    Check 'the shot hotkey opens the frame overlay' $overlay

    if ($overlay) {
        # Framing a real rectangle is stronger evidence than pressing Escape: it
        # proves the hotkey path carries all the way to the popup, not merely
        # that a window appeared. A fixed sleep before the drag is fatal here
        # (no hover, 2 s auto-hide), so move over the overlay first.
        [U4]::MoveTo(400, 300)
        Start-Sleep -Milliseconds 150
        [U4]::LeftDown()
        Start-Sleep -Milliseconds 100
        [U4]::MoveTo(700, 460)
        Start-Sleep -Milliseconds 120
        [U4]::LeftUp()

        Check 'the overlay closes after the drag' (Wait-TitleGone 'QuickDrawer Screenshot' 5000)

        $popupShown = $false
        for ($try = 0; $try -lt 40; $try++) {
            if (Test-VisibleTitle 'QuickDrawer Selection') { $popupShown = $true; break }
            Start-Sleep -Milliseconds 100
        }
        Say ("selection popup shown by the hotkey path = {0}" -f $popupShown)
        Check 'the hotkey path reaches the popup' $popupShown

        Start-Sleep -Milliseconds 300
        $diag2 = @(Get-DiagLines | Select-Object -Skip $mark)
        $ready = $diag2 | Select-String -Pattern 'hotkey: ready ' -SimpleMatch | Select-Object -Last 1
        Say ("diag: {0}" -f $(if ($ready) { $ready.Line.Trim() } else { '(no hotkey ready line)' }))
        Check 'the hotkey path tags its log with the source' ($null -ne $ready)

        # Clear the popup before exercising the toggle hotkey.
        [U4]::KeyTap(0x1B)
        Start-Sleep -Milliseconds 500

        # The toggle hotkey must still do its own job: two ids, two behaviours.
        # Give the panel time to settle first: showing it animates for 180 ms.
        Start-Sleep -Milliseconds 1200
        $mark2 = @(Get-DiagLines).Count
        [U4]::HotkeyWinAltN()
        Start-Sleep -Milliseconds 1500
        $diag3 = @(Get-DiagLines | Select-Object -Skip $mark2)
        $toggled = $diag3 | Select-String -Pattern 'drawer' -SimpleMatch | Select-Object -First 1
        Say ("toggle after shot = {0}" -f $(if ($toggled) { $toggled.Line.Trim() } else { '(no drawer line)' }))
        Check 'the toggle hotkey still works after the shot one' ($null -ne $toggled)
    }

    # ---------- C) the settings page ----------
    $win = Open-Settings
    Check 'settings window opened' ($null -ne $win)

    if ($null -ne $win) {
        $shotText = Find-AnyById $win 'ShotHotkeyText'
        $shotCapture = Find-AnyById $win 'ShotHotkeyCapture'
        $shotClear = Find-AnyById $win 'ShotHotkeyClear'

        Check 'settings exposes the shot hotkey value' ($null -ne $shotText)
        Check 'settings exposes the shot hotkey capture button' ($null -ne $shotCapture)
        Check 'settings exposes the shot hotkey off button' ($null -ne $shotClear)

        if ($null -ne $shotText) {
            $label = $shotText.Current.Name
            Say ("shot hotkey label = '{0}'" -f $label)
            Check 'the label shows the configured combo' ($label -like '*S*')
        }

        # Turning it off must clear the config and stop the registration.
        if ($null -ne $shotClear) {
            $mark3 = @(Get-DiagLines).Count
            Click-El $shotClear 0.5
            Start-Sleep -Milliseconds 800

            $cfg2 = Read-ConfigRaw
            Say ("config shotHotkey.key after off = '{0}'" -f $cfg2.shotHotkey.key)
            Check 'the off button clears the key in the config' ([string]::IsNullOrWhiteSpace($cfg2.shotHotkey.key))

            $diag4 = @(Get-DiagLines | Select-Object -Skip $mark3)
            $off = $diag4 | Select-String -Pattern 'shot hotkey disabled by config' -SimpleMatch | Select-Object -Last 1
            Say ("diag: {0}" -f $(if ($off) { $off.Line.Trim() } else { '(no disabled line)' }))
            Check 'the off button stops the registration' ($null -ne $off)

            if ($null -ne $shotText) {
                Start-Sleep -Milliseconds 200
                $label2 = $shotText.Current.Name
                Say ("shot hotkey label after off = '{0}'" -f $label2)
                Check 'the label reports the hotkey as off' ($label2.Length -gt 0 -and $label2 -ne $label)
            }

            # And the key really is dead now.
            $dead = $true
            Send-Hotkey 0x53
            if (Wait-Title 'QuickDrawer Screenshot' 2500) {
                $dead = $false
                [U4]::KeyTap(0x1B)
                Wait-TitleGone 'QuickDrawer Screenshot' 3000 | Out-Null
            }
            Check 'the shot hotkey no longer fires once it is off' $dead
        }

        Close-Window $win
        Start-Sleep -Milliseconds 600
    }
}
catch {
    Say ("ERROR: {0}" -f $_.Exception.Message)
    $script:fail++
}
finally {
    Stop-App
    Start-Sleep -Milliseconds 300
    Restore-State
    Start-App
    Say ("RESULT: {0} ({1} failed assertions)" -f $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' }), $script:fail)
    Flush
}
