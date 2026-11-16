# 应用区右键「以管理员身份打开」门禁（2026-11-16）
#
# 分两层验：
#   A. 反射层（不需要界面）—— 提权判定的边界条件、runas 常量、LaunchTarget 的两个重载。
#      这一层能抓住"菜单里给了这一项，但 CanRunElevated 判错，点了必然失败"这类错。
#   B. 界面层（真开抽屉、真右键）—— 菜单里确实出现这一项、可用、位置在分隔线之上。
#      UAC 弹窗本身没法自动点，所以本门禁**不**真的触发提权，只验到"调用链就位"。
#
# 用法：
#   $env:QD_EXE = 'D:\...\QuickDrawer.exe'
#   powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File probe\_verify_app_runas.ps1
#
# 必须 STA：要建 WPF 类型、要用 UIA。

param(
    [string]$Exe = $env:QD_EXE
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
if (-not $Exe) {
    $Exe = Join-Path $root 'publish\QuickDrawer.exe'
}
if (-not (Test-Path -LiteralPath $Exe)) {
    throw "QD_EXE not found: $Exe"
}

$script:failures = 0
$script:checks = 0

function Check([string]$name, [bool]$ok, [string]$detail = '') {
    $script:checks++
    if ($ok) {
        Write-Host ("PASS  {0}{1}" -f $name, $(if ($detail) { "  $detail" } else { '' }))
    }
    else {
        $script:failures++
        Write-Host ("FAIL  {0}{1}" -f $name, $(if ($detail) { "  $detail" } else { '' })) -ForegroundColor Red
    }
}

Write-Host "exe: $Exe"

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

# ===========================================================================
# A. 反射层
# ===========================================================================
$asm = [System.Reflection.Assembly]::LoadFrom($Exe)
Check 'assembly loaded' ($null -ne $asm) $asm.GetName().Name

$staticFlags = [System.Reflection.BindingFlags]'Public,NonPublic,Static'
$instFlags = [System.Reflection.BindingFlags]'Public,NonPublic,Instance'

# --- CanRunElevated 的存在与签名 -------------------------------------------
$storeType = $asm.GetType('QuickDrawer.ShortcutStore')
Check 'ShortcutStore type exists' ($null -ne $storeType)

$canRun = $storeType.GetMethod('CanRunElevated', $staticFlags)
Check 'ShortcutStore.CanRunElevated exists (static)' ($null -ne $canRun)
$canRunOk = ($null -ne $canRun) -and
            ($canRun.ReturnType -eq [bool]) -and
            ($canRun.GetParameters().Count -eq 1) -and
            ($canRun.GetParameters()[0].ParameterType.Name -eq 'ShortcutItem')
Check 'CanRunElevated(bool) <- (ShortcutItem)' $canRunOk

$itemType = $asm.GetType('QuickDrawer.ShortcutItem')
Check 'ShortcutItem type exists' ($null -ne $itemType)

# --- 造测试条目 ------------------------------------------------------------
function New-Item2([string]$kind, [string]$target) {
    $it = [System.Activator]::CreateInstance($itemType)
    $itemType.GetProperty('Kind').SetValue($it, $kind)
    $itemType.GetProperty('Target').SetValue($it, $target)
    return $it
}

$exePath = (Resolve-Path -LiteralPath $Exe).Path
$dirPath = Split-Path -Parent $exePath
$tmpTxt = Join-Path $env:TEMP ('qd_runas_' + [Guid]::NewGuid().ToString('N') + '.txt')
Set-Content -LiteralPath $tmpTxt -Value 'x' -Encoding ASCII
$missing = Join-Path $env:TEMP ('qd_missing_' + [Guid]::NewGuid().ToString('N') + '.exe')

try {
    $cases = @(
        @{ Label = 'app + 存在的 exe';       Item = (New-Item2 'app'  $exePath);    Expect = $true },

        # 这三条是"不该出现在可提权项里就判错"的反例：
        @{ Label = 'app + 目录';             Item = (New-Item2 'app'  $dirPath);    Expect = $false },
        @{ Label = 'app + 不存在的路径';     Item = (New-Item2 'app'  $missing);    Expect = $false },
        @{ Label = 'file + 存在的 exe';      Item = (New-Item2 'file' $exePath);    Expect = $false },
        @{ Label = 'dir + 存在的目录';       Item = (New-Item2 'dir'  $dirPath);    Expect = $false },
        @{ Label = 'app + 存在的 .txt';      Item = (New-Item2 'app'  $tmpTxt);     Expect = $false }
    )

    foreach ($c in $cases) {
        $got = [bool]$canRun.Invoke($null, @($c.Item))
        Check ("CanRunElevated: " + $c.Label) ($got -eq $c.Expect) ("got=" + $got + " expect=" + $c.Expect)
    }
}
finally {
    Remove-Item -LiteralPath $tmpTxt -Force -ErrorAction SilentlyContinue
}

# --- runas 常量与错误码 ----------------------------------------------------
$nativeType = $asm.GetType('QuickDrawer.Native.NativeMethods')
Check 'NativeMethods type exists' ($null -ne $nativeType)

$verbField = $nativeType.GetField('VERB_RUNAS', $staticFlags)
Check 'VERB_RUNAS exists' ($null -ne $verbField)
if ($verbField) {
    Check 'VERB_RUNAS == "runas"' ($verbField.GetValue($null) -eq 'runas') ("= '" + $verbField.GetValue($null) + "'")
}

$threshField = $nativeType.GetField('ShellExecuteSuccessThreshold', $staticFlags)
Check 'ShellExecuteSuccessThreshold == 32' (($null -ne $threshField) -and ($threshField.GetValue($null) -eq 32))

$deniedField = $nativeType.GetField('ERROR_ACCESS_DENIED', $staticFlags)
Check 'ERROR_ACCESS_DENIED == 5' (($null -ne $deniedField) -and ($deniedField.GetValue($null) -eq 5))

# --- IsProcessElevated -----------------------------------------------------
$isElev = $nativeType.GetMethod('IsProcessElevated', $staticFlags)
Check 'NativeMethods.IsProcessElevated exists (static, -> bool)' (
    ($null -ne $isElev) -and ($isElev.ReturnType -eq [bool]) -and ($isElev.GetParameters().Count -eq 0))

if ($isElev) {
    $elevated = [bool]$isElev.Invoke($null, @())

    # 交叉核对：与 .NET 自己的判断比。本门禁脚本是在普通（非提权）终端里跑的，
    # 若两边不一致，说明 P/Invoke 那条路不可信。
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
    $isAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)

    Write-Host ("      IsProcessElevated=" + $elevated + "  IsInRole(Administrator)=" + $isAdmin)
    Check 'IsProcessElevated 与 IsInRole(Administrator) 一致' ($elevated -eq $isAdmin)

    if (-not $isAdmin) {
        Check '未提权终端下 IsProcessElevated == false' ($elevated -eq $false)
    }
}

