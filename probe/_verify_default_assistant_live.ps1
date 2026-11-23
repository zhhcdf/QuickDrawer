# 默认助手门禁（第二部分）：设置页里改默认助手 → 当场生效
#
# 为什么单独一个脚本，而不是并进 _verify_default_assistant.ps1：
# 那边验的是"启动后是什么样"，是只读的；这边要真的去点设置页里的单选项，
# 会改用户 config.json 的 assistant.defaultProviderId —— 侵入性不同，分开跑更清楚。
#
# 步骤：开抽屉 → 进助手页 → 记下当前标签顺序 → 开设置 → 点目标站点 → 关设置
#       → 重新唤出抽屉 → 断言标签顺序变成「Chip<目标> 在最左」且 config.json 已落盘。
#
# 前置要求：目标站点**不能**是当前默认（否则"改完顺序对"是碰巧一致的假绿——
# 2026-11-23 实测踩过两次：默认本来就是 kimi 时点 kimi，before/after 完全相同，
# 断言照样 PASS，但根本没验证到重排）。脚本会自己判并直接报 FAIL。
#
# 用法：
#   $env:QD_EXE = 'D:\...\QuickDrawer.exe'
#   powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File probe\_verify_default_assistant_live.ps1
#
# 不传 -Target 时自动挑一个"当前不是默认"的站点来切，这样门禁可以直接跑，
# 不用人手先改 config（早先写死 -Target kimi，默认恰好是 kimi 时就假绿了）。
param([string]$Target = '')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class T {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, uint d, UIntPtr e);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    public static IntPtr FindByPrefix(uint procId, string prefix) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == procId && IsWindowVisible(h)) {
                StringBuilder t = new StringBuilder(256); GetWindowTextW(h, t, 256);
                if (t.ToString().StartsWith(prefix, StringComparison.Ordinal)) { found = h; return false; }
            }
            return true; }, IntPtr.Zero);
        return found;
    }
    public static void Click() {
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(60);
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
    }
}
"@

function Pump([int]$ms) {
    $end = [Environment]::TickCount + $ms
    while ([Environment]::TickCount -lt $end) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 10 }
}

$AE = [System.Windows.Automation.AutomationElement]
$CTS = [System.Windows.Automation.TreeScope]
$CTL = [System.Windows.Automation.ControlType]
$proc = Get-Process QuickDrawer -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $proc) { throw 'QuickDrawer not running' }
Write-Host "pid=$($proc.Id)"

# 唤醒抽屉
[void][T]::SetCursorPos(1915, 500); Pump 1500
[void][T]::SetCursorPos(1700, 400); Pump 700

$h = [T]::FindByPrefix([uint32]$proc.Id, 'QuickDrawer')
$win = $AE::FromHandle($h)

# 进助手页
$tab = $win.FindFirst($CTS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, 'TabAssistant')))
$tr = $tab.Current.BoundingRectangle
[void][T]::SetCursorPos([int]($tr.Left + $tr.Width/2), [int]($tr.Top + $tr.Height/2)); Pump 200
[T]::Click(); Pump 2000

function ChipOrder {
    $rc = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CTL::RadioButton)
    $rs = $win.FindAll($CTS::Descendants, $rc)
    $c = @()
    for ($i = 0; $i -lt $rs.Count; $i++) {
        $n = $rs[$i].Current.Name
        if ($n -and $n.StartsWith('Chip')) {
            $r = $rs[$i].Current.BoundingRectangle
            if ($r.Width -gt 0) { $c += [pscustomobject]@{ Name = $n; Left = $r.Left } }
        }
    }
    return ($c | Sort-Object Left | ForEach-Object { $_.Name })
}

$orderBefore = ChipOrder
Write-Host ("order before: " + ($orderBefore -join ', '))

# 站点 id → UIA 里的标签名。**必须显式列出**，不能靠"首字母大写"推导：
# deepseek 的标签是 ChipDeepSeek（大写 S），chatglm 的是 ChipGlm（连名字都不一样）。
# 早先用推导写成了 ChipDeepseek / ChipChatglm，断言靠 PowerShell 的 -eq 默认
# 忽略大小写侥幸通过 —— 这种"碰巧对"的断言不算验证过。
$ChipOf = @{ deepseek = 'ChipDeepSeek'; qwen = 'ChipQwen'; kimi = 'ChipKimi'; chatglm = 'ChipGlm' }

