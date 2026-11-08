$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class QH {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    public static IntPtr FindByTitle(uint procId, string title) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == procId && IsWindowVisible(h)) {
                StringBuilder t = new StringBuilder(256); GetWindowTextW(h, t, 256);
                if (t.ToString() == title) { found = h; return false; }
            }
            return true; }, IntPtr.Zero);
        return found;
    }
    public static string ListTitles(uint procId) {
        var sb = new StringBuilder();
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == procId && IsWindowVisible(h)) {
                StringBuilder t = new StringBuilder(256); GetWindowTextW(h, t, 256);
                if (t.Length > 0) sb.Append(t.ToString()).Append(" | ");
            }
            return true; }, IntPtr.Zero);
        return sb.ToString();
    }
    // 编辑器窗口的标题取的是卡片名称（卡片没名字时才是"便签"），
    // 所以不能按固定标题找。这里排除主面板，取剩下的第一个可见顶层窗口。
    public static IntPtr FindOtherWindow(uint procId, string excludeTitle) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == procId && IsWindowVisible(h)) {
                StringBuilder t = new StringBuilder(256); GetWindowTextW(h, t, 256);
                if (t.Length > 0 && t.ToString() != excludeTitle) { found = h; return false; }
            }
            return true; }, IntPtr.Zero);
        return found;
    }
}
"@

$proc = Get-Process -Name QuickDrawer | Select-Object -First 1
Write-Output "pid=$($proc.Id)"

# 触发面板滑出：先把光标贴到右边缘的拉手上，等它展开；
# 随后立刻把光标移进面板内部 —— 否则自动收起逻辑（光标离开面板 400ms）会把面板收掉，
# 我们就抓不到里面的控件了。
[void][QH]::SetCursorPos(1915, 500)
Start-Sleep -Milliseconds 1200
[void][QH]::SetCursorPos(1700, 500)
Start-Sleep -Milliseconds 600
Write-Output ("visible windows: " + [QH]::ListTitles([uint32]$proc.Id))

$AE = [Windows.Automation.AutomationElement]
$cond = New-Object Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $proc.Id)
$root = $AE::RootElement
$win = $root.FindFirst([Windows.Automation.TreeScope]::Children, $cond)
if ($null -eq $win) { Write-Output 'FAIL=no main window'; exit 1 }

# 注意：WPF 的 AutomationProperties.Name 映射到 UIA 的 Name 属性，
# AutomationId 是空的。历史脚本 probe/_uia_note_header.ps1 用的就是 NameProperty。
# 之前按 AutomationIdProperty 查，才会出现"按钮明明在屏幕上却找不到"的假故障。
function Find-ByName($scope, $name) {
    $c = New-Object Windows.Automation.PropertyCondition($AE::NameProperty, $name)
    return $scope.FindFirst([Windows.Automation.TreeScope]::Descendants, $c)
}

# ✎ 按钮
$btn = Find-ByName $win 'EditCard'
if ($null -eq $btn) { Write-Output 'FAIL=EditCard button not found'; exit 1 }
$r = $btn.Current.BoundingRectangle
Write-Output ("EditCard found  name=$($btn.Current.Name) rect={0},{1} {2}x{3} offscreen={4}" -f [int]$r.X, [int]$r.Y, [int]$r.Width, [int]$r.Height, $btn.Current.IsOffscreen)

# 点它
$inv = $btn.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)
$inv.Invoke()
Start-Sleep -Milliseconds 1500

Write-Output ("visible windows after: " + [QH]::ListTitles([uint32]$proc.Id))
$mainTitle = 'QuickDrawer'
$eh = [QH]::FindOtherWindow([uint32]$proc.Id, $mainTitle)
if ($eh -eq [IntPtr]::Zero) {
    Write-Output 'FAIL=editor window not found'
    exit 1
}
Write-Output "editor window found hwnd=$eh"

$ewin = $AE::FromHandle($eh)
$box = Find-ByName $ewin 'NoteEditorText'
if ($null -eq $box) { Write-Output 'FAIL=NoteEditorText not found'; exit 1 }
$vp = $box.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
$before = $vp.Current.Value
Write-Output ("editor text = " + ($before -replace "`r`n", '\r\n'))

# 统计行：TextBlock 的 Name 就是文本内容，按 AutomationId 找
function Find-ById($scope, $id) {
    $c = New-Object Windows.Automation.PropertyCondition($AE::AutomationIdProperty, $id)
    return $scope.FindFirst([Windows.Automation.TreeScope]::Descendants, $c)
}
$stat = Find-ById $ewin 'NoteStat'
if ($null -ne $stat) { Write-Output ("stat = " + $stat.Current.Name) }
else { Write-Output 'stat element not found' }

# 改内容，用「完成」关闭
$marker = '端到端测试写入'
$vp.SetValue($marker + "`r`n" + '第二行')
Start-Sleep -Milliseconds 800
$stat2 = Find-ById $ewin 'NoteStat'
if ($null -ne $stat2) { Write-Output ("stat after edit = " + $stat2.Current.Name) }

$done = Find-ByName $ewin 'NoteDone'
if ($null -eq $done) { Write-Output 'FAIL=NoteDone not found'; exit 1 }
$done.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
Start-Sleep -Milliseconds 1500

$still = [QH]::FindOtherWindow([uint32]$proc.Id, $mainTitle)
Write-Output ("editor still open after Done: " + ($still -ne [IntPtr]::Zero))

$notes = Join-Path $env:APPDATA 'QuickDrawer\notes.json'
# notes.json 用 System.Text.Json 写，非 ASCII 字符会变成 \uXXXX 转义（od -c 可见），
# 所以不能直接 Contains 中文。反序列化后再比。
$obj = Get-Content -LiteralPath $notes -Raw -Encoding UTF8 | ConvertFrom-Json
$has = $false
foreach ($n in $obj.notes) { if ($n.Text -and $n.Text.Contains($marker)) { $has = $true } }
Write-Output ("notes.json contains new text: $has")

if ($still -ne [IntPtr]::Zero) { Write-Output 'RESULT: FAIL (editor did not close)'; exit 1 }
if (-not $has) { Write-Output 'RESULT: FAIL (text not persisted)'; exit 1 }
Write-Output 'RESULT: PASS'