# --- LaunchTarget 的两个重载 -----------------------------------------------
$drawerType = $asm.GetType('QuickDrawer.DrawerWindow')
Check 'DrawerWindow type exists' ($null -ne $drawerType)

$overloads = @($drawerType.GetMethods($staticFlags) | Where-Object { $_.Name -eq 'LaunchTarget' })
Check 'LaunchTarget 有两个重载' ($overloads.Count -eq 2) ("count=" + $overloads.Count)

$oneArg = $overloads | Where-Object { $_.GetParameters().Count -eq 1 }
$twoArg = $overloads | Where-Object { $_.GetParameters().Count -eq 2 }
Check 'LaunchTarget(ShortcutItem) 存在' ($null -ne $oneArg)
$twoArgOk = ($null -ne $twoArg) -and
            ($twoArg.GetParameters()[0].ParameterType.Name -eq 'ShortcutItem') -and
            ($twoArg.GetParameters()[1].ParameterType -eq [bool])
Check 'LaunchTarget(ShortcutItem, bool) 存在' $twoArgOk

# ===========================================================================
# B. 界面层：真开抽屉、真右键、真看菜单
# ===========================================================================
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class MR {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, uint d, UIntPtr e);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    public static IntPtr Find(uint procId, string title) {
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
    public static void RightClick() {
        mouse_event(0x0008, 0, 0, 0, UIntPtr.Zero);   // RIGHTDOWN
        System.Threading.Thread.Sleep(60);
        mouse_event(0x0010, 0, 0, 0, UIntPtr.Zero);   // RIGHTUP
    }
}
"@

Add-Type -AssemblyName System.Windows.Forms

function Pump([int]$ms) {
    $end = [Environment]::TickCount + $ms
    while ([Environment]::TickCount -lt $end) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 10
    }
}

$proc = Get-Process -Name QuickDrawer -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $proc) {
    Write-Host 'SKIP 界面层：QuickDrawer 没在运行（反射层结果如上）'
    Write-Host ''
    if ($script:failures -gt 0) { Write-Host ("RESULT: FAIL ({0}/{1} checks)" -f $script:failures, $script:checks); exit 1 }
    Write-Host ("RESULT: PASS ({0} checks, 界面层跳过)" -f $script:checks)
    exit 0
}

Write-Host ("pid=" + $proc.Id)

# 打开抽屉：光标停到屏幕右缘（与其它门禁一致的唤出方式）
[void][MR]::SetCursorPos(1915, 500)
Pump 1500
[void][MR]::SetCursorPos(1700, 400)
Pump 600

$h = [MR]::Find([uint32]$proc.Id, 'QuickDrawer')
Check '抽屉窗口可见' ($h -ne [IntPtr]::Zero)
if ($h -eq [IntPtr]::Zero) {
    Write-Host ''
    Write-Host ("RESULT: FAIL ({0}/{1} checks)" -f $script:failures, $script:checks)
    exit 1
}

