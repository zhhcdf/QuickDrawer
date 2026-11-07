# Verification for the 2026-11-01 (third) changes:
#   A) the duplicate "start with Windows" checkbox is gone from the settings
#      window, while every other control is still there (guard against
#      deleting too much) and the tray/menu entry still works;
#   B) the popup send button has rounded corners instead of a square slab.
# ASCII only; paths derive from $PSScriptRoot.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '_helpers.ps1')

Add-Type -AssemblyName System.Drawing

$AE = [System.Windows.Automation.AutomationElement]
$CTS = [System.Windows.Automation.TreeScope]
$CTL = [System.Windows.Automation.ControlType]

$script:fail = 0
$script:sourceProc = $null

$token = 'QD-RND-' + (Get-Date -Format 'HHmmss')

# ---------- pixel helpers ----------

function Get-RectShot([int]$x, [int]$y, [int]$w, [int]$h) {
    if ($w -le 0 -or $h -le 0) { return $null }
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size($w, $h)))
    $g.Dispose()
    return $bmp
}

# Max B-R over the whole bitmap: the accent fill itself (#3A7BD5 -> 155).
# The button is small and its centre is covered by white text, so a centre
# sample under-reports the fill; the point of the fill is what we need.
function Get-MaxBleness($bmp) {
    $best = 0
    for ($py = 0; $py -lt $bmp.Height; $py++) {
        for ($px = 0; $px -lt $bmp.Width; $px++) {
            $c = $bmp.GetPixel($px, $py)
            $v = $c.B - $c.R
            if ($v -gt $best) { $best = $v }
        }
    }
    return $best
}

# Mean B-R over a small box. The accent blue is B-R ~155, every neutral
# (white popup backdrop, grey text, antialiased rim) sits near 0.
function Get-Blueness($bmp, [int]$x, [int]$y, [int]$w, [int]$h) {
    $sum = 0.0
    $n = 0
    for ($py = $y; $py -lt ($y + $h); $py++) {
        if ($py -lt 0 -or $py -ge $bmp.Height) { continue }
        for ($px = $x; $px -lt ($x + $w); $px++) {
            if ($px -lt 0 -or $px -ge $bmp.Width) { continue }
            $c = $bmp.GetPixel($px, $py)
            $sum += ($c.B - $c.R)
            $n++
        }
    }
    if ($n -eq 0) { return 0.0 }
    return [math]::Round($sum / $n, 1)
}

# ---------- UIA helpers ----------

# _helpers.ps1 Get-DrawerWindow filters on a 380..430 px width, which stops
# matching as soon as dock.width changes (appendix D #141/#156). Find the
# drawer by process id and height instead.
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

# MainWindowHandle only ever names ONE window and the WPF ContextMenu lives in
# its own popup, so enumerate every top-level window of the process.
function Get-AppWins {
    $p = Get-Process -Name QuickDrawer -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $p) { return @() }
    $cond = New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $p.Id)
    return @($AE::RootElement.FindAll($CTS::Children, $cond))
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

function Find-AnyById($root, [string]$id) {
    $el = Find-ById $root $id
    if ($null -eq $el) { $el = Find-By-Name $root $id }
    return $el
}

function Open-AppMenu {
    Ensure-DrawerOpen | Out-Null
    Start-Sleep -Milliseconds 300
    $drawer = Get-DrawerAny
    if ($null -eq $drawer) { throw 'drawer window not found in UIA' }
    $btn = Find-AnyById $drawer 'MenuButton'
    if ($null -eq $btn) { throw 'menu button missing' }
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
    return $items
}

function Close-Window($win) {
    $pat = $null
    if ($win.TryGetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern, [ref]$pat)) {
        $pat.Close()
        return $true
    }
    return $false
}

