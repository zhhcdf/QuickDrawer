# 默认助手页门禁（2026-11-23 用户需求）
#
# 需求原文：「在设置里添加一项设置：可选默认加载AI助手页，选择的助手页调整到标签最左侧。
#            助手在应用启动后后台自动加载默认助手。初始默认助手设置为Deepseek。」
#
# 分三层验：
#   A. 反射层（不需要界面）
#      1. AssistantConfig.DefaultProviderId 存在，且**新建实例**的初值是 deepseek
#         —— 这是"初始默认助手设置为 Deepseek"的直接证据。
#      2. AssistantConfig.ActiveProviderId 仍然是独立的一项（不能被合并掉，
#         否则"上次在看哪个"和"启动用哪个"就分不开了）。
#      3. AssistantService.PreloadAsync(AssistantProvider) 存在且返回 Task<bool>。
#      4. DrawerWindow.ApplyDefaultAssistant(bool) 存在。
#   B. 启动层（读 diag.log）
#      启动后必须有这两行，证明"后台自动加载默认助手"真的发生了：
#         [assistant] default provider = <id> (startup)
#         [assistant] preloaded <id>
#      diag.log 含 NUL 字节，Select-String 会当二进制跳过 —— 必须 ReadAllText 再匹配。
#   C. 界面层（真开抽屉、真点设置）
#      1. 助手页四个站点标签，最左那个的 UIA Name 必须是 Chip<默认站点>。
#      2. 设置页里有四个「默认助手」单选，且默认站点那个是选中态。
#
# 用法：
#   $env:QD_EXE = 'D:\...\QuickDrawer.exe'      # 必须是含本次改动的构建
#   $env:QD_DEFAULT = 'deepseek'                # 期望的默认站点（可选，默认 deepseek）
#   powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File probe\_verify_default_assistant.ps1
#
# 必须 STA：要读 WPF 程序集的 UIA、要建 WinForms 消息泵。

