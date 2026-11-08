# Gate probe for "hide the drawer handle while a fullscreen app is in front".
#
# What it proves:
#   1. the detection entry points exist on the SHIPPED assembly;
#   2. on a normal desktop they say "not fullscreen" (no false positive);
#   3. against a REAL borderless fullscreen window owned by ANOTHER process they
#      say "fullscreen" (no false negative) -- this is the part that cannot be
#      verified by reading code, because the 2px tolerance, the rcMonitor vs
#      rcWork choice and the "own process" exclusion all interact;
#   4. after that window closes the verdict flips back to "not fullscreen",
#      which is exactly the signal the 500ms poll uses to bring the handle back;
#   5. config default + tray wiring members are present.
#
# Why a second process for the test window: IsForegroundFullscreenOnCursorMonitor
# deliberately returns false for windows owned by our own process (otherwise the
# drawer panel could hide the handle that belongs to it). A fullscreen form
# created inside this probe would therefore always test as "own process".
#
# ASCII-only on purpose: Windows PowerShell 5.1 decodes BOM-less UTF-8 as ANSI,
# and non-ASCII comments have broken parsing in this repo more than once.
#
# Usage: powershell.exe -NoProfile -ExecutionPolicy Bypass -File probe\_verify_fullscreen_handle.ps1
#        $env:QD_EXE = <path to QuickDrawer.exe>   (defaults to %LOCALAPPDATA%\QuickDrawer\QuickDrawer.exe)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

$failures = 0
function Check($name, $ok, $detail) {
    if ($ok) { Write-Host ("PASS  {0}  {1}" -f $name, $detail) -ForegroundColor Green }
    else { Write-Host ("FAIL  {0}  {1}" -f $name, $detail) -ForegroundColor Red; $script:failures++ }
}

$exe = $env:QD_EXE
if (-not $exe) { $exe = Join-Path $env:LOCALAPPDATA 'QuickDrawer\QuickDrawer.exe' }
if (-not (Test-Path $exe)) { throw "QD_EXE not found: $exe" }
$asm = [System.Reflection.Assembly]::LoadFrom($exe)
Write-Host ("assembly: {0}" -f $exe)

$native = $asm.GetType('QuickDrawer.Native.NativeMethods')
$nvPublic = [System.Reflection.BindingFlags]'Public,Static'
$nvAny = [System.Reflection.BindingFlags]'Public,NonPublic,Static,Instance'

# ---------------------------------------------------------------- section 1
Write-Host "`n--- 1. API surface on the shipped assembly ---" -ForegroundColor Cyan

foreach ($m in @('TryGetMonitorRect', 'GetMonitorForCursor', 'IsForegroundFullscreenOnCursorMonitor', 'IsD3DFullscreen')) {
    $mi = $native.GetMethod($m, $nvPublic)
    Check "NativeMethods.$m exists" ($null -ne $mi) $(if ($mi) { "" } else { "method not found" })
}

$probeMethod = $native.GetMethod('IsForegroundFullscreenOnCursorMonitor', $nvPublic)
$configType = $asm.GetType('QuickDrawer.AppConfig')
$handleCfg = $asm.GetType('QuickDrawer.HandleConfig')
$hideProp = $handleCfg.GetProperty('HideInFullscreen')
Check "HandleConfig.HideInFullscreen exists" ($null -ne $hideProp) ""

if ($hideProp) {
    # the property lives on HandleConfig, so the target must be a HandleConfig
    # instance (AppConfig.Dock.Handle type) -- passing AppConfig throws TargetException.
    $handleInstance = [System.Activator]::CreateInstance($handleCfg)
    $default = $hideProp.GetValue($handleInstance)
    Check "HideInFullscreen defaults to true" ($default -eq $true) "default=$default"

    $jsonName = '?'
    try {
        $attr = $hideProp.GetCustomAttributes($false) | Where-Object { $_.GetType().Name -eq 'JsonPropertyNameAttribute' } | Select-Object -First 1
        if ($attr) { $jsonName = $attr.Name }
    } catch { $jsonName = "<attribute load failed: $($_.Exception.GetType().Name)>" }
    Check "JSON name is hideInFullscreen" ($jsonName -eq 'hideInFullscreen') "jsonName=$jsonName"
}