$AE = [System.Windows.Automation.AutomationElement]
$CTS = [System.Windows.Automation.TreeScope]
$CTL = [System.Windows.Automation.ControlType]

$win = $AE::FromHandle($h)

# --- 找到第一块应用磁贴 ----------------------------------------------------
$appListCond = New-Object System.Windows.Automation.PropertyCondition($AE::AutomationIdProperty, 'AppsList')
$appList = $win.FindFirst($CTS::Descendants, $appListCond)
Check 'AppsList 找到' ($null -ne $appList)

if ($null -eq $appList) {
    Write-Host ''
    Write-Host ("RESULT: FAIL ({0}/{1} checks)" -f $script:failures, $script:checks)
    exit 1
}

$btnCond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CTL::Button)
$tiles = $appList.FindAll($CTS::Descendants, $btnCond)
Check '应用磁贴数量 > 0' ($tiles.Count -gt 0) ("count=" + $tiles.Count)

if ($tiles.Count -eq 0) {
    Write-Host ''
    Write-Host ("RESULT: FAIL ({0}/{1} checks)" -f $script:failures, $script:checks)
    exit 1
}

$tile = $tiles[0]
$tr = $tile.Current.BoundingRectangle
$cx = [int]($tr.Left + $tr.Width / 2)
$cy = [int]($tr.Top + $tr.Height / 2)
Write-Host ("tile[0] rect={0} center={1},{2}" -f $tr, $cx, $cy)

# --- 真右键 ----------------------------------------------------------------
[void][MR]::SetCursorPos($cx, $cy)
Pump 250
[MR]::RightClick()
Pump 700

# 菜单是独立 Popup 窗口，不在抽屉的 UIA 子树里，要从桌面上找。
# 注意不能直接把"桌面上所有 MenuItem"当成这个菜单 —— 屏幕上可能同时有别的
# 弹出菜单（实测就混进过「应用 / 编辑」两项，导致"共几项"和"第几项"的断言
# 被其它菜单污染）。正确做法：先定位到含目标项的 Popup 根，再只数它内部的项。
$root2 = $AE::RootElement
$menuItemCond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CTL::MenuItem)
$allMenuItems = $root2.FindAll($CTS::Descendants, $menuItemCond)

$target = $null
for ($i = 0; $i -lt $allMenuItems.Count; $i++) {
    $n = $allMenuItems[$i].Current.Name
    if ($n -and $n.StartsWith('以管理员身份打开')) { $target = $allMenuItems[$i]; break }
}

Check '菜单里有「以管理员身份打开」' ($null -ne $target)

# 从这个菜单项往上爬到 Popup 根（类名 Popup / HwndWrapper... 的独立窗口），
# 再只在这个根里数菜单项。这样别的弹出菜单不会混进来。
$names = New-Object System.Collections.Generic.List[string]
if ($target) {
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $popupRoot = $target
    for ($i = 0; $i -lt 12; $i++) {
        $parent = $walker.GetParent($popupRoot)
        if ($null -eq $parent) { break }
        if ($parent -eq $root2) { break }
        if ($parent.Current.ControlType -eq $CTL::Window) { $popupRoot = $parent; break }
        $popupRoot = $parent
    }

    $inMenu = $popupRoot.FindAll($CTS::Descendants, $menuItemCond)
    for ($i = 0; $i -lt $inMenu.Count; $i++) {
        $n = $inMenu[$i].Current.Name
        if ($n) { $names.Add($n) }
    }
}

Write-Host ("菜单项: " + ($names -join ' | '))

Check '右键菜单出现' ($names.Count -gt 0) ("items=" + $names.Count)
Check '菜单项数与预期一致（4 项）' ($names.Count -eq 4) ("items=" + $names.Count)

if ($target) {
    Check '该项可用（磁贴是存在的 exe）' ([bool]$target.Current.IsEnabled)

    # 位置：必须在第一条分隔线之上，也就是菜单里的第 0 项。
    # 顺序即 UIA 的 tree order，与视觉顺序一致。
    if ($names.Count -gt 0) {
        Check '该项在菜单第一组（第 0 项）' ($names[0].StartsWith('以管理员身份打开')) ("first=" + $names[0])
    }
}

# --- 关掉菜单，别把弹窗留在屏幕上 ------------------------------------------
[void][MR]::SetCursorPos(1700, 400)
Pump 200
[System.Windows.Forms.SendKeys]::SendWait('{ESC}')
Pump 300

Write-Host ''
if ($script:failures -gt 0) {
    Write-Host ("RESULT: FAIL ({0}/{1} checks)" -f $script:failures, $script:checks)
    exit 1
}
Write-Host ("RESULT: PASS ({0} checks)" -f $script:checks)
exit 0
