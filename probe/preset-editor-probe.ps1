# Verification for the settings-window preset prompt editor (2026-10-31).
# Opens Settings from the drawer menu, edits the first preset label, adds a
# preset, removes it, and checks config.json plus the popup button list.
# ASCII only; paths derive from $PSScriptRoot.

. (Join-Path $PSScriptRoot '_helpers.ps1')

$script:fail = 0

function Get-DiagLines {
    if (-not (Test-Path -LiteralPath $diagPath)) { return @() }
    return @(Get-Content -LiteralPath $diagPath -ErrorAction SilentlyContinue)
}

function Get-AppWins {
    $p = Get-Process -Name QuickDrawer -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $p) { return @() }
    $cond = New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $p.Id)
    return @($AE::RootElement.FindAll($CTS::Children, $cond))
}

# SettingsWindow.Show() is called on an owner-linked window (Owner = drawer),
# so UIA reports it as a DESCENDANT of the drawer window, not a root child.
# Scanning only root children always missed it (2026-10-31).
function Get-SettingsWin {
    $drawer = Get-DrawerWindow
    if ($null -eq $drawer) { return $null }
    $cond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CTL::Window)
    $wins = @($drawer.FindAll($CTS::Descendants, $cond))
    foreach ($w in $wins) {
        $r = $w.Current.BoundingRectangle
        if ($r.Width -gt 400 -and $r.Width -lt 600) { return $w }
    }
    return $null
}

