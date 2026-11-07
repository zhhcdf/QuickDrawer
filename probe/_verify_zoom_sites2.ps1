$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

$out = Join-Path $env:TEMP 'qd_zoomcap_sites.txt'
$lines = New-Object System.Collections.Generic.List[string]
function Say([string]$s) { $lines.Add($s); Write-Host $s }
function Flush { [IO.File]::WriteAllLines($out, $lines, (New-Object System.Text.UTF8Encoding($false))) }

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class U9 {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    public struct RECT { public int Left, Top, Right, Bottom; }

    public static IntPtr FindByTitle(uint procId, string title) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == procId) {
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

try {
    $AE = [Windows.Automation.AutomationElement]
    $TS = [Windows.Automation.TreeScope]
    $proc = Get-Process -Name QuickDrawer -ErrorAction Stop | Select-Object -First 1
    Say ('pid = ' + $proc.Id)

    [void][U9]::SetCursorPos(1915, 500)
    Start-Sleep -Milliseconds 1200

    $h = [U9]::FindByTitle([uint32]$proc.Id, 'QuickDrawer')
    if ($h -eq [IntPtr]::Zero) { throw 'drawer window not found' }
    $drawer = $AE::FromHandle($h)
    $r = New-Object U9+RECT
    [void][U9]::GetWindowRect($h, [ref]$r)
    Say ('drawer width = ' + ($r.Right - $r.Left))

    $cTab = New-Object Windows.Automation.PropertyCondition($AE::AutomationIdProperty, 'TabAssistant')
    $tab = $drawer.FindFirst($TS::Descendants, $cTab)
    if (-not $tab) { throw 'TabAssistant not found' }
    $tab.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Say 'assistant tab selected'
    Start-Sleep -Milliseconds 2500

    [void][U9]::GetWindowRect($h, [ref]$r)
    $w = $r.Right - $r.Left
    Say ('width before widen check = ' + $w)
    if ($w -lt 500) {
        $cW = New-Object Windows.Automation.PropertyCondition($AE::AutomationIdProperty, 'AssistantWidenButton')
        $widen = $drawer.FindFirst($TS::Descendants, $cW)
        if (-not $widen) { throw 'AssistantWidenButton not found' }
        $widen.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
        Say 'widen clicked'
        Start-Sleep -Milliseconds 2000
    }
    [void][U9]::GetWindowRect($h, [ref]$r)
    Say ('drawer width after widen = ' + ($r.Right - $r.Left))

    foreach ($site in @('ChipKimi', 'ChipGlm', 'ChipQwen', 'ChipDeepSeek')) {
        $cond = New-Object Windows.Automation.PropertyCondition($AE::AutomationIdProperty, $site)
        $chip = $drawer.FindFirst($TS::Descendants, $cond)
        if (-not $chip) { Say ($site + ' NOT FOUND'); continue }
        $chip.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
        Say ($site + ' selected')
        Start-Sleep -Milliseconds 2600
    }
}
catch {
    Say ('ERROR: ' + $_.Exception.Message)
}
finally {
    Flush
}