if (-not $Target) {
    # 挑第一个当前不在最左的站点（最左那个就是当前默认，切它没有意义）
    foreach ($c in @('deepseek', 'qwen', 'kimi', 'chatglm')) {
        if ($orderBefore[0] -ne $ChipOf[$c]) { $Target = $c; break }
    }
    Write-Host ("auto target = $Target")
}
if (-not $ChipOf.ContainsKey($Target)) { Write-Host "RESULT: FAIL (unknown target '$Target')"; exit 1 }
if (-not $Target) { Write-Host 'RESULT: FAIL (cannot pick target)'; exit 1 }

$expectChip = $ChipOf[$Target]
Write-Host ("expect leftmost after switch = $expectChip")

# 前置：目标必须不是当前默认，否则测不出重排（假绿）
if ($orderBefore[0] -ceq $expectChip) {
    Write-Host ''
    Write-Host "FAIL  目标站点已是当前默认（$expectChip），测不出重排；先把默认改成别的再跑" -ForegroundColor Red
    Write-Host 'RESULT: FAIL (precondition)'
    exit 1
}

# 开设置
$menuCond = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CTL::Button)),
    (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, 'Menu')))
$menuBtn = $win.FindFirst($CTS::Descendants, $menuCond)
$mb = $menuBtn.Current.BoundingRectangle
[void][T]::SetCursorPos([int]($mb.Left + $mb.Width/2), [int]($mb.Top + $mb.Height/2)); Pump 200
[T]::Click(); Pump 800

$rootEl = $AE::RootElement
$miCond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CTL::MenuItem)
$allMi = $rootEl.FindAll($CTS::Descendants, $miCond)
$settingsItem = $null
for ($i = 0; $i -lt $allMi.Count; $i++) {
    if ($allMi[$i].Current.Name -like '设置*') { $settingsItem = $allMi[$i]; break }
}
$settingsItem.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
Pump 1500

$setH = [T]::FindByPrefix([uint32]$proc.Id, 'QuickDrawer 设置')
if ($setH -eq [IntPtr]::Zero) { throw 'settings window not found' }
$setWin = $AE::FromHandle($setH)

# 点目标站点
$targetEl = $setWin.FindFirst($CTS::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, "DefaultAssistant:$Target")))
if (-not $targetEl) { throw "DefaultAssistant:$Target not found" }
$qr = $targetEl.Current.BoundingRectangle
Write-Host ("target=$Target rect=" + $qr)
[void][T]::SetCursorPos([int]($qr.Left + $qr.Width/2), [int]($qr.Top + $qr.Height/2)); Pump 250
[T]::Click(); Pump 1500

# 断言：设置页里 qwen 选中
$sel = $targetEl.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected
Write-Host "$Target selected in settings = $sel"

# 先关设置窗，再重新唤醒抽屉读顺序。
# 设置窗开着时抽屉多半已被 AutoHide 收起，此时 WPF 不做布局，UIA 读到的
# BoundingRectangle 是重排前的旧坐标 —— 必须让抽屉重新显示后才有意义。
try { $setWin.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close() } catch { }
Pump 800
[void][T]::SetCursorPos(1915, 500); Pump 1500
[void][T]::SetCursorPos(1700, 400); Pump 800

$h2 = [T]::FindByPrefix([uint32]$proc.Id, 'QuickDrawer')
$win = $AE::FromHandle($h2)

# 断言：助手页标签最左变成 ChipQwen
$order = ChipOrder
Write-Host ("order after: " + ($order -join ', '))

# 断言：配置文件落盘
$cfgPath = Join-Path $env:APPDATA 'QuickDrawer\config.json'
$cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Host ("config defaultProviderId = " + $cfg.assistant.defaultProviderId)

# 用 -ceq（区分大小写）：标签名是精确的，大小写错了说明映射表写错了。
$ok = $sel -and ($order[0] -ceq $expectChip) -and ($cfg.assistant.defaultProviderId -eq $Target)
Write-Host ''
if ($ok) { Write-Host 'RESULT: PASS'; exit 0 }
Write-Host 'RESULT: FAIL'
exit 1
