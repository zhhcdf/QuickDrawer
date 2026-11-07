# dialog-theme-probe.ps1
# Verifies that the settings window and the custom prompt editor use the same
# background colour as the main drawer panel (2026-11-01 requirement:
# "settings page and custom prompt window background should match the main panel").
#
# Method: read the system theme from the registry, then measure the real pixel
# colour of both windows and compare with the drawer panel and with the theme
# resource value. The dominant colour (mode) of the window body is used instead
# of a fixed strip, so control layout changes cannot make the probe lie.
# ASCII only (Windows PowerShell 5.1 reads BOM-less scripts as ANSI).

param([string]$Exe = '')

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot '_helpers.ps1')

if ($Exe -eq '') { $Exe = Join-Path $root 'publish\QuickDrawer.exe' }

# ---- native helper: enumerate this process' top level windows -----------
if (-not ('ZWin' -as [type])) {
Add-Type @"
using System;
using System.Collections.Generic;
using System.Text;
using System.Runtime.InteropServices;

public class ZWinInfo {
    public IntPtr Handle;
    public uint Style;
    public uint ExStyle;
    public bool Topmost;
    public bool Visible;
    public string Title;
    public string ClassName;
    public int Left, Top, Right, Bottom;
    public int Width { get { return Right - Left; } }
    public int Height { get { return Bottom - Top; } }
    public override string ToString() {
        return string.Format("hwnd=0x{0:X} ex=0x{1:X} topmost={2} rect={3},{4} {5}x{6} title='{7}'",
            Handle.ToInt64(), ExStyle, Topmost, Left, Top, Width, Height, Title);
    }
}

public static class ZWin {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern int GetWindowLongW(IntPtr h, int idx);

    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

    public static List<ZWinInfo> TopLevel(int pid) {
        List<ZWinInfo> list = new List<ZWinInfo>();
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            uint wp; GetWindowThreadProcessId(h, out wp);
            if (wp != (uint)pid) return true;
            if (!IsWindowVisible(h)) return true;
            RECT r; GetWindowRect(h, out r);
            if ((r.Right - r.Left) < 60 || (r.Bottom - r.Top) < 20) return true;
            ZWinInfo i = new ZWinInfo();
            i.Handle = h;
            i.Style = (uint)GetWindowLongW(h, -16);
            i.ExStyle = (uint)GetWindowLongW(h, -20);
            i.Topmost = (i.ExStyle & 0x00000008) != 0;
            i.Visible = true;
            StringBuilder t = new StringBuilder(512);
            GetWindowTextW(h, t, 512);
            i.Title = t.ToString();
            StringBuilder c = new StringBuilder(512);
            GetClassNameW(h, c, 512);
            i.ClassName = c.ToString();
            i.Left = r.Left; i.Top = r.Top; i.Right = r.Right; i.Bottom = r.Bottom;
            list.Add(i);
            return true;
        }, IntPtr.Zero);
        return list;
    }
}
"@
}

# ---- dominant colour of a screen region --------------------------------
function Get-ModeColor($rect) {
    $x = [int]$rect.X; $y = [int]$rect.Y
    $w = [int]$rect.Width; $h = [int]$rect.Height
    if ($w -le 4 -or $h -le 4) { return $null }
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size($w, $h)))
    $counts = @{}
    for ($yy = 0; $yy -lt $h; $yy += 2) {
        for ($xx = 0; $xx -lt $w; $xx += 2) {
            $c = $bmp.GetPixel($xx, $yy)
            $key = '{0},{1},{2}' -f $c.R, $c.G, $c.B
            if ($counts.ContainsKey($key)) { $counts[$key]++ } else { $counts[$key] = 1 }
        }
    }
    $g.Dispose(); $bmp.Dispose()
    $bestKey = $null; $bestN = -1
    foreach ($k in $counts.Keys) { if ($counts[$k] -gt $bestN) { $bestN = $counts[$k]; $bestKey = $k } }
    $parts = $bestKey.Split(',')
    return [pscustomobject]@{ R = [int]$parts[0]; G = [int]$parts[1]; B = [int]$parts[2]; Hits = $bestN }
}

# normalises anything with R/G/B properties (RegionStats, ModeColor) or an
# int[] into a plain int[3] so delta maths never mixes types
function To-Rgb($c) {
    if ($c -is [int[]]) { return $c }
    return @([int]$c.R, [int]$c.G, [int]$c.B)
}

function Get-Delta($c, [int[]]$exp) {
    $v = To-Rgb $c
    return [math]::Abs($v[0] - $exp[0]) + [math]::Abs($v[1] - $exp[1]) + [math]::Abs($v[2] - $exp[2])
}

