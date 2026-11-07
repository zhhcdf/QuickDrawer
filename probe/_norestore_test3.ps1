param()

# 验证需求 m08344（2026-11-06）：
# 面板钉住时被弹出的窗口，取消钉住后应**留在弹出后的位置**（不再挪回原位）。
#
# 前置条件由外部脚本保证：进程启动前把 config.json 的 dock.pinPanel 写成 true，
# 这样面板一展开就进入 pushout 看守状态，不受 auto-hide(500ms) 干扰。
#
# 坑（都实测踩过）：
# 1. WinForms 窗体必须 StartPosition='Manual'，否则 Left/Top 白设。
# 2. Add-Type -TypeDefinition 默认不引用 System.Windows.Forms，消息泵放 PowerShell 侧。
# 3. `W "X=" + $(...)` 会多传参数，必须写 `W ("X=" + $(...))`。

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

if (-not ('NrsFix3' -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class NrsFix3
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int max);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);

    public static string RectOf(IntPtr h)
    {
        RECT r;
        if (!GetWindowRect(h, out r)) { return "rect-fail"; }
        return String.Format("{0},{1} {2}x{3}", r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top);
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

$out = Join-Path $env:TEMP 'qd_norestore_test3.txt'
"=== no-restore-after-unpin test (m08344) ===" | Out-File -FilePath $out -Encoding utf8
function W([string]$msg) { $msg | Out-File -FilePath $out -Append -Encoding utf8 }

function Pump([int]$ms) {
    $end = [Environment]::TickCount + $ms
    while ([Environment]::TickCount -lt $end) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 10
    }
}

function PumpIn([int]$ms) {
    $end = [Environment]::TickCount + $ms
    while ([Environment]::TickCount -lt $end) {
        [void][NrsFix3]::SetCursorPos(1900, 520)
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 20
    }
}

function FindName([string]$name) {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty, $name)
    return $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
}

$HOME_LEFT = 1620
$HOME_TOP = 220
$HOME_W = 280
$HOME_H = 240
$homeRect = "$HOME_LEFT,$HOME_TOP ${HOME_W}x${HOME_H}"

# --- 1. 让抽屉滑出（配置里 pinPanel=True，启动即钉住）---
[void][NrsFix3]::SetCursorPos(1900, 520)
PumpIn 2200
$pin = FindName 'PinPanel'
if ($null -eq $pin) {
    W "PIN BUTTON NOT FOUND"
    Get-Content -Path $out -Encoding utf8
    exit 1
}
$inv = $pin.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
W "panel opened, pin button found"

# --- 2. 摆窗口到面板区，等 pushout 把它弹出去 ---
$form = New-Object System.Windows.Forms.Form
$form.Text = 'QdNoRestoreTarget'
$form.StartPosition = 'Manual'
$form.Left = $HOME_LEFT
$form.Top = $HOME_TOP
$form.Width = $HOME_W
$form.Height = $HOME_H
$form.Show()
$h = $form.Handle
W "target hwnd=0x$($h.ToInt64().ToString('X'))"
W "home rect      : $homeRect"

PumpIn 4000
$movedRect = [NrsFix3]::RectOf($h)
W "rect after pin : $movedRect"
$moved = ($movedRect -ne $homeRect)
W ("MOVED=" + $(if ($moved) { 'YES' } else { 'NO' }))

if (-not $moved) {
    W "PRE-CONDITION FAILED: window was not pushed out"
    $form.Close()
    Get-Content -Path $out -Encoding utf8
    exit 1
}

# --- 3. 取消钉住 -> WindowPushOut.End() ---
$inv.Invoke()
W "unpinned via UIA (End() runs)"
PumpIn 3000

# --- 4. 判定 ---
$finalRect = [NrsFix3]::RectOf($h)
$fgTitle = [NrsFix3]::TitleOf([NrsFix3]::GetForegroundWindow())
W "after unpin    : $finalRect"
W "foreground now : [$fgTitle]"
$stayed = ($finalRect -eq $movedRect)
$wentBack = ($finalRect -eq $homeRect)
W ("STAYED=" + $(if ($stayed) { 'YES' } else { 'NO' }))
W ("WENT_BACK=" + $(if ($wentBack) { 'YES' } else { 'NO' }))
W ("VERDICT=" + $(if ($stayed) { 'KEPT-LAYOUT' } elseif ($wentBack) { 'RESTORED-OLD-LAYOUT' } else { 'MOVED-ELSEWHERE' }))
W "HOME_RECT=$homeRect"
W "MOVED_RECT=$movedRect"
W "FINAL_RECT=$finalRect"

$form.Close()
$form.Dispose()
W "done"
Get-Content -Path $out -Encoding utf8