# the handle must still be reachable / hideable
$handleWin = $asm.GetType('QuickDrawer.HandleWindow')
foreach ($m in @('HideForPanel', 'ShowForPanel')) {
    $mi = $handleWin.GetMethod($m, [System.Reflection.BindingFlags]'Public,Instance')
    Check "HandleWindow.$m exists" ($null -ne $mi) ""
}

# every show/hide decision must funnel through one place, otherwise the handle
# pops back over a running game the next time the panel collapses
$drawer = $asm.GetType('QuickDrawer.DrawerWindow')
foreach ($m in @('UpdateHandleVisibility', 'StartFullscreenWatch', 'StopFullscreenWatch', 'FullscreenTimer_Tick')) {
    $mi = $drawer.GetMethod($m, $nvAny)
    Check "DrawerWindow.$m exists" ($null -ne $mi) ""
}
foreach ($f in @('_handleSuppressedByFullscreen', '_handleVisible', '_fullscreenTimer')) {
    $fi = $drawer.GetField($f, $nvAny)
    Check "DrawerWindow.$f exists" ($null -ne $fi) ""
}

# ---------------------------------------------------------------- section 2
Write-Host "`n--- 2. normal desktop: must NOT look fullscreen ---" -ForegroundColor Cyan

$args2 = [object[]]@([IntPtr]::Zero, '')
$baseline = $probeMethod.Invoke($null, $args2)
Check "foreground is not fullscreen" ($baseline -eq $false) ("reason=" + $args2[1])

$d3d = $native.GetMethod('IsD3DFullscreen', $nvPublic).Invoke($null, @())
Check "IsD3DFullscreen() callable" ($d3d -eq $false) ("returned=" + $d3d)

# ---------------------------------------------------------------- section 2b
# 2026-11-08 用户实测反馈补的回归项：切到纯桌面（没有前台应用窗口）时，
# 前台会变成资源管理器铺壁纸的 WorkerW / Progman，它天生铺满整块 rcMonitor，
# 几何判定必然命中 —— 结果拉手在桌面上被藏起来，而这时恰恰最需要它。
# "显示桌面"用 Shell.Application.ToggleDesktop，切完必须再切回来。
Write-Host "`n--- 2b. bare desktop: must NOT look fullscreen ---" -ForegroundColor Cyan
try {
    $shellApp = New-Object -ComObject Shell.Application
    $shellApp.ToggleDesktop()
    Start-Sleep -Milliseconds 1200

    $args2b = [object[]]@([IntPtr]::Zero, '')
    $deskVerdict = $probeMethod.Invoke($null, $args2b)
    Check "bare desktop is not fullscreen" ($deskVerdict -eq $false) ("reason=" + $args2b[1])
}
catch {
    Check "bare desktop is not fullscreen" $false ("could not toggle desktop: " + $_.Exception.Message)
}
finally {
    if ($null -ne $shellApp) {
        try { $shellApp.ToggleDesktop() } catch { }
        Start-Sleep -Milliseconds 1200
    }
}

# ---------------------------------------------------------------- section 3
Write-Host "`n--- 3. real fullscreen window in another process: MUST look fullscreen ---" -ForegroundColor Cyan

if (-not ('ProbeWin' -as [type])) {
    Add-Type -Namespace Probe -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT r);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
public struct RECT { public int Left, Top, Right, Bottom; }
'@
}

$tmpScript = Join-Path $env:TEMP ('qd_fullscreen_child_' + [Guid]::NewGuid().ToString('N') + '.ps1')
$outFile = Join-Path $env:TEMP ('qd_fullscreen_hwnd_' + [Guid]::NewGuid().ToString('N') + '.txt')

