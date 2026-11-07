# chip-accent-probe.ps1
#
# Verifies two fixes from the 2026-11-01 request:
#   1. The assistant provider chips mark the active one with light-blue text
#      and NO background fill (it used to be a grey rounded box).
#   2. The settings window shows the real numeric values on open; previously
#      the three number labels were hardcoded in XAML (380 / 120 / 600) and
#      never refreshed, so they always claimed the default no matter what
#      was actually configured.
#
# ASCII only: Windows PowerShell 5.1 reads BOM-less scripts as ANSI, so any
# Chinese literal here would corrupt the parse.

param(
    [string]$Exe = '',
    [int]$WorkWidth = 460
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '_helpers.ps1')

Add-Type -AssemblyName System.Drawing

$AE = [System.Windows.Automation.AutomationElement]
$CTS = [System.Windows.Automation.TreeScope]
$CTL = [System.Windows.Automation.ControlType]
$trueCond = [System.Windows.Automation.Condition]::TrueCondition

# ---------- pixel helpers ----------

function Get-RectShot([int]$x, [int]$y, [int]$w, [int]$h) {
    if ($w -le 0 -or $h -le 0) { return $null }
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size($w, $h)))
    $g.Dispose()
    return $bmp
}

# Returns the most blue-leaning pixel in the rect: {DR, DB, R, G, B}.
# Grey text (TextSecondary #3D3D44) has DB-DR around 7; the accent blue
# (#2F7BD8) reaches 169, so any antialiased pixel of it stands far apart.
function Get-BluestPixel($bmp) {
    $best = $null
    $bestScore = -999
    for ($py = 0; $py -lt $bmp.Height; $py++) {
        for ($px = 0; $px -lt $bmp.Width; $px++) {
            $c = $bmp.GetPixel($px, $py)
            $score = $c.B - $c.R
            if ($score -gt $bestScore) {
                $bestScore = $score
                $best = @{ DR = ($c.B - $c.R); DB = $c.B; R = $c.R; G = $c.G; B = $c.B }
            }
        }
    }
    return $best
}

# Mode colour of the rect, 2px steps: tells "is there a fill behind the text".
function Get-ModeColor($bmp) {
    $counts = @{}
    for ($py = 0; $py -lt $bmp.Height; $py += 2) {
        for ($px = 0; $px -lt $bmp.Width; $px += 2) {
            $c = $bmp.GetPixel($px, $py)
            $k = '{0},{1},{2}' -f $c.R, $c.G, $c.B
            if ($counts.ContainsKey($k)) { $counts[$k] = $counts[$k] + 1 }
            else { $counts[$k] = 1 }
        }
    }
    $top = $counts.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 1
    $parts = $top.Key -split ','
    return @([int]$parts[0], [int]$parts[1], [int]$parts[2])
}

function Set-SliderValue($el, [double]$v) {
    $pat = $null
    if (-not $el.TryGetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern, [ref]$pat)) {
        return $false
    }
    $pat.SetValue($v)
    return $true
}

# Get-DrawerWindow() from _helpers.ps1 filters on a 380..430 px width, which
# stops matching the moment this probe changes dock.width. Find the drawer by
# process id and height instead (appendix D #141: assert the state, not a
# stale shape).
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

# MainWindowHandle only ever names ONE window, and the WPF ContextMenu lives in
# its own popup window, so enumerating by process id is the only way to see the
# menu items here.
function Get-AppWins {
    $p = Get-Process -Name QuickDrawer -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $p) { return @() }
    $cond = New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $p.Id)
    return @($AE::RootElement.FindAll($CTS::Children, $cond))
}

function Open-Settings {
    Ensure-DrawerOpen | Out-Null
    Start-Sleep -Milliseconds 300
    $drawer = Get-DrawerAny
    if ($null -eq $drawer) { throw 'drawer window not found in UIA' }
    $menu = Find-ById $drawer 'MenuButton'
    if ($null -eq $menu) { $menu = Find-By-Name $drawer 'MenuButton' }
    if ($null -eq $menu) { throw 'menu button missing' }
    Click-El $menu 0.5
    Start-Sleep -Milliseconds 700

    $menus = @()
    for ($try = 0; $try -lt 20; $try++) {
        Start-Sleep -Milliseconds 200
        $menus = @()
        foreach ($win in Get-AppWins) {
            $found = Find-All-Of $win $CTL::MenuItem
            if (@($found).Count -gt 0) { $menus += @($found) }
        }
        if (@($menus).Count -ge 4) { break }
    }
    Say ("menu items = {0}" -f @($menus).Count)
    if (@($menus).Count -lt 1) { throw 'context menu did not open' }
    Click-El @($menus)[0] 0.5
    return (Wait-SettingsWin 8000)
}

function Close-Window($win) {
    $pat = $null
    if ($win.TryGetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern, [ref]$pat)) {
        $pat.Close()
        return $true
    }
    return $false
}