param(
    [string]$Exe = $env:QD_EXE,
    [string]$ExpectDefault = $env:QD_DEFAULT
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
if (-not $Exe) { $Exe = Join-Path $root 'publish\QuickDrawer.exe' }
if (-not (Test-Path -LiteralPath $Exe)) { throw "QD_EXE not found: $Exe" }
if (-not $ExpectDefault) { $ExpectDefault = 'deepseek' }

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
Write-Host "expect default: $ExpectDefault"

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms

# ===========================================================================
# A. 反射层
# ===========================================================================
$asm = [System.Reflection.Assembly]::LoadFrom($Exe)
Check 'assembly loaded' ($null -ne $asm) $asm.GetName().Name

$staticFlags = [System.Reflection.BindingFlags]'Public,NonPublic,Static'
$instFlags = [System.Reflection.BindingFlags]'Public,NonPublic,Instance'

# --- AssistantConfig.DefaultProviderId -------------------------------------
$cfgType = $asm.GetType('QuickDrawer.AssistantConfig')
Check 'AssistantConfig type exists' ($null -ne $cfgType)

$defaultProp = $cfgType.GetProperty('DefaultProviderId', $instFlags)
Check 'AssistantConfig.DefaultProviderId 存在' ($null -ne $defaultProp) `
    $(if ($defaultProp) { $defaultProp.PropertyType.Name } else { '' })
Check 'DefaultProviderId 是 string' ($defaultProp -and $defaultProp.PropertyType -eq [string])

# 关键：新建一个实例，看**代码里的初值**，不看用户 config.json。
$freshCfg = [System.Activator]::CreateInstance($cfgType)
$freshDefault = $defaultProp.GetValue($freshCfg)
Check '新建配置的默认助手是 deepseek' ($freshDefault -eq 'deepseek') "value=$freshDefault"

# 与 ActiveProviderId 必须是两个独立属性：合并了就分不清"启动用哪个"和"上次在看哪个"。
$activeProp = $cfgType.GetProperty('ActiveProviderId', $instFlags)
Check 'ActiveProviderId 仍独立存在' ($null -ne $activeProp)

# --- AssistantService.PreloadAsync ----------------------------------------
$svcType = $asm.GetType('QuickDrawer.Assistant.AssistantService')
Check 'AssistantService type exists' ($null -ne $svcType)

$preload = $svcType.GetMethod('PreloadAsync', $instFlags)
Check 'AssistantService.PreloadAsync 存在' ($null -ne $preload)
$preloadOk = ($null -ne $preload) -and
             ($preload.ReturnType -eq [System.Threading.Tasks.Task[bool]]) -and
             ($preload.GetParameters().Count -eq 1) -and
             ($preload.GetParameters()[0].ParameterType.Name -eq 'AssistantProvider')
Check 'PreloadAsync(Task<bool>) <- (AssistantProvider)' $preloadOk `
    $(if ($preload) { "returns=" + $preload.ReturnType.Name } else { '' })

# EnsureAsync 必须还在（预加载是新增路径，不能把原路径改坏了）
$ensure = $svcType.GetMethod('EnsureAsync', $instFlags)
Check 'EnsureAsync 仍然存在（原路径未被改坏）' ($null -ne $ensure)

# --- DrawerWindow.ApplyDefaultAssistant -----------------------------------
$drawerType = $asm.GetType('QuickDrawer.DrawerWindow')
Check 'DrawerWindow type exists' ($null -ne $drawerType)

$applyDefault = $drawerType.GetMethod('ApplyDefaultAssistant', $instFlags)
Check 'DrawerWindow.ApplyDefaultAssistant 存在' ($null -ne $applyDefault)
$applyOk = ($null -ne $applyDefault) -and
           ($applyDefault.GetParameters().Count -eq 1) -and
           ($applyDefault.GetParameters()[0].ParameterType -eq [bool])
Check 'ApplyDefaultAssistant(bool)' $applyOk

# ===========================================================================
# B. 启动层：diag.log 里必须留下启动时用了默认助手、且预加载成功的痕迹
# ===========================================================================
$log = Join-Path $env:APPDATA 'QuickDrawer\logs\diag.log'
Check 'diag.log 存在' (Test-Path -LiteralPath $log) $log

if (Test-Path -LiteralPath $log) {
    # 不能 Select-String：日志里含 NUL 字节，会被当二进制文件整篇跳过。
    $text = [System.IO.File]::ReadAllText($log)

    $startupRe = [regex]'\[assistant\] default provider = (\w+) \(startup\)'
    $startupHit = $startupRe.Matches($text)
    $lastStartup = if ($startupHit.Count -gt 0) { $startupHit[$startupHit.Count - 1].Groups[1].Value } else { '' }
    Check '启动时应用了默认助手（日志有 default provider … (startup)）' `
        ($startupHit.Count -gt 0) `
        $(if ($startupHit.Count -gt 0) { "hit=$lastStartup count=" + $startupHit.Count } else { 'no hit' })
    Check '启动时用的默认助手 == 期望值' ($lastStartup -eq $ExpectDefault) `
        "last=$lastStartup expect=$ExpectDefault"

    $preloadRe = [regex]'\[assistant\] preloaded (\w+)'
    $preloadHit = $preloadRe.Matches($text)
    $lastPreload = if ($preloadHit.Count -gt 0) { $preloadHit[$preloadHit.Count - 1].Groups[1].Value } else { '' }
    Check '启动后后台预加载了默认助手（日志有 preloaded …）' `
        ($preloadHit.Count -gt 0) `
        $(if ($preloadHit.Count -gt 0) { "hit=$lastPreload count=" + $preloadHit.Count } else { 'no hit' })
    Check '预加载的站点 == 默认站点' ($lastPreload -eq $ExpectDefault) `
        "last=$lastPreload expect=$ExpectDefault"

    # 预加载失败也要抓出来（失败只有 preload failed，不会有 preloaded）
    $preloadFail = $text.LastIndexOf('[assistant] preload failed', [StringComparison]::Ordinal)
    $preloadDone = $text.LastIndexOf('[assistant] preloaded', [StringComparison]::Ordinal)
    Check '最近一次预加载没有失败' ($preloadFail -lt $preloadDone) `
        "failedAt=$preloadFail doneAt=$preloadDone"
}

# ===========================================================================
# C. 界面层
# ===========================================================================
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class MR2 {
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
    /// <summary>
    /// 按标题前缀找本进程的可见顶层窗口。
    ///
    /// 为什么不能靠 UIA 的 RootElement 找设置窗口：实测（2026-11-23）设置窗口明明
    /// 可见（hwnd 可 EnumWindows 到、标题「QuickDrawer 设置」），
    /// 但 RootElement.FindAll(Children) 里只列出抽屉那个窗口 ——
    /// 设置窗口是 Owner 指向抽屉的 WPF 窗口，UIA 的桌面 Children 里查不到它。
    /// 所以先按 HWND 找到，再 FromHandle 转 UIA 元素。
    /// </summary>
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
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);   // LEFTDOWN
        System.Threading.Thread.Sleep(60);
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);   // LEFTUP
    }
}
"@

function Pump([int]$ms) {
    $end = [Environment]::TickCount + $ms
    while ([Environment]::TickCount -lt $end) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 10
    }
}

$proc = Get-Process -Name QuickDrawer -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $proc) {
    Write-Host 'SKIP 界面层：QuickDrawer 没在运行'
    Write-Host ''
    if ($script:failures -gt 0) { Write-Host ("RESULT: FAIL ({0}/{1} checks)" -f $script:failures, $script:checks); exit 1 }
    Write-Host ("RESULT: PASS ({0} checks, 界面层跳过)" -f $script:checks)
    exit 0
}
Write-Host ("pid=" + $proc.Id)

$AE = [System.Windows.Automation.AutomationElement]
$CTS = [System.Windows.Automation.TreeScope]
$CTL = [System.Windows.Automation.ControlType]

# --- 打开抽屉 --------------------------------------------------------------
[void][MR2]::SetCursorPos(1915, 500)
Pump 1500
[void][MR2]::SetCursorPos(1700, 400)
Pump 600

$h = [MR2]::Find([uint32]$proc.Id, 'QuickDrawer')
Check '抽屉窗口可见' ($h -ne [IntPtr]::Zero)
if ($h -eq [IntPtr]::Zero) {
    Write-Host ''
    Write-Host ("RESULT: FAIL ({0}/{1} checks)" -f $script:failures, $script:checks)
    exit 1
}
$win = $AE::FromHandle($h)

# --- 切到助手页 ------------------------------------------------------------
$tabCond = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, 'TabAssistant')
$tab = $win.FindFirst($CTS::Descendants, $tabCond)
Check '助手页标签 TabAssistant 找到' ($null -ne $tab)
if ($null -eq $tab) {
    Write-Host ''
    Write-Host ("RESULT: FAIL ({0}/{1} checks)" -f $script:failures, $script:checks)
    exit 1
}

# 用真实点击而不是 Invoke：Invoke 在某些 WPF 版本上不触发 Checked 里的异步导航
$tr = $tab.Current.BoundingRectangle
[void][MR2]::SetCursorPos([int]($tr.Left + $tr.Width / 2), [int]($tr.Top + $tr.Height / 2))
Pump 200
[MR2]::Click()
Pump 2500

# --- 站点标签顺序 ----------------------------------------------------------
$radioCond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CTL::RadioButton)
$radios = $win.FindAll($CTS::Descendants, $radioCond)

$chips = @()
for ($i = 0; $i -lt $radios.Count; $i++) {
    $n = $radios[$i].Current.Name
    if ($n -and $n.StartsWith('Chip')) {
        $r = $radios[$i].Current.BoundingRectangle
        if ($r.Width -gt 0 -and $r.Height -gt 0) {
            $chips += [pscustomobject]@{ Name = $n; Left = $r.Left; Top = $r.Top }
        }
    }
}

Check '助手页站点标签数量 == 4' ($chips.Count -eq 4) ("count=" + $chips.Count)

if ($chips.Count -gt 0) {
    $sorted = $chips | Sort-Object Left
    $leftmost = $sorted[0].Name
    Write-Host ("chip order (left->right): " + (($sorted | ForEach-Object { $_.Name }) -join ', '))
    Check '默认站点排在最左' ($leftmost -eq "Chip$ExpectDefault") "leftmost=$leftmost"
}

# --- 设置页里的默认助手选择 ------------------------------------------------
$menuCond = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CTL::Button)),
    (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, 'Menu')))
$menuBtn = $win.FindFirst($CTS::Descendants, $menuCond)
Check '面板菜单按钮找到' ($null -ne $menuBtn)

if ($null -ne $menuBtn) {
    $mb = $menuBtn.Current.BoundingRectangle
    [void][MR2]::SetCursorPos([int]($mb.Left + $mb.Width / 2), [int]($mb.Top + $mb.Height / 2))
    Pump 200
    [MR2]::Click()
    Pump 700

    # 菜单是独立 Popup 窗口，从桌面上找「设置…」
    $rootEl = $AE::RootElement
    $miCond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CTL::MenuItem)
    $allMi = $rootEl.FindAll($CTS::Descendants, $miCond)

    $settingsItem = $null
    for ($i = 0; $i -lt $allMi.Count; $i++) {
        $n = $allMi[$i].Current.Name
        if ($n -and $n.StartsWith('设置')) { $settingsItem = $allMi[$i]; break }
    }
    Check '菜单里有「设置…」' ($null -ne $settingsItem)

    if ($null -ne $settingsItem) {
        $settingsItem.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        Pump 1200

        $settings = Get-Process -Name QuickDrawer -ErrorAction SilentlyContinue | Select-Object -First 1
        # 设置窗是同一进程的另一个顶层窗口。
        # 不能用 UIA RootElement 的 Children 找（Owner 指向抽屉的 WPF 窗口不在其中，
        # 实测只列出抽屉那一个），改用 EnumWindows 按标题前缀取 HWND 再转 UIA。
        $setHwnd = [MR2]::FindByPrefix([uint32]$proc.Id, 'QuickDrawer 设置')
        $setWin = if ($setHwnd -ne [IntPtr]::Zero) { $AE::FromHandle($setHwnd) } else { $null }
        Check '设置窗口打开' ($null -ne $setWin) $(if ($setHwnd -ne [IntPtr]::Zero) { "hwnd=$setHwnd" } else { 'not found' })

        if ($null -ne $setWin) {
            $rbCond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CTL::RadioButton)
            $setRadios = $setWin.FindAll($CTS::Descendants, $rbCond)

            $defaults = @()
            for ($i = 0; $i -lt $setRadios.Count; $i++) {
                $n = $setRadios[$i].Current.Name
                if ($n -and $n.StartsWith('DefaultAssistant:')) {
                    $defaults += $setRadios[$i]
                }
            }

            Check '设置页有 4 个「默认助手」选项' ($defaults.Count -eq 4) `
                ("count=" + $defaults.Count + " names=" + (($defaults | ForEach-Object { $_.Current.Name }) -join ','))

            if ($defaults.Count -gt 0) {
                $selected = @()
                foreach ($d in $defaults) {
                    try {
                        $sel = $d.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected
                        if ($sel) { $selected += $d.Current.Name }
                    }
                    catch {
                        # 读不到选中态不算失败，下面断言会体现
                    }
                }
                Check '选中的正是默认站点' ($selected.Count -eq 1 -and $selected[0] -eq "DefaultAssistant:$ExpectDefault") `
                    ("selected=" + ($selected -join ','))

                # 每一项都要可点（不是灰的）
                $allEnabled = $true
                foreach ($d in $defaults) { if (-not $d.Current.IsEnabled) { $allEnabled = $false } }
                Check '四个选项都可点' $allEnabled
            }

            # 关掉设置窗，避免影响后续门禁
            try {
                $setWin.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
                Pump 400
            }
            catch { }
        }
    }
}

Write-Host ''
if ($script:failures -gt 0) {
    Write-Host ("RESULT: FAIL ({0}/{1} checks)" -f $script:failures, $script:checks)
    exit 1
}
Write-Host ("RESULT: PASS ({0} checks)" -f $script:checks)
exit 0