$childSource = @'
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
$f = New-Object System.Windows.Forms.Form
$f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$f.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$f.Bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$f.TopMost = $true
$f.ShowInTaskbar = $false
$f.Show()
$f.Activate()
[System.IO.File]::WriteAllText("__OUT__", $f.Handle.ToInt64().ToString())
$deadline = [DateTime]::UtcNow.AddSeconds(12)
while ([DateTime]::UtcNow -lt $deadline) {
    $f.Activate()
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 80
}
$f.Close()
'@
$childSource = $childSource.Replace('__OUT__', $outFile)
# ASCII only, but keep BOM off for clarity: this string has no non-ASCII bytes.
[System.IO.File]::WriteAllText($tmpScript, $childSource, [System.Text.UTF8Encoding]::new($false))

$child = Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $tmpScript) -PassThru
Write-Host ("child pid={0}" -f $child.Id)

$hwnd = [IntPtr]::Zero
$waited = 0
while ($waited -lt 8000) {
    if (Test-Path $outFile) {
        $raw = (Get-Content $outFile -Raw).Trim()
        if ($raw) { $hwnd = [IntPtr][Int64]$raw; break }
    }
    Start-Sleep -Milliseconds 100
    $waited += 100
}
Check "child created a window" ($hwnd -ne [IntPtr]::Zero) ("hwnd=0x{0:X}" -f [Int64]$hwnd)

if ($hwnd -ne [IntPtr]::Zero) {
    # put the cursor on the child's screen: detection follows the cursor's monitor
    $r = New-Object Probe.Win+RECT
    [void][Probe.Win]::GetWindowRect($hwnd, [ref]$r)
    [void][Probe.Win]::SetCursorPos([int](($r.Left + $r.Right) / 2), [int](($r.Top + $r.Bottom) / 2))

    # make it the foreground window (the fresh child is allowed to take foreground)
    $fg = [IntPtr]::Zero
    for ($i = 0; $i -lt 40; $i++) {
        [void][Probe.Win]::SetForegroundWindow($hwnd)
        Start-Sleep -Milliseconds 100
        $fg = [Probe.Win]::GetForegroundWindow()
        if ($fg -eq $hwnd) { break }
    }
    Check "child window is foreground" ($fg -eq $hwnd) ("foreground=0x{0:X} child=0x{1:X}" -f [Int64]$fg, [Int64]$hwnd)

    if ($fg -eq $hwnd) {
        Start-Sleep -Milliseconds 200
        $args3 = [object[]]@([IntPtr]::Zero, '')
        $hit = $probeMethod.Invoke($null, $args3)
        Check "fullscreen detected" ($hit -eq $true) ("reason=" + $args3[1])
        Check "culprit hwnd is the child" (([IntPtr]$args3[0]) -eq $hwnd) ("reported=0x{0:X}" -f [Int64]([IntPtr]$args3[0]))

        # ------------------------------------------------------------ section 4
        Write-Host "`n--- 4. after the fullscreen app closes: verdict must flip back ---" -ForegroundColor Cyan
    }
}

# close the child, then look again
try { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue } catch { }
Start-Sleep -Milliseconds 600
$stillUp = $false
try { $stillUp = [Probe.Win]::IsWindow($hwnd) } catch { }
Check "child window is gone" (($hwnd -ne [IntPtr]::Zero) -and (-not $stillUp)) ("IsWindow=" + $stillUp)

$args4 = [object[]]@([IntPtr]::Zero, '')
$after = $probeMethod.Invoke($null, $args4)
Check "back to not-fullscreen" ($after -eq $false) ("reason=" + $args4[1])

# tidy up
Remove-Item $tmpScript -Force -ErrorAction SilentlyContinue
Remove-Item $outFile -Force -ErrorAction SilentlyContinue

Write-Host ""
if ($failures -eq 0) {
    Write-Host "RESULT: PASS" -ForegroundColor Green
    exit 0
} else {
    Write-Host ("RESULT: FAIL ({0} check(s))" -f $failures) -ForegroundColor Red
    exit 1
}
