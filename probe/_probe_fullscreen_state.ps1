# 探针：验证"全屏应用检测"在本机可用的信号源
# 目的：给「全屏游戏时自动隐藏拉手」方案做取证，不涉及任何修改。
# 注意：本文件保持纯 ASCII，避免 PowerShell 5.1 按 ANSI 读中文导致解析失败。

$ErrorActionPreference = 'Stop'

Add-Type -Namespace Probe -Name Fs -MemberDefinition @'
[DllImport("shell32.dll")]
public static extern int SHQueryUserNotificationState(out int state);

[DllImport("user32.dll")]
public static extern IntPtr GetForegroundWindow();

[DllImport("user32.dll")]
public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);

[DllImport("user32.dll")]
public static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);

[DllImport("user32.dll")]
public static extern bool GetMonitorInfo(IntPtr hmon, ref MONITORINFO mi);

[DllImport("user32.dll")]
public static extern bool IsZoomed(IntPtr hwnd);

[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern int GetWindowTextW(IntPtr hwnd, System.Text.StringBuilder sb, int max);

[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern int GetClassNameW(IntPtr hwnd, System.Text.StringBuilder sb, int max);

[DllImport("user32.dll")]
public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);

[DllImport("dwmapi.dll")]
public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out int val, int cb);

[DllImport("user32.dll")]
public static extern int GetWindowLong(IntPtr hwnd, int index);

[StructLayout(LayoutKind.Sequential)]
public struct RECT { public int Left, Top, Right, Bottom; }

[StructLayout(LayoutKind.Sequential)]
public struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
'@

$names = @{
    1 = 'QUNS_NOT_PRESENT'
    2 = 'QUNS_BUSY'
    3 = 'QUNS_RUNNING_D3D_FULL_SCREEN'
    4 = 'QUNS_PRESENTATION_MODE'
    5 = 'QUNS_ACCEPTS_NOTIFICATIONS'
    6 = 'QUNS_QUIET_TIME'
    7 = 'QUNS_APP'
}

Write-Host '=== 1. SHQueryUserNotificationState ==='
$state = 0
$hr = [Probe.Fs]::SHQueryUserNotificationState([ref]$state)
$label = if ($names.ContainsKey($state)) { $names[$state] } else { '(unknown)' }
Write-Host ("  hr=0x{0:X8}  state={1}  {2}" -f $hr, $state, $label)
Write-Host ("  API callable: {0}" -f ($hr -eq 0))

Write-Host ''
Write-Host '=== 2. Foreground window geometry (vs monitor rect) ==='
$hwnd = [Probe.Fs]::GetForegroundWindow()
Write-Host ("  hwnd=0x{0:X}" -f [int64]$hwnd)

if ($hwnd -ne [IntPtr]::Zero) {
    $sbTitle = New-Object System.Text.StringBuilder 512
    [void][Probe.Fs]::GetWindowTextW($hwnd, $sbTitle, 512)
    $sbClass = New-Object System.Text.StringBuilder 256
    [void][Probe.Fs]::GetClassNameW($hwnd, $sbClass, 256)

    # 注意：不能用 $pid，PowerShell 的 $PID 是只读自动变量
    $procId = 0
    [void][Probe.Fs]::GetWindowThreadProcessId($hwnd, [ref]$procId)
    $pname = try { (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch { '(?)' }

    Write-Host ("  title='{0}'" -f $sbTitle.ToString())
    Write-Host ("  class='{0}' pid={1} process='{2}'" -f $sbClass.ToString(), $procId, $pname)

    $r = New-Object Probe.Fs+RECT
    [void][Probe.Fs]::GetWindowRect($hwnd, [ref]$r)
    Write-Host ("  rect=({0},{1})-({2},{3})  size={4}x{5}" -f $r.Left, $r.Top, $r.Right, $r.Bottom, ($r.Right - $r.Left), ($r.Bottom - $r.Top))

    $hmon = [Probe.Fs]::MonitorFromWindow($hwnd, 2)  # MONITOR_DEFAULTTONEAREST
    $mi = New-Object Probe.Fs+MONITORINFO
    $mi.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($mi)
    [void][Probe.Fs]::GetMonitorInfo($hmon, [ref]$mi)
    Write-Host ("  monitor rcMonitor=({0},{1})-({2},{3})  rcWork=({4},{5})-({6},{7})" -f `
        $mi.rcMonitor.Left, $mi.rcMonitor.Top, $mi.rcMonitor.Right, $mi.rcMonitor.Bottom, `
        $mi.rcWork.Left, $mi.rcWork.Top, $mi.rcWork.Right, $mi.rcWork.Bottom)

    $fillsMonitor = ([Math]::Abs($r.Left - $mi.rcMonitor.Left) -le 2) -and
                    ([Math]::Abs($r.Top - $mi.rcMonitor.Top) -le 2) -and
                    ([Math]::Abs($r.Right - $mi.rcMonitor.Right) -le 2) -and
                    ([Math]::Abs($r.Bottom - $mi.rcMonitor.Bottom) -le 2)

    $cloaked = 0
    $hrDwm = [Probe.Fs]::DwmGetWindowAttribute($hwnd, 14, [ref]$cloaked, 4)

    Write-Host ("  fillsMonitor={0}  IsZoomed={1}  cloaked={2}" -f $fillsMonitor, [Probe.Fs]::IsZoomed($hwnd), $cloaked)
    Write-Host ("  => would-be-misdetected-as-fullscreen: {0}" -f ($fillsMonitor -and -not [Probe.Fs]::IsZoomed($hwnd) -and $cloaked -eq 0))
}

Write-Host ''
Write-Host '=== 3. QuickDrawer handle window ex-style ==='
$qd = Get-Process QuickDrawer -ErrorAction SilentlyContinue
if ($qd) {
    foreach ($p in $qd) { Write-Host ("  pid={0} mainWindow=0x{1:X} start={2}" -f $p.Id, [int64]$p.MainWindowHandle, $p.StartTime) }
} else {
    Write-Host '  QuickDrawer not running'
}

Write-Host ''
Write-Host 'DONE'