# The window background is only visible in the 16px margin that surrounds the
# root Grid, so sample a narrow column there instead of the whole client area
# (big controls such as the prompt TextBox would otherwise dominate the mode).
# left+8..left+14 stays clear of the non-client frame and inside the margin.
function Get-BgColor([int]$x, [int]$y, [int]$w, [int]$h) {
    $strip = @{ X = $x + 8; Y = $y + 40; Width = 6; Height = $h - 56 }
    return Get-ModeColor $strip
}

# ---- theme expectation -------------------------------------------------
$personalize = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$light = 0
try { $light = (Get-ItemProperty -Path $personalize -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme } catch { $light = 0 }
Say ("system AppsUseLightTheme = {0} ({1} theme)" -f $light, $(if ($light -eq 1) { 'light' } else { 'dark' }))

# opaque colours, mirroring Themes/Light.xaml / Themes/Dark.xaml
if ($light -eq 1) {
    $expPanel  = @(246, 246, 248)   # PanelBackground  #F5F6F6F8 (96% over desktop)
    $expDialog = @(246, 246, 248)   # DialogBackground #FFF6F6F8
    $oldDialog = @(42, 42, 50)      # previous hard-coded #FF2A2A32
} else {
    $expPanel  = @(43, 43, 51)      # PanelBackground  #F52B2B33
    $expDialog = @(43, 43, 51)      # DialogBackground #FF2B2B33
    $oldDialog = @(35, 35, 43)      # previous hard-coded #FF23232B
}
Say ("expected panel  = {0},{1},{2}" -f $expPanel[0], $expPanel[1], $expPanel[2])
Say ("expected dialog = {0},{1},{2}" -f $expDialog[0], $expDialog[1], $expDialog[2])

# PanelBackground is 96% opaque (#F5 alpha) and the drawer runs with
# AllowsTransparency=True, so the panel colour that actually lands on screen is
# the themes colour composited over whatever wallpaper sits behind it. Measured
# drift on this machine is ~18 total (246,246,248 -> 239,240,243); the dialogs
# are plain opaque windows and hit the theme colour exactly. Any comparison that
# involves the *panel* therefore has to tolerate that compositing drift, while
# still being far tighter than the old hard-coded dark (delta ~600) it guards
# against.
$panelTolerance = 26

$state = Backup-State
Start-App $Exe
$settingsColor = $null
$panelColor = $null
$dialogColor = $null
try {
    Ensure-DrawerOpen

    $drawer = Get-DrawerWindow
    if ($null -eq $drawer) { throw 'drawer window not found' }
    $r = Get-DrawerRect
    Say ("drawer rect = {0},{1} {2}x{3}" -f $r[0], $r[1], $r[2], $r[3])

    # ---- 1. drawer panel reference colour -----------------------------
    $tabNotes = Find-ById $drawer 'TabNotes'
    if ($null -eq $tabNotes) { throw 'TabNotes not found' }
    $tr = $tabNotes.Current.BoundingRectangle
    $refY = [int]$tr.Y - 4
    $panelRef = Get-RegionStats @{ X = $r[0] + 20; Y = $refY; Width = 40; Height = 2 }
    $panelColor = To-Rgb $panelRef
    Say ("drawer panel ref = {0},{1},{2}" -f [int]$panelRef.R, [int]$panelRef.G, [int]$panelRef.B)
    $dp = Get-Delta $panelRef $expPanel
    Say ('drawer panel vs expected total delta = ' + $dp + ' (tolerance ' + $panelTolerance + ')')
    Check 'drawer panel matches the active theme' ($dp -le $panelTolerance)

    # ---- 2. settings window -------------------------------------------
    $menuBtn = Find-ById $drawer 'MenuButton'
    if ($null -eq $menuBtn) { throw 'MenuButton not found' }
    Click-El $menuBtn
    Start-Sleep -Milliseconds 600

    $menuItems = @()
    for ($i = 0; $i -lt 40 -and $menuItems.Count -lt 4; $i++) {
        Start-Sleep -Milliseconds 150
        $cond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CTL::MenuItem)
        $menuItems = @($AE::RootElement.FindAll($CTS::Descendants, $cond))
    }
    Say ('menu items = ' + $menuItems.Count)
    Check 'app menu opened with 4 items' ($menuItems.Count -ge 4)
    if ($menuItems.Count -lt 1) { throw 'app menu did not open' }
    $menuItems[0].GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Milliseconds 900

    $settingsWin = $null
    for ($i = 0; $i -lt 30 -and $null -eq $settingsWin; $i++) {
        Start-Sleep -Milliseconds 200
        $winCond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CTL::Window)
        $wins = @($drawer.FindAll($CTS::Descendants, $winCond))
        foreach ($w in $wins) {
            $wr = $w.Current.BoundingRectangle
            if ($wr.Width -gt 400 -and $wr.Width -lt 600) { $settingsWin = $w; break }
        }
    }
    Check 'settings window opened' ($null -ne $settingsWin)
    if ($null -ne $settingsWin) {
        $sr = $settingsWin.Current.BoundingRectangle
        Say ("settings rect = {0},{1} {2}x{3}" -f [int]$sr.X, [int]$sr.Y, [int]$sr.Width, [int]$sr.Height)

        # background colour: only the 16px margin around the root Grid shows it
        $bg = Get-BgColor ([int]$sr.X) ([int]$sr.Y) ([int]$sr.Width) ([int]$sr.Height)
        $settingsColor = To-Rgb $bg
        Say ("settings dominant colour = {0},{1},{2}  (pixels={3})" -f $bg.R, $bg.G, $bg.B, $bg.Hits)
        $ds = Get-Delta $bg $expDialog
        Say ('settings background vs expected total delta = ' + $ds)
        Check 'settings background matches the theme dialog colour' ($ds -le 6)

        $do = Get-Delta $bg $oldDialog
        Say ('settings background vs old hard-coded dark total delta = ' + $do)
        Check 'settings background is no longer the old dark colour' ($do -ge 60)

        $shot = Join-Path $PSScriptRoot 'dialog-theme-settings.png'
        $bmp = New-Object System.Drawing.Bitmap([int]$sr.Width, [int]$sr.Height)
        $gfx = [System.Drawing.Graphics]::FromImage($bmp)
        $gfx.CopyFromScreen([int]$sr.X, [int]$sr.Y, 0, 0, $bmp.Size)
        $gfx.Dispose(); $bmp.Save($shot, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
        Say ('screenshot -> ' + $shot)

        $settingsWin.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
        Start-Sleep -Milliseconds 500
    }

    # ---- 3. custom prompt editor --------------------------------------
    $srcExe = Join-Path $PSScriptRoot 'sel-source.ps1'
    $srcProc = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $srcExe) -PassThru
    Start-Sleep -Seconds 3

    $srcHwnd = [IntPtr]::Zero
    for ($i = 0; $i -lt 40 -and $srcHwnd -eq [IntPtr]::Zero; $i++) {
        Start-Sleep -Milliseconds 200
        $cands = [ZWin]::TopLevel($srcProc.Id)
        foreach ($c in $cands) {
            if ($c.Title -ne '' -and $c.Handle -ne [IntPtr]::Zero) { $srcHwnd = $c.Handle; break }
        }
    }
    Check 'selection source window found' ($srcHwnd -ne [IntPtr]::Zero)

    if ($srcHwnd -ne [IntPtr]::Zero) {
        $srcEl = $AE::FromHandle($srcHwnd)
        $edit = $null
        $ec = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CTL::Edit)
        $found = @($srcEl.FindAll($CTS::Descendants, $ec))
        if ($found.Count -gt 0) { $edit = $found[0] }
        if ($null -eq $edit) {
            $all = @($srcEl.FindAll($CTS::Descendants, [System.Windows.Automation.Condition]::TrueCondition))
            foreach ($e in $all) {
                if ($e.Current.ClassName -like '*EDIT*') { $edit = $e; break }
            }
        }
        if ($null -ne $edit) {
            $er = $edit.Current.BoundingRectangle
            $sx = [int]($er.X + 10); $sy = [int]($er.Y + 8)
            [U4]::MoveTo($sx, $sy)
            Start-Sleep -Milliseconds 150
            [U4]::LeftDown()
            for ($i = 1; $i -le 10; $i++) { [U4]::MoveTo($sx + $i * 8, $sy) }
            Start-Sleep -Milliseconds 120
            [U4]::LeftUp()

            # 2026-11-01 (fourth): the popup now collapses itself when the
            # pointer never docks on it within 2s. This probe used to sleep
            # 2200ms here, so the strip was already hidden by the time it
            # looked for the send button (FindWindowW still matches a HIDDEN
            # window, hence "popup appeared" passed while "send button" did
            # not). Wait for it right away and dock the pointer on it, which
            # keeps it alive until we click.
            $popup = [IntPtr]::Zero
            for ($i = 0; $i -lt 50 -and $popup -eq [IntPtr]::Zero; $i++) {
                Start-Sleep -Milliseconds 100
                $popup = [U4]::FindByTitle('QuickDrawer Selection')
            }
            Check 'selection popup appeared' ($popup -ne [IntPtr]::Zero)

            if ($popup -ne [IntPtr]::Zero) {
                $pr0 = [U4]::GetRect($popup)
                [U4]::MoveTo([int](($pr0[0] + $pr0[2]) / 2), [int](($pr0[1] + $pr0[3]) / 2))
                Start-Sleep -Milliseconds 250
                $pe = $AE::FromHandle((New-Object System.IntPtr($popup.ToInt64())))
                $bc = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CTL::Button)
                $buttons = @($pe.FindAll($CTS::Descendants, $bc))
                $send = $null
                foreach ($b in $buttons) { if ($b.Current.Name -eq 'SendCustomPrompt') { $send = $b; break } }
                Check 'send button present on the popup' ($null -ne $send)
                if ($null -ne $send) {
                    $br = $send.Current.BoundingRectangle
                    Click-Point ([int]($br.X + $br.Width / 2)) ([int]($br.Y + $br.Height / 2))
                    Start-Sleep -Milliseconds 1200

                    $qd = @(Get-Process -Name QuickDrawer -ErrorAction SilentlyContinue)
                    $dlgInfo = $null
                    for ($i = 0; $i -lt 40 -and $null -eq $dlgInfo; $i++) {
                        Start-Sleep -Milliseconds 200
                        foreach ($t in [ZWin]::TopLevel($qd[0].Id)) {
                            $ti = $t.Title
                            if ($ti -ne 'QuickDrawer' -and $ti -ne 'QuickDrawer Handle' -and $ti -ne 'QuickDrawer Selection' -and $ti -ne '') {
                                $dlgInfo = $t; break
                            }
                        }
                    }
                    Check 'prompt editor dialog opened' ($null -ne $dlgInfo)

                    if ($null -ne $dlgInfo) {
                        Say ('dialog ' + $dlgInfo.ToString())
                        $dbg = Get-BgColor $dlgInfo.Left $dlgInfo.Top $dlgInfo.Width $dlgInfo.Height
                        $dialogColor = To-Rgb $dbg
                        Say ("dialog dominant colour = {0},{1},{2}  (pixels={3})" -f $dbg.R, $dbg.G, $dbg.B, $dbg.Hits)
                        $dd = Get-Delta $dbg $expDialog
                        Say ('dialog background vs expected total delta = ' + $dd)
                        Check 'prompt editor background matches the theme dialog colour' ($dd -le 6)

                        $do2 = Get-Delta $dbg $oldDialog
                        Say ('dialog background vs old hard-coded dark total delta = ' + $do2)
                        Check 'prompt editor background is no longer the old dark colour' ($do2 -ge 60)

                        # The dialog is opaque, the panel is 96% over the desktop,
                        # so these two can only be equal after compositing drift.
                        $dpn = Get-Delta $dbg $panelColor
                        Say ('dialog background vs drawer panel total delta = ' + $dpn + ' (tolerance ' + $panelTolerance + ')')
                        Check 'dialog background equals the drawer panel background' ($dpn -le $panelTolerance)

                        if ($null -ne $settingsColor) {
                            $dps = Get-Delta $dbg $settingsColor
                            Say ('dialog background vs settings background total delta = ' + $dps)
                            Check 'dialog and settings share the same background' ($dps -le 6)
                        }

                        $shot2 = Join-Path $PSScriptRoot 'dialog-theme-prompt.png'
                        $bmp2 = New-Object System.Drawing.Bitmap($dlgInfo.Width, $dlgInfo.Height)
                        $g2 = [System.Drawing.Graphics]::FromImage($bmp2)
                        $g2.CopyFromScreen($dlgInfo.Left, $dlgInfo.Top, 0, 0, $bmp2.Size)
                        $g2.Dispose(); $bmp2.Save($shot2, [System.Drawing.Imaging.ImageFormat]::Png); $bmp2.Dispose()
                        Say ('screenshot -> ' + $shot2)

                        [U4]::KeyTap(0x1B)   # ESC
                        Start-Sleep -Milliseconds 500
                    }
                }
            }
        } else {
            Say 'source edit not found'
            Check 'source edit found' $false
        }
    }

    if (-not $srcProc.HasExited) { Stop-Process -Id $srcProc.Id -Force -ErrorAction SilentlyContinue }
} finally {
    Stop-App
    Restore-State $state
}

Say ("RESULT: {0} ({1} failed assertions)" -f $(if ($script:fail -eq 0) { 'PASS' } else { 'FAIL' }), $script:fail)
Flush
