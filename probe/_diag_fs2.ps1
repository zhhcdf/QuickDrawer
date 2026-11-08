# Temp diagnostic 2: MonitorFromPoint returns NULL on this box. Find out why.
# ASCII only.

$ErrorActionPreference = 'Stop'

Add-Type -Namespace D2 -Name M -MemberDefinition @'
[DllImport("user32.dll", SetLastError=true)] public static extern bool GetCursorPos(out POINT p);
[DllImport("user32.dll", SetLastError=true)] public static extern IntPtr MonitorFromPoint(POINT pt, uint flags);
[DllImport("user32.dll", SetLastError=true)] public static extern IntPtr MonitorFromPoint2(int x, int y, uint flags);
[DllImport("user32.dll", SetLastError=true)] public static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
[DllImport("user32.dll", SetLastError=true)] public static extern IntPtr GetDesktopWindow();
[DllImport("user32.dll", SetLastError=true)] public static extern int GetSystemMetrics(int i);
[DllImport("user32.dll", SetLastError=true)] public static extern bool GetMonitorInfo(IntPtr h, ref MONITORINFO mi);
public struct POINT { public int X; public int Y; }
public struct RECT { public int Left, Top, Right, Bottom; }
public struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
public delegate bool MonitorEnumProc(IntPtr hMon, IntPtr hdc, IntPtr rect, IntPtr data);
[DllImport("user32.dll", SetLastError=true)] public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc cb, IntPtr data);
'@

$p = New-Object D2.M+POINT
Write-Host ("GetCursorPos -> {0} at {1},{2}" -f [D2.M]::GetCursorPos([ref]$p), $p.X, $p.Y)

Write-Host ("SM_CMONITORS(80) = {0}" -f [D2.M]::GetSystemMetrics(80))
Write-Host ("SM_CXSCREEN(0)   = {0}" -f [D2.M]::GetSystemMetrics(0))
Write-Host ("SM_CYSCREEN(1)   = {0}" -f [D2.M]::GetSystemMetrics(1))
Write-Host ("SM_XVIRTUALSCREEN(76) = {0}, SM_YVIRTUALSCREEN(77) = {1}, SM_CXVIRTUALSCREEN(78) = {2}, SM_CYVIRTUALSCREEN(79) = {3}" -f `
    [D2.M]::GetSystemMetrics(76), [D2.M]::GetSystemMetrics(77), [D2.M]::GetSystemMetrics(78), [D2.M]::GetSystemMetrics(79))

Write-Host ("MonitorFromWindow(desktop, NEAREST) = 0x{0:X}" -f [Int64][D2.M]::MonitorFromWindow([D2.M]::GetDesktopWindow(), 2))
Write-Host ("MonitorFromWindow(NULL, NEAREST)    = 0x{0:X}" -f [Int64][D2.M]::MonitorFromWindow([IntPtr]::Zero, 2))

$mInt = [D2.M]::MonitorFromPoint2($p.X, $p.Y, 2)
Write-Host ("MonitorFromPoint(int,int,2) = 0x{0:X} lastErr={1}" -f [Int64]$mInt, [System.Runtime.InteropServices.Marshal]::GetLastWin32Error())

$mStruct = [D2.M]::MonitorFromPoint($p, [uint32]2)
Write-Host ("MonitorFromPoint(POINT,2)   = 0x{0:X} lastErr={1}" -f [Int64]$mStruct, [System.Runtime.InteropServices.Marshal]::GetLastWin32Error())

$mZero = [D2.M]::MonitorFromPoint2($p.X, $p.Y, 0)
Write-Host ("MonitorFromPoint(int,int,0=NULL flag) = 0x{0:X}" -f [Int64]$mZero)

# enumerate every monitor with its rect
$script:monCount = 0
$cb = [D2.M+MonitorEnumProc] {
    param($hMon, $hdc, $rect, $data)
    $script:monCount++
    $mi = New-Object D2.M+MONITORINFO
    $mi.cbSize = 40
    $ok = [D2.M]::GetMonitorInfo($hMon, [ref]$mi)
    Write-Host ("  monitor #{0} h=0x{1:X} info={2} rcMonitor={3},{4}-{5},{6} rcWork={7},{8}-{9},{10} flags={11}" -f `
        $script:monCount, [Int64]$hMon, $ok, $mi.rcMonitor.Left, $mi.rcMonitor.Top, $mi.rcMonitor.Right, $mi.rcMonitor.Bottom, `
        $mi.rcWork.Left, $mi.rcWork.Top, $mi.rcWork.Right, $mi.rcWork.Bottom, $mi.dwFlags)
    return $true
}
$enumOk = [D2.M]::EnumDisplayMonitors([IntPtr]::Zero, [IntPtr]::Zero, $cb, [IntPtr]::Zero)
Write-Host ("EnumDisplayMonitors -> {0}, count={1}" -f $enumOk, $script:monCount)