function Get-TextOf($root, [string]$id) {
    $el = Find-ById $root $id
    if ($null -eq $el) { $el = Find-By-Name $root $id }
    if ($null -eq $el) { return $null }
    return $el.Current.Name
}

# ---------- run ----------

Say '=== chip accent + settings value labels ==='
if ($Exe -ne '') { $script:appExe = $Exe }

Backup-State
$opened = $false
try {
    Stop-App
    Start-Sleep -Milliseconds 400
    Start-App
    Start-Sleep -Milliseconds 1200
    Ensure-DrawerOpen | Out-Null
    Start-Sleep -Milliseconds 600

    $drawer = Get-DrawerWindow
    if ($null -eq $drawer) { throw 'drawer window not found' }

    $cfg = Read-Config
    Say ("config dock.width={0} dock.handle.heightPx={1} dock.handle.collapseDelayMs={2}" -f `
            $cfg.dock.width, $cfg.dock.handle.heightPx, $cfg.dock.handle.collapseDelayMs)

    # --- part 1: provider chips ---
    $tab = Find-ById $drawer 'TabAssistant'
    if ($null -eq $tab) { $tab = Find-By-Name $drawer 'TabAssistant' }
    Check 'assistant tab found' ($null -ne $tab)
    Click-El $tab 0.5
    Start-Sleep -Milliseconds 900

    $dsChip = Find-ById $drawer 'ChipDeepSeek'
    if ($null -eq $dsChip) { $dsChip = Find-By-Name $drawer 'ChipDeepSeek' }
    $qmChip = Find-ById $drawer 'ChipQwen'
    if ($null -eq $qmChip) { $qmChip = Find-By-Name $drawer 'ChipQwen' }
    $kmChip = Find-ById $drawer 'ChipKimi'
    if ($null -eq $kmChip) { $kmChip = Find-By-Name $drawer 'ChipKimi' }
    Check 'deepseek chip found' ($null -ne $dsChip)
    Check 'qwen chip found' ($null -ne $qmChip)
    Check 'kimi chip found' ($null -ne $kmChip)
    if ($null -eq $dsChip -or $null -eq $kmChip) { throw 'chips missing' }

    $dr = Get-DrawerRect
    # Park the cursor well away from the chip row: hover would paint
    # ControlFill and fake a background box. Also keeps the drawer open.
    $parkX = [int]($dr.X + 30)
    $parkY = [int]($dr.Y + 220)

    # Differential, not absolute: the panel is 96% opaque, so its colour
    # drifts by a few units between two x positions as different desktop
    # content shows through (appendix D #124). Comparing the SAME chip
    # unchecked vs checked cancels that drift out.
    Click-El $kmChip 0.5
    Start-Sleep -Milliseconds 700
    [U4]::MoveTo($parkX, $parkY)
    Start-Sleep -Milliseconds 500

    $dsRect = $dsChip.Current.BoundingRectangle
    Say ("chip deepseek rect={0},{1} {2}x{3}" -f [int]$dsRect.X, [int]$dsRect.Y, [int]$dsRect.Width, [int]$dsRect.Height)

    $offBmp = Get-RectShot ([int]$dsRect.X) ([int]$dsRect.Y) ([int]$dsRect.Width) ([int]$dsRect.Height)
    $offMode = Get-ModeColor $offBmp
    $offBlue = Get-BluestPixel $offBmp
    $offBmp.Dispose()
    Say ("deepseek UNCHECKED mode={0},{1},{2} bluest=({3},{4},{5}) B-R={6}" -f `
            $offMode[0], $offMode[1], $offMode[2], $offBlue.R, $offBlue.G, $offBlue.B, $offBlue.DR)

    Click-El $dsChip 0.5
    Start-Sleep -Milliseconds 800
    [U4]::MoveTo($parkX, $parkY)
    Start-Sleep -Milliseconds 500

    $onBmp = Get-RectShot ([int]$dsRect.X) ([int]$dsRect.Y) ([int]$dsRect.Width) ([int]$dsRect.Height)
    $onMode = Get-ModeColor $onBmp
    $onBlue = Get-BluestPixel $onBmp
    $onBmp.Dispose()
    Say ("deepseek CHECKED   mode={0},{1},{2} bluest=({3},{4},{5}) B-R={6}" -f `
            $onMode[0], $onMode[1], $onMode[2], $onBlue.R, $onBlue.G, $onBlue.B, $onBlue.DR)

    # 1a) active chip text is the accent blue
    Check 'checked chip text is blue (B-R >= 40)' ($onBlue.DR -ge 40)
    # 1b) the same chip at rest keeps grey text
    Check 'unchecked chip text is not blue (B-R <= 20)' ($offBlue.DR -le 20)
    # 1c) no background box: checking must not change the fill colour
    $fillDelta = [math]::Abs($onMode[0] - $offMode[0]) + [math]::Abs($onMode[1] - $offMode[1]) + [math]::Abs($onMode[2] - $offMode[2])
    Say ("checked vs unchecked mode delta = {0} (must stay tiny: no fill on check)" -f $fillDelta)
    Check 'checked chip has no background fill (delta <= 6)' ($fillDelta -le 6)

    # 1d) positive control: hovering an unchecked chip DOES paint a fill,
    #     otherwise 1c could pass simply because hover/checked styling died.
    $kmRect = $kmChip.Current.BoundingRectangle
    [U4]::MoveTo([int]($kmRect.X + $kmRect.Width / 2), [int]($kmRect.Y + $kmRect.Height / 2))
    Start-Sleep -Milliseconds 500
    $kmBmp = Get-RectShot ([int]$kmRect.X) ([int]$kmRect.Y) ([int]$kmRect.Width) ([int]$kmRect.Height)
    $kmMode = Get-ModeColor $kmBmp
    $kmBlue = Get-BluestPixel $kmBmp
    $kmBmp.Dispose()
    [U4]::MoveTo($parkX, $parkY)
    Start-Sleep -Milliseconds 300
    $hoverDelta = [math]::Abs($kmMode[0] - $onMode[0]) + [math]::Abs($kmMode[1] - $onMode[1]) + [math]::Abs($kmMode[2] - $onMode[2])
    Say ("hovered kimi mode={0},{1},{2} bluest B-R={3}; hover fill delta vs panel = {4}" -f `
            $kmMode[0], $kmMode[1], $kmMode[2], $kmBlue.DR, $hoverDelta)
    Check 'hover still paints a fill (delta >= 4)' ($hoverDelta -ge 4)

    # pointer already parked off the chip row above

    # --- part 2: settings value labels ---
    $win = Open-Settings
    Check 'settings window opened' ($null -ne $win)
    if ($null -eq $win) { throw 'settings window did not open' }
    $opened = $true

    $wr = $win.Current.BoundingRectangle
    Say ("settings window rect={0},{1} {2}x{3}" -f [int]$wr.X, [int]$wr.Y, [int]$wr.Width, [int]$wr.Height)

    $cfg = Read-Config
    $wLabel = Get-TextOf $win 'WidthText'
    $hLabel = Get-TextOf $win 'HandleHeightText'
    $cLabel = Get-TextOf $win 'CollapseDelayText'
    Say ("labels on open: width='{0}' handle='{1}' delay='{2}'" -f $wLabel, $hLabel, $cLabel)
    Say ("config on open: width={0} handle={1} delay={2}" -f $cfg.dock.width, $cfg.dock.handle.heightPx, $cfg.dock.handle.collapseDelayMs)

    Check 'width label matches config on open' ($wLabel -eq ([string][int]$cfg.dock.width))
    Check 'handle label matches config on open' ($hLabel -eq ([string][int]$cfg.dock.handle.heightPx))
    Check 'delay label matches config on open' ($cLabel -eq ([string][int]$cfg.dock.handle.collapseDelayMs))

    # the reported symptom: after changing the width, reopening still says 380
    $slider = Find-ById $win 'WidthSlider'
    if ($null -eq $slider) { $slider = Find-By-Name $win 'WidthSlider' }
    Check 'width slider found' ($null -ne $slider)
    if ($null -ne $slider) {
        $ok = Set-SliderValue $slider ([double]$WorkWidth)
        Check 'width slider accepts range value' $ok
        Start-Sleep -Milliseconds 600
        $cfg2 = Read-Config
        Say ("config after setting width {0} -> {1}" -f $WorkWidth, $cfg2.dock.width)
        Check 'width change persisted to config' ([int]$cfg2.dock.width -eq $WorkWidth)

        $liveLabel = Get-TextOf $win 'WidthText'
        Say ("width label right after change = '{0}'" -f $liveLabel)
        Check 'width label follows the change immediately' ($liveLabel -eq ([string]$WorkWidth))
    }

    # close and reopen: this is exactly the user's reported path
    Close-Window $win | Out-Null
    $opened = $false
    Start-Sleep -Milliseconds 900

    $win2 = Open-Settings
    Check 'settings window reopened' ($null -ne $win2)
    if ($null -ne $win2) {
        $opened = $true
        $reLabel = Get-TextOf $win2 'WidthText'
        $cfg3 = Read-Config
        Say ("after reopen: label='{0}' config width={1}" -f $reLabel, $cfg3.dock.width)
        Check 'reopened width label is not the stale default' ($reLabel -ne '380')
        Check 'reopened width label matches config' ($reLabel -eq ([string][int]$cfg3.dock.width))
    }
}
catch {
    Say ("ERROR: {0}" -f $_.Exception.Message)
    Check 'no unexpected exception' $false
}
finally {
    try {
        if ($opened) {
            $w = Wait-SettingsWin 1000
            if ($null -ne $w) { Close-Window $w | Out-Null }
        }
    } catch { }
    Start-Sleep -Milliseconds 400
    Stop-App
    Restore-State
    Say ("RESULT: {0} ({1} failed assertions)" -f $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' }), $script:fail)
    Flush
}
