$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

$out = Join-Path $env:TEMP 'qd_zoomcap.txt'
$lines = New-Object System.Collections.Generic.List[string]
function Say([string]$s) { $lines.Add($s); Write-Host $s }
function Flush { [IO.File]::WriteAllLines($out, $lines, (New-Object System.Text.UTF8Encoding($false))) }

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class U7 {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
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

    # 悬停右边缘把抽屉滑出来
    [void][U7]::SetCursorPos(1915, 500)
    Start-Sleep -Milliseconds 1200

    $h = [U7]::FindByTitle([uint32]$proc.Id, 'QuickDrawer')
    Say ('drawer hwnd = 0x' + $h.ToInt64().ToString('X'))
    if ($h -eq [IntPtr]::Zero) { throw 'drawer window not found' }
    $drawer = $AE::FromHandle($h)

    $r = New-Object U7+RECT
    [void][U7]::GetWindowRect($h, [ref]$r)
    Say ('drawer rect = ' + $r.Left + ',' + $r.Top + ',' + $r.Right + ',' + $r.Bottom)

    $cond = New-Object Windows.Automation.PropertyCondition($AE::AutomationIdProperty, 'TabAssistant')
    $tab = $drawer.FindFirst($TS::Descendants, $cond)
    if (-not $tab) { throw 'TabAssistant not found' }
    $tab.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Say 'assistant tab selected'
    Start-Sleep -Milliseconds 2500

    $cond2 = New-Object Windows.Automation.PropertyCondition($AE::AutomationIdProperty, 'AssistantWidenButton')
    $widen = $drawer.FindFirst($TS::Descendants, $cond2)
    if (-not $widen) { throw 'AssistantWiden not found' }
    $widen.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    Say 'widen clicked'
    Start-Sleep -Milliseconds 2000

    [void][U7]::GetWindowRect($h, [ref]$r)
    Say ('drawer rect after widen = ' + $r.Left + ',' + $r.Top + ',' + $r.Right + ',' + $r.Bottom + ' width=' + ($r.Right - $r.Left))
}
catch {
    Say ('ERROR: ' + $_.Exception.Message)
}
finally {
    Flush
}
