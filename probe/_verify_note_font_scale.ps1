$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing, System.Windows.Forms

$out = Join-Path $env:TEMP 'qd_notefont_scale.txt'
$lines = New-Object System.Collections.Generic.List[string]
function Say([string]$s) { $lines.Add($s); Write-Host $s }
function Flush { [IO.File]::WriteAllLines($out, $lines, (New-Object System.Text.UTF8Encoding($false))) }

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class U6 {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    public struct RECT { public int Left, Top, Right, Bottom; }

    public static IntPtr FindByTitle(uint pid, string title) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && IsWindowVisible(h)) {
                StringBuilder t = new StringBuilder(256);
                GetWindowTextW(h, t, 256);
                if (t.ToString() == title) { found = h; return false; }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
"@

function Shot([IntPtr]$h, [string]$path) {
    $r = New-Object U6+RECT
    [void][U6]::GetWindowRect($h, [ref]$r)
    $w = $r.Right - $r.Left
    $hh = $r.Bottom - $r.Top
    $bmp = New-Object System.Drawing.Bitmap($w, $hh)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.Left, $r.Top, 0, 0, $bmp.Size)
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
}

try {
    $AE = [Windows.Automation.AutomationElement]
    $TS = [Windows.Automation.TreeScope]
    $proc = Get-Process -Name QuickDrawer -ErrorAction Stop | Select-Object -First 1
    Say ('pid = ' + $proc.Id)

    $drawerH = [U6]::FindByTitle([uint32]$proc.Id, 'QuickDrawer')
    $setH = [U6]::FindByTitle([uint32]$proc.Id, 'QuickDrawer 设置')
    Say ('drawer hwnd = 0x' + $drawerH.ToInt64().ToString('X'))
    Say ('settings hwnd = 0x' + $setH.ToInt64().ToString('X'))
    if ($drawerH -eq [IntPtr]::Zero) { throw 'drawer window not found' }
    if ($setH -eq [IntPtr]::Zero) { throw 'settings window not found' }

    $drawer = $AE::FromHandle($drawerH)
    $settings = $AE::FromHandle($setH)

    # switch to notes tab
    $nb = New-Object Windows.Automation.PropertyCondition($AE::AutomationIdProperty, 'TabNotes')
    $tab = $drawer.FindFirst($TS::Descendants, $nb)
    if (-not $tab) { throw 'TabNotes not found' }
    $tab.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Start-Sleep -Milliseconds 900
    Say 'notes tab selected'

    # baseline screenshot at current size
    $p12 = Join-Path $env:TEMP 'qd_notefont_12.png'
    Shot $drawerH $p12
    Say ('saved ' + $p12)

    # slider
    $sc = New-Object Windows.Automation.PropertyCondition($AE::AutomationIdProperty, 'NoteFontSlider')
    $slider = $settings.FindFirst($TS::Descendants, $sc)
    if (-not $slider) { throw 'NoteFontSlider not found' }
    $rp = $slider.GetCurrentPattern([Windows.Automation.RangeValuePattern]::Pattern)
    Say ('slider value before = ' + $rp.Current.Value)

    $rp.SetValue(20.0)
    Start-Sleep -Milliseconds 1200
    Say ('slider value after = ' + $rp.Current.Value)

    $tc = New-Object Windows.Automation.PropertyCondition($AE::AutomationIdProperty, 'NoteFontText')
    $lbl = $settings.FindFirst($TS::Descendants, $tc)
    if ($lbl) { Say ('NoteFontText after = ' + $lbl.Current.Name) }

    $p20 = Join-Path $env:TEMP 'qd_notefont_20.png'
    Shot $drawerH $p20
    Say ('saved ' + $p20)

    # back to 10 for the low end
    $rp.SetValue(10.0)
    Start-Sleep -Milliseconds 1200
    $p10 = Join-Path $env:TEMP 'qd_notefont_10.png'
    Shot $drawerH $p10
    Say ('saved ' + $p10)

    # restore 12
    $rp.SetValue(12.0)
    Start-Sleep -Milliseconds 1000
    Say ('slider restored to ' + $rp.Current.Value)
}
catch {
    Say ('ERROR: ' + $_.Exception.Message)
}
finally {
    Flush
}
