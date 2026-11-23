# 双击便签正文是否真的能打开编辑器 —— 用真实鼠标事件（SendInput 级）验证。
# 结论字段：DIAG 行（diag.log 里 [note] 的条数变化）。
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class M {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, uint d, UIntPtr e);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }

    public static void Click(int x, int y) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(120);
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
    }

    public static void DoubleClick(int x, int y) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(150);
        // 连着两次 down/up，间隔很短 —— ClickCount 会累加成 2
        for (int i = 0; i < 2; i++) {
            mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
            mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
            System.Threading.Thread.Sleep(40);
        }
    }
}
"@

$exe = 'D:\software\QuickDrawer-publish-net48\QuickDrawer.exe'
$proc = Get-Process QuickDrawer -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $proc) { throw "QuickDrawer not running" }
Write-Host "pid=$($proc.Id)"

$log = Join-Path $env:APPDATA 'QuickDrawer\logs\diag.log'
function NoteCount {
    if (-not (Test-Path $log)) { return 0 }
    return @(Select-String -LiteralPath $log -Pattern '\[note\] editor opened' -SimpleMatch -ErrorAction SilentlyContinue).Count
}

$before = NoteCount
Write-Host "note-open count before = $before"

# 1) 把光标放到右边缘拉手处，等面板弹出，再移进面板内部保持不收起
[M]::SetCursorPos(1915, 500) | Out-Null
Start-Sleep -Milliseconds 1300
[M]::SetCursorPos(1700, 400) | Out-Null
Start-Sleep -Milliseconds 700

# 2) 找 NoteBodyText（UIA Name 是 '<正文>' 之类，用 ControlType.Text + 位置更稳）
$root = [System.Windows.Automation.AutomationElement]::RootElement
$cond = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $proc.Id)
$win = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $cond)
if (-not $win) { throw "QuickDrawer window not found" }
Write-Host "panel: $($win.Current.Name)"

# 先确保在"便签"页 —— 这两道门禁假定当前是便签页，但抽屉上次停在哪个标签
# 取决于之前跑过什么（比如刚跑完助手页门禁就停在助手页）。
# 不补这一步，会以 "no visible note body" 报错，看着像功能回归，其实是前置条件没满足。
# 注意：TabNotes 的标识在 AutomationId 里（Name 是"📝 便签"），
# 而 TabAssistant 的标识在 Name 里（XAML 里显式写了 AutomationProperties.Name）。
# 两个标签写法不一致，只查 Name 会找不到 —— 用 Or 两种都查。
$tabCond = New-Object System.Windows.Automation.OrCondition(
    (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'TabNotes')),
    (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty, 'TabNotes')))
$tab = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $tabCond)
if ($tab) {
    $tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Start-Sleep -Milliseconds 600
}
$win = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $cond)

$textCond = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Text)),
    (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'NoteBodyText')),
    (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::IsOffscreenProperty, $false)))

$bodies = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $textCond)
Write-Host "visible bodies = $($bodies.Count)"
if ($bodies.Count -eq 0) { throw "no visible note body" }

$target = $bodies.Item(0)
$r = $target.Current.BoundingRectangle
Write-Host ("body rect = {0},{1} {2}x{3}" -f $r.X, $r.Y, $r.Width, $r.Height)

$cx = [int]($r.X + $r.Width / 2)
$cy = [int]($r.Y + $r.Height / 2)
Write-Host "double-clicking at $cx,$cy"

[M]::DoubleClick($cx, $cy) | Out-Null
Start-Sleep -Milliseconds 1500

$after = NoteCount
Write-Host "note-open count after = $after"

# 假设验证：双击后正文位置是否出现了 Edit 控件（= 第一下把阅读态切成了编辑态，
# 于是第二下落在 TextBox 上，TextBlock 的 MouseLeftButtonDown 收不到 ClickCount==2）
$editCond = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Edit)),
    (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::IsOffscreenProperty, $false)))
$edits = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $editCond)
$editInfo = @()
foreach ($ed in $edits) {
    $rect = $ed.Current.BoundingRectangle
    $editInfo += ("id='{0}' name='{1}' {2},{3} {4}x{5}" -f $ed.Current.AutomationId, $ed.Current.Name, [int]$rect.X, [int]$rect.Y, [int]$rect.Width, [int]$rect.Height)
}
Write-Host "visible Edit controls after double-click:"
$editInfo | ForEach-Object { Write-Host "  $_" }
Write-Host ("body was at {0},{1} — an Edit overlapping there means the first click switched to inline edit" -f $cx, $cy)

# 3) 看看有没有出现第二个可见窗口（编辑器）
$wins = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)
$titles = @()
foreach ($w in $wins) { $titles += $w.Current.Name }
Write-Host ("visible windows: {0}" -f ($titles -join ' | '))

# 判据用"是否多出一个可见顶层窗口"，不要用 diag.log 里的 [note] 行数：
# diag.log 含 NUL 字节，Select-String 会按二进制处理，计数恒为 0（曾因此误判 FAIL）。
$opened = $titles.Count -gt 1
if ($opened) {
    Write-Host "RESULT: PASS (double-click opened the editor window)"
    exit 0
}
Write-Host "RESULT: FAIL (double-click did NOT open the editor)"
exit 1