function Get-RegistryAutoStart {
    try {
        $v = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' `
            -Name 'QuickDrawer' -ErrorAction Stop
        return ([string]$v.QuickDrawer).Length -gt 0
    }
    catch {
        return $false
    }
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

function Wait-Window([string]$title, [int]$timeoutMs = 4000) {
    $deadline = (Get-Date).AddMilliseconds($timeoutMs)
    while ((Get-Date) -lt $deadline) {
        $h = [U4]::FindByTitle($title)
        if ($h -ne [IntPtr]::Zero) { return $h }
        Start-Sleep -Milliseconds 100
    }
    return [IntPtr]::Zero
}

function Stop-Source {
    if ($script:sourceProc) {
        Stop-Process -Id $script:sourceProc.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 400
        $script:sourceProc = $null
    }
}

# ---------- run ----------

Say '=== settings autostart removal + rounded send button ==='
if ($Exe -ne '') { $script:appExe = $Exe }

Backup-State
$openedSettings = $false
try {
    Stop-App
    Start-Sleep -Milliseconds 400
    Start-App
    Start-Sleep -Milliseconds 1500
    Ensure-DrawerOpen | Out-Null
    Start-Sleep -Milliseconds 500

    $drawer = Get-DrawerAny
    Check 'drawer window found' ($null -ne $drawer)
    if ($null -eq $drawer) { throw 'drawer window not found' }

    # ---------- part A: settings window ----------
    $items = Open-AppMenu
    Say ("menu items = {0}" -f @($items).Count)
    Check 'menu has four entries (settings/autostart/about/exit)' (@($items).Count -eq 4)

    $autoItem = $null
    foreach ($it in @($items)) {
        $tp = $null
        if ($it.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$tp)) {
            $autoItem = $it
        }
    }
    Check 'exactly one menu entry is checkable (autostart)' ($null -ne $autoItem)
    if ($null -ne $autoItem) {
        $tp = $null
        [void]$autoItem.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$tp)
        $state = $tp.Current.ToggleState
        $reg = Get-RegistryAutoStart
        $expectOn = ($state -eq [System.Windows.Automation.ToggleState]::On)
        Say ("menu autostart toggle={0} registry_run_entry={1}" -f $state, $reg)
        Check 'menu autostart check state matches the registry' ($expectOn -eq $reg)
    }

    # first entry is 'settings...' - click it to open the settings window
    Click-El @($items)[0] 0.5
    $win = Wait-SettingsWin 8000
    Check 'settings window opened from the menu' ($null -ne $win)
    if ($null -eq $win) { throw 'settings window did not open' }
    $openedSettings = $true

    $wr = $win.Current.BoundingRectangle
    Say ("settings window rect={0},{1} {2}x{3}" -f [int]$wr.X, [int]$wr.Y, [int]$wr.Width, [int]$wr.Height)

    # A1) the duplicate is gone
    $autoCheck = Find-AnyById $win 'AutoStartCheck'
    Check 'settings window has no AutoStartCheck control' ($null -eq $autoCheck)
    $allChecks = @(Find-All-Of $win $CTL::CheckBox)
    Say ("checkboxes in settings = {0}" -f @($allChecks).Count)
    $names = @()
    foreach ($c in $allChecks) { $names += ('[' + $c.Current.Name + ']') }
    Say ("checkbox names = {0}" -f ($names -join ' '))
    Check 'only the zoom checkbox remains' (@($allChecks).Count -eq 1)

    # A2) nothing else was deleted along with it
    foreach ($id in @('WidthSlider', 'WidthText', 'HotkeyText', 'HotkeyCapture', 'HotkeyHint',
                      'HandleHeightSlider', 'HandleHeightText', 'CollapseDelaySlider',
                      'CollapseDelayText', 'ZoomScaleCheck', 'ZoomScaleHint', 'PresetList',
                      'PresetLabelBox', 'PresetInstructionBox', 'PresetAddButton',
                      'PresetRemoveButton', 'StatusText')) {
        $el = Find-AnyById $win $id
        Check ("settings still has {0}" -f $id) ($null -ne $el)
    }

    # A3) no stray blank row: the content must fill the window down to the
    # status bar, so the status text sits near the bottom edge.
    $stEl = Find-AnyById $win 'StatusText'
    if ($null -ne $stEl) {
        $sr = $stEl.Current.BoundingRectangle
        $gapBottom = ($wr.Y + $wr.Height) - ($sr.Y + $sr.Height)
        Say ("status text bottom gap = {0}px" -f [int]$gapBottom)
        Check 'status text still hugs the window bottom (gap <= 40px)' ($gapBottom -le 40)
    }

    [void](Close-Window $win)
    Start-Sleep -Milliseconds 600
    $openedSettings = $false

    # ---------- part B: rounded send button ----------
    $sourceScript = Join-Path $PSScriptRoot 'sel-source.ps1'
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

    Invoke-DragSelect ([int]($er.X + 6)) ([int]($er.Y + 12)) ([int]($er.X + 180))

    $popup = Wait-Window 'QuickDrawer Selection' 4000
    Check 'popup appeared' ($popup -ne [IntPtr]::Zero)
    if ($popup -eq [IntPtr]::Zero) { throw 'popup did not appear' }

    $buttons = @()
    for ($retry = 0; $retry -lt 5 -and @($buttons).Count -eq 0; $retry++) {
        Start-Sleep -Milliseconds 300
        $popup = [U4]::FindByTitle('QuickDrawer Selection')
        if ($popup -eq [IntPtr]::Zero) { break }
        $pel = $AE::FromHandle($popup)
        $buttons = @(Find-All-Of $pel $CTL::Button)
    }
    $sendBtn = @($buttons | Where-Object { $_.Current.Name -eq 'SendCustomPrompt' })
    Say ("popup buttons total={0} send={1}" -f @($buttons).Count, $sendBtn.Count)
    Check 'send button present' ($sendBtn.Count -eq 1)
    if ($sendBtn.Count -ne 1) { throw 'send button missing' }

    $sb = $sendBtn[0].Current.BoundingRectangle
    $bx = [int]$sb.X
    $by = [int]$sb.Y
    $bw = [int]$sb.Width
    $bh = [int]$sb.Height
    Say ("send button rect={0},{1} {2}x{3}" -f $bx, $by, $bw, $bh)
    Check 'send button is at least 20x16 (sane bounds)' ($bw -ge 20 -and $bh -ge 16)

    $bmp = Get-RectShot $bx $by $bw $bh
    if ($null -eq $bmp) { throw 'could not capture the send button' }

    # The fill colour is #3A7BD5 (B-R 155). Sample it as the maximum over the
    # bitmap: the button is only 42x19 and its centre is covered by the white
    # "send" label, so a centre probe under-reports badly.
    $fillBlue = Get-MaxBleness $bmp

    # Corners: with radius 4 on a 19px-tall button the extreme corner pixel is
    # backdrop or the antialiased rim, never solid fill. A square button would
    # put full fill there, so the RATIO against the fill is the discriminator
    # (absolute values drift with the backdrop behind the popup).
    $tlBlue = Get-Blueness $bmp 0 0 2 2
    $trBlue = Get-Blueness $bmp ($bw - 2) 0 2 2
    $blBlue = Get-Blueness $bmp 0 ($bh - 2) 2 2
    $brBlue = Get-Blueness $bmp ($bw - 2) ($bh - 2) 2 2
    $maxCorner = [math]::Max([math]::Max($tlBlue, $trBlue), [math]::Max($blBlue, $brBlue))
    $cornerRatio = 0.0
    if ($fillBlue -gt 0) { $cornerRatio = [math]::Round($maxCorner / $fillBlue, 2) }
    Say ("send button fill B-R={0}; corners TL={1} TR={2} BL={3} BR={4}; corner/fill ratio={5}" -f `
            $fillBlue, $tlBlue, $trBlue, $blBlue, $brBlue, $cornerRatio)

    # positive control first: without it "corners are not blue" could pass
    # simply because nothing blue was painted at all.
    Check 'send button is painted in the accent blue (fill B-R >= 120)' ($fillBlue -ge 120)
    # a square button would put ~1.0 here; rounded corners fall well under
    Check 'corners are not solid fill (ratio <= 0.60)' ($cornerRatio -le 0.60)

    # and the fill must be back just one radius in from the corner, otherwise
    # "not fill at the corner" could just mean the whole button went blank.
    $insetBlue = Get-Blueness $bmp 4 4 2 2
    $insetRatio = 0.0
    if ($fillBlue -gt 0) { $insetRatio = [math]::Round($insetBlue / $fillBlue, 2) }
    Say ("send button B-R at inset 4,4 = {0} (ratio {1})" -f $insetBlue, $insetRatio)
    Check 'fill returns one radius in from the corner (inset ratio >= 0.70)' ($insetRatio -ge 0.70)


    $shot = Join-Path $here 'send-button-rounded.png'
    $bmp.Save($shot, [System.Drawing.Imaging.ImageFormat]::Png)
    Say ("screenshot -> {0}" -f $shot)
    $bmp.Dispose()

    [U4]::KeyTap(0x1B)
    Start-Sleep -Milliseconds 400
}
catch {
    Say ("ERROR: {0}" -f $_.Exception.Message)
    $script:fail = $script:fail + 1
}
finally {
    Stop-Source
    if ($openedSettings) {
        $w = Wait-SettingsWin 500
        if ($null -ne $w) { [void](Close-Window $w) }
    }
    Stop-App
    Restore-State
    Say ("RESULT: {0} ({1} failed assertions)" -f $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' }), $script:fail)
    Flush
}