function Wait-SettingsWin([int]$timeoutMs = 6000) {
    $deadline = (Get-Date).AddMilliseconds($timeoutMs)
    while ((Get-Date) -lt $deadline) {
        $w = Get-SettingsWin
        if ($null -ne $w) { return $w }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

function Read-Presets {
    $cfg = Read-Config
    return @($cfg.assistant.prompts)
}

try {
    Backup-State
    Stop-App
    Start-App | Out-Null
    if (-not (Ensure-DrawerOpen)) { throw 'drawer did not open' }

    $before = Read-Presets
    Say ("presets before = {0}" -f $before.Count)

    # open the settings window through the drawer menu
    $drawer = Get-DrawerWindow
    if ($null -eq $drawer) { throw 'drawer window not found in UIA' }
    $menu = Find-ById $drawer 'MenuButton'
    if ($null -eq $menu) { $menu = Find-By-Name $drawer 'MenuButton' }
    Check 'menu button found' ($null -ne $menu)
    if ($null -eq $menu) { throw 'menu button missing' }
    Click-El $menu 0.5
    Start-Sleep -Milliseconds 700

    # The context menu has no AutomationIds and its headers are Chinese, which
    # this ASCII-only script cannot spell. Click the first MenuItem instead:
    # OpenAppMenu() adds settings / auto-start / about / exit in that order.
    # Wait until all four exist, otherwise an early single hit is clicked.
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
    Check 'context menu opened' (@($menus).Count -ge 1)
    $settingsItem = @($menus)[0]
    Click-El $settingsItem 0.5

    $win = Wait-SettingsWin 8000
    Check 'settings window opened' ($null -ne $win)
    if ($null -eq $win) { throw 'settings window did not open' }
    $r = $win.Current.BoundingRectangle
    Say ("settings window rect={0},{1} {2}x{3}" -f [int]$r.X, [int]$r.Y, [int]$r.Width, [int]$r.Height)

    $list = Find-ById $win 'PresetList'
    if ($null -eq $list) { $list = Find-By-Name $win 'PresetList' }
    Check 'preset list found' ($null -ne $list)

    $labelBox = Find-ById $win 'PresetLabel'
    if ($null -eq $labelBox) { $labelBox = Find-By-Name $win 'PresetLabel' }
    Check 'preset label box found' ($null -ne $labelBox)

    $instrBox = Find-ById $win 'PresetInstruction'
    if ($null -eq $instrBox) { $instrBox = Find-By-Name $win 'PresetInstruction' }
    Check 'preset instruction box found' ($null -ne $instrBox)

    $addBtn = Find-ById $win 'PresetAdd'
    if ($null -eq $addBtn) { $addBtn = Find-By-Name $win 'PresetAdd' }
    Check 'preset add button found' ($null -ne $addBtn)

    $delBtn = Find-ById $win 'PresetRemove'
    if ($null -eq $delBtn) { $delBtn = Find-By-Name $win 'PresetRemove' }
    Check 'preset remove button found' ($null -ne $delBtn)

    if ($null -ne $list) {
        $items = @($list.FindAll($CTS::Children, [System.Windows.Automation.Condition]::TrueCondition))
        $rows = @()
        foreach ($it in $items) {
            $sub = @($it.FindAll($CTS::Descendants, [System.Windows.Automation.Condition]::TrueCondition))
            if ($sub.Count -gt 0) { $rows += $sub[0] }
        }
        if ($rows.Count -eq 0) { $rows = $items }
        Say ("preset list rows = {0}" -f $rows.Count)
        Check 'preset list shows every configured preset' ($rows.Count -eq $before.Count)
    }

    # 1) rename the first preset
    $newLabel = 'QDLabel' + (Get-Date -Format 'HHmmss')
    if ($null -ne $labelBox) {
        try {
            $vp = $labelBox.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
            $vp.SetValue($newLabel)
        } catch {
            Say ("label ValuePattern failed: {0}" -f $_.Exception.Message)
        }
        Start-Sleep -Milliseconds 800
        $after = Read-Presets
        Say ("preset[0].label after rename = '{0}'" -f $after[0].label)
        Check 'renamed preset saved to config' ($after[0].label -eq $newLabel)
    }

    # 2) add a preset, then remove it again
    if ($null -ne $addBtn) {
        $cntBefore = (Read-Presets).Count
        Click-El $addBtn 0.5
        Start-Sleep -Milliseconds 800
        $cntAfterAdd = (Read-Presets).Count
        Say ("preset count {0} -> {1} after add" -f $cntBefore, $cntAfterAdd)
        Check 'add button appends a preset' ($cntAfterAdd -eq ($cntBefore + 1))

        if ($null -ne $delBtn) {
            Click-El $delBtn 0.5
            Start-Sleep -Milliseconds 800
            $cntAfterDel = (Read-Presets).Count
            Say ("preset count {0} -> {1} after remove" -f $cntAfterAdd, $cntAfterDel)
            Check 'remove button deletes the preset' ($cntAfterDel -eq $cntBefore)
        }
    }

    # 3) close settings and confirm the popup reflects the edited label
    $win = Get-SettingsWin
    if ($null -ne $win) {
        try {
            $wp = $win.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
            $wp.Close()
        } catch { }
        Start-Sleep -Milliseconds 800
    }

    if (-not (Ensure-DrawerOpen)) { Say 'drawer not open before popup check' }

    $src = Join-Path $PSScriptRoot 'sel-source.ps1'
    $token = 'QD-PRE-' + (Get-Date -Format 'HHmmss')
    $proc = Start-Process -FilePath (Get-Process -Id $PID).Path `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $src, '-Text', $token) -PassThru
    $dhwnd = [IntPtr]::Zero
    for ($w = 0; $w -lt 30; $w++) {
        Start-Sleep -Milliseconds 200
        $dhwnd = [U4]::FindByTitle('QD Sel Source')
        if ($dhwnd -ne [IntPtr]::Zero) { break }
    }
    if ($dhwnd -ne [IntPtr]::Zero) {
        [void][U4]::SetForegroundWindow($dhwnd)
        Start-Sleep -Milliseconds 600
        $editWin = $AE::FromHandle($dhwnd)
        $edit = Find-All-Of $editWin $CTL::Edit | Select-Object -First 1
        if ($null -eq $edit) {
            $all = $editWin.FindAll($CTS::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
            foreach ($el in $all) { if ($el.Current.ClassName -like '*EDIT*') { $edit = $el; break } }
        }
        if ($null -ne $edit) {
            $er = $edit.Current.BoundingRectangle
            [U4]::MoveTo([int]($er.X + 6), [int]($er.Y + 12))
            Start-Sleep -Milliseconds 150
            [U4]::LeftDown()
            Start-Sleep -Milliseconds 90
            for ($i = 1; $i -le 12; $i++) {
                [U4]::MoveTo([int]($er.X + 6 + (184 * $i / 12)), [int]($er.Y + 12))
                Start-Sleep -Milliseconds 25
            }
            [U4]::LeftUp()

            $popup = [IntPtr]::Zero
            for ($w = 0; $w -lt 40; $w++) {
                Start-Sleep -Milliseconds 150
                $popup = [U4]::FindByTitle('QuickDrawer Selection')
                if ($popup -ne [IntPtr]::Zero) { break }
            }
            Check 'popup reopened for label check' ($popup -ne [IntPtr]::Zero)
            if ($popup -ne [IntPtr]::Zero) {
                Start-Sleep -Milliseconds 400
                $pel = $AE::FromHandle($popup)
                $buttons = @(Find-All-Of $pel $CTL::Button)
                $names = @($buttons | Where-Object { $_.Current.Name -ne 'SendCustomPrompt' } | ForEach-Object { $_.Current.Name })
                Say ("popup preset labels = {0}" -f ($names -join ' | '))
                Check 'popup shows the renamed preset' ($names -contains $newLabel)
            }
        }
    }
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
}
finally {
    Restore-State
    Start-App | Out-Null
    Say ("RESULT: {0} ({1} failed assertions)" -f $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' }), $script:fail)
    Flush
}
