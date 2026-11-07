param()

# 验证缺陷 m07888 症状 B：
# 助手页点"截图提问"按钮 -> 面板收起 -> 全屏遮罩弹出 -> Esc 取消遮罩。
# 修复前：遮罩关闭触发系统前台重选，已最小化的窗口会被恢复显示。
# 判定：全过程结束后，被测窗口仍处于最小化状态。
# 2026-11-05。
#
# 关键 UIA 事实（probe/_uia_shot_probe.ps1 实测）：
#   TabAssistant    : ControlType.RadioButton, rect=1669,452 60x24, patterns=SelectionItem —— 不支持 Invoke！
#   AssistantShot   : ControlType.Button,     rect=1890,480 22x24, patterns=Invoke
#   PinPanel        : ControlType.Button,     rect=1856,12  26x24, patterns=Invoke
# 点标签页必须用 SelectionItemPattern.Select()，用 InvokePattern 会抛 InvalidOperationException。

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

if (-not ('ShotFix2' -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class ShotFix2
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int max);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);

    public const int SW_MINIMIZE = 6;
    public const byte VK_ESCAPE = 0x1B;
    public const uint KEYEVENTF_KEYUP = 0x0002;
    public const uint LEFTDOWN = 0x0002;
    public const uint LEFTUP = 0x0004;

    public static string TitleOf(IntPtr h)
    {
        StringBuilder sb = new StringBuilder(256);
        GetWindowTextW(h, sb, sb.Capacity);
        return sb.ToString();
    }

    public static string RectOf(IntPtr h)
    {
        RECT r;
        if (!GetWindowRect(h, out r)) { return "rect-fail"; }
        return String.Format("{0},{1} {2}x{3}", r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top);
    }

    public static void Click(int x, int y)
    {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(80);
        mouse_event(LEFTDOWN, 0, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(60);
        mouse_event(LEFTUP, 0, 0, 0, UIntPtr.Zero);
    }

    public static void Esc()
    {
        keybd_event(VK_ESCAPE, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(80);
        keybd_event(VK_ESCAPE, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
    }
}
"@
}

$out = Join-Path $env:TEMP 'qd_shotfix_test.txt'
"=== screenshot-button minimized-window test ===" | Out-File -FilePath $out -Encoding utf8
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
function InvokeButton([string]$name) {
    $el = FindName $name
    if ($null -eq $el) { return 'NOT-FOUND' }
    try {
        $inv = $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        $inv.Invoke()
        return 'OK'
    } catch { return ('ERR: ' + $_.Exception.Message) }
}
function SelectTab([string]$name) {
    $el = FindName $name
    if ($null -eq $el) { return 'NOT-FOUND' }
    try {
        $sel = $el.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
        $sel.Select()
        return 'OK'
    } catch { return ('ERR: ' + $_.Exception.Message) }
}

# --- 1. 建被测窗口并最小化 ---
$form = New-Object System.Windows.Forms.Form
$form.Text = 'QdShotFixTarget'
$form.StartPosition = 'Manual'
$form.Left = 300
$form.Top = 300
$form.Width = 320
$form.Height = 240
$form.Show()
Pump 800
$h = $form.Handle
W "target hwnd=0x$($h.ToInt64().ToString('X')) rect=$([ShotFix2]::RectOf($h))"

[void][ShotFix2]::ShowWindow($h, [ShotFix2]::SW_MINIMIZE)
Pump 1200
W "after minimize : iconic=$([ShotFix2]::IsIconic($h)) fg=[$([ShotFix2]::TitleOf([ShotFix2]::GetForegroundWindow()))]"

# --- 2. 鼠标到右缘让面板滑出 ---
[void][ShotFix2]::SetCursorPos(1915, 520)
Pump 1600
W "panel hover    : fg=[$([ShotFix2]::TitleOf([ShotFix2]::GetForegroundWindow()))]"

# --- 3. 切助手页（SelectionItemPattern），再点截图按钮（InvokePattern）---
W ("tab assistant  : " + (SelectTab 'TabAssistant'))
Pump 2200
W ("shot button    : " + (InvokeButton 'AssistantShot'))
Pump 3000

$overlay = FindName 'QuickDrawer Screenshot'
W ("overlay title  : " + $(if ($null -ne $overlay) { 'FOUND' } else { 'NOT-FOUND' }))
W "iconic while overlay=$([ShotFix2]::IsIconic($h)) panelOpen-ish fg=[$([ShotFix2]::TitleOf([ShotFix2]::GetForegroundWindow()))]"

# --- 4. Esc 取消遮罩（按两次，防止第一次被别的窗口吃掉）---
[ShotFix2]::Esc()
Pump 800
[ShotFix2]::Esc()
Pump 2600

# --- 5. 判定 ---
$finalIconic = [ShotFix2]::IsIconic($h)
$fgTitle = [ShotFix2]::TitleOf([ShotFix2]::GetForegroundWindow())
W "after cancel   : iconic=$finalIconic fg=[$fgTitle] rect=$([ShotFix2]::RectOf($h))"
W ("VERDICT=" + $(if ($finalIconic) { 'STILL-MINIMIZED' } else { 'GOT-RESTORED' }))

if (-not $finalIconic) { [void][ShotFix2]::ShowWindow($h, [ShotFix2]::SW_MINIMIZE) }
$form.Close()
$form.Dispose()
W "done"
Get-Content -Path $out -Encoding utf8
