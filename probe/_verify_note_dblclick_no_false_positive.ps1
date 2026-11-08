# 反例验证：已经处于就地编辑态时，双击选词不该弹出独立编辑器。
# 修复引入了"编辑态起始时间"时间窗来区分手势，必须证明它没有把正常选词也变成弹窗。
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class M2 {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, uint d, UIntPtr e);
    public static void Click(int x, int y) {
        SetCursorPos(x, y); System.Threading.Thread.Sleep(120);
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
    }
    public static void DoubleClick(int x, int y) {
        SetCursorPos(x, y); System.Threading.Thread.Sleep(150);
        for (int i = 0; i < 2; i++) {
            mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
            mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
            System.Threading.Thread.Sleep(40);
        }
    }
}
"@

$proc = Get-Process QuickDrawer -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $proc) { throw "QuickDrawer not running" }
Write-Host "pid=$($proc.Id)"

$root = [System.Windows.Automation.AutomationElement]::RootElement
$cond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $proc.Id)

function VisibleWindowCount {
    return $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond).Count
}

# 关掉可能已经开着的编辑器：只留主面板
$wins = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)
foreach ($w in $wins) {
    if ($w.Current.Name -ne 'QuickDrawer') {
        $pc = $w.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
        $pc.Close()
        Start-Sleep -Milliseconds 600
    }
}
Write-Host "windows before = $(VisibleWindowCount)"

# 打开面板
[M2]::SetCursorPos(1915, 500) | Out-Null
Start-Sleep -Milliseconds 1300
[M2]::SetCursorPos(1700, 400) | Out-Null
Start-Sleep -Milliseconds 700

$win = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $cond)
$bodyCond = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Text)),
    (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'NoteBodyText')),
    (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::IsOffscreenProperty, $false)))
$body = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $bodyCond)
if (-not $body) { throw "no visible note body" }
$r = $body.Current.BoundingRectangle
$cx = [int]($r.X + $r.Width / 2); $cy = [int]($r.Y + $r.Height / 2)

# 第一步：单击进入就地编辑态
[M2]::Click($cx, $cy) | Out-Null
Start-Sleep -Milliseconds 1200

# 确认正文已是编辑控件
$editCond = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Edit)),
    (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'NoteBodyEditor')))
$editor = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $editCond)
Write-Host "inline editor visible after single click: $($null -ne $editor)"
$baseline = VisibleWindowCount

# 第二步：等远超双击间隔之后，在编辑框里双击选词 —— 不该弹编辑器
Start-Sleep -Milliseconds 1500
[M2]::DoubleClick($cx, $cy) | Out-Null
Start-Sleep -Milliseconds 1500

$after = VisibleWindowCount
Write-Host "windows after word-select double-click = $after (baseline $baseline)"

if ($after -eq $baseline) {
    Write-Host "RESULT: PASS (word selection double-click did not open the editor)"
    exit 0
}
Write-Host "RESULT: FAIL (word selection wrongly opened the editor)"
exit 1
