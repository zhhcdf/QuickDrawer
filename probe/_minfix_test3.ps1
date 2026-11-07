param()

# 验证缺陷 m07888 症状 A：
# 面板固定(pushout)时被挪过的窗口，用户随后把它最小化，
# 再取消固定 / 收起面板 —— 修复前 SetWindowPlacement 会把它弹出来（抢前台），
# 修复后应保持最小化、只是把还原矩形改回原值。
# 2026-11-05。
#
# 三个必须踩对的点（都实测踩过）：
# 1. WinForms 窗体必须 StartPosition='Manual'，否则 Show() 时被
#    WindowsDefaultLocation 覆盖，Left/Top 白设。
# 2. C# 代码里不要用 System.Windows.Forms.Application.DoEvents()，
#    Add-Type -TypeDefinition 默认不引用 System.Windows.Forms。消息泵放 PowerShell 侧。
# 3. `W "X=" + $(if ...)` 会把 + 后面的东西当成额外参数传给只接一个参数的函数，
#    必须写 `W ("X=" + $(...))`。我第一次就是因此拿到 `MOVED=`、`VERDICT=` 空值。

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

if (-not ('MinFix' -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class MinFix
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct WINDOWPLACEMENT
    {
        public int length, flags, showCmd;
        public POINT ptMinPosition, ptMaxPosition;
        public RECT rcNormalPosition;
    }

    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr h, ref WINDOWPLACEMENT p);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int max);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);

    public const int SW_MINIMIZE = 6;
    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_NOZORDER = 0x0004;
    public const uint SWP_NOACTIVATE = 0x0010;

    public static string RectOf(IntPtr h)
    {
        RECT r;
        if (!GetWindowRect(h, out r)) { return "rect-fail"; }
        return String.Format("{0},{1} {2}x{3}", r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top);
    }

    public static string NormalOf(IntPtr h)
    {
        WINDOWPLACEMENT p = new WINDOWPLACEMENT();
        p.length = Marshal.SizeOf(typeof(WINDOWPLACEMENT));
        GetWindowPlacement(h, ref p);
        return String.Format("showCmd={0} normal={1},{2} {3}x{4}",
            p.showCmd, p.rcNormalPosition.Left, p.rcNormalPosition.Top,
            p.rcNormalPosition.Right - p.rcNormalPosition.Left,
            p.rcNormalPosition.Bottom - p.rcNormalPosition.Top);
    }

    public static string TitleOf(IntPtr h)
    {
        StringBuilder sb = new StringBuilder(256);
        GetWindowTextW(h, sb, sb.Capacity);
        return sb.ToString();
    }
}
"@
}

$out = Join-Path $env:TEMP 'qd_minfix_test.txt'
"=== minimized-window fix test ===" | Out-File -FilePath $out -Encoding utf8
function W([string]$msg) { $msg | Out-File -FilePath $out -Append -Encoding utf8 }
function Pump([int]$ms) {
    $end = [Environment]::TickCount + $ms
    while ([Environment]::TickCount -lt $end) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 10
    }
}

function FindName([string]$name) {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty, $name)
    return $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
}

# --- 1. 建被测窗口，摆在面板区（面板 x=1520..1920）---
$form = New-Object System.Windows.Forms.Form
$form.Text = 'QdMinFixTarget'
$form.StartPosition = 'Manual'
$form.Left = 1620
$form.Top = 220
$form.Width = 280
$form.Height = 240
$form.Show()
Pump 700

$h = $form.Handle
$origRect = [MinFix]::RectOf($h)
$origNormal = [MinFix]::NormalOf($h)
W "target hwnd=0x$($h.ToInt64().ToString('X'))"
W "orig rect      : $origRect"
W "orig placement : $origNormal"

# --- 2. 让抽屉滑出 ---
[void][MinFix]::SetCursorPos(1915, 520)
Pump 1500
$drawer = FindName 'Dashboard'
W ("drawer found   : " + $(if ($null -ne $drawer) { 'YES' } else { 'NO' }))
W "foreground after hover=0x$(([MinFix]::GetForegroundWindow()).ToInt64().ToString('X'))"

# --- 3. UIA 点固定按钮 ---
$pin = FindName 'PinPanel'
if ($null -eq $pin) {
    W "PIN BUTTON NOT FOUND"
    $form.Close()
    Get-Content -Path $out -Encoding utf8
    exit 1
}
$inv = $pin.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
$inv.Invoke()
W "pinned via UIA"
Pump 3000

$movedRect = [MinFix]::RectOf($h)
W "rect after pin : $movedRect"
W ("MOVED=" + $(if ($movedRect -ne $origRect) { 'YES' } else { 'NO' }))

# --- 4. 用户把它最小化 ---
[void][MinFix]::ShowWindow($h, [MinFix]::SW_MINIMIZE)
Pump 1500
W "after minimize : iconic=$([MinFix]::IsIconic($h)) $([MinFix]::NormalOf($h))"

# --- 5. 取消固定 -> WindowPushOut.End() ---
$inv.Invoke()
W "unpinned via UIA"
Pump 3000

# --- 6. 判定 ---
$stillIconic = [MinFix]::IsIconic($h)
$finalNormal = [MinFix]::NormalOf($h)
$fgTitle = [MinFix]::TitleOf([MinFix]::GetForegroundWindow())
W "after unpin    : iconic=$stillIconic $finalNormal"
W "foreground now : [$fgTitle]"
W ("VERDICT=" + $(if ($stillIconic) { 'STILL-MINIMIZED' } else { 'GOT-RESTORED' }))
W "NORMAL_BEFORE=$origNormal"
W "NORMAL_AFTER =$finalNormal"
$movedTag = if ($movedRect -ne $origRect) { $movedRect } else { 'never-moved' }
W "MOVED_RECT=$movedTag"

$form.Close()
$form.Dispose()
W "done"
Get-Content -Path $out -Encoding utf8
