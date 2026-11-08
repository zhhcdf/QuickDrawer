# Temp diagnostic: why does IsForegroundFullscreenOnCursorMonitor report "no monitor rect"?
# ASCII only. Written because the PowerShell heredoc mangled the UTF-8 path.

$ErrorActionPreference = 'Stop'
$exe = $env:QD_EXE
$asm = [System.Reflection.Assembly]::LoadFrom($exe)
$nv = $asm.GetType('QuickDrawer.Native.NativeMethods')
$f = [System.Reflection.BindingFlags]'Public,NonPublic,Static'

$h = $nv.GetMethod('GetMonitorForCursor', $f).Invoke($null, @())
Write-Host ("GetMonitorForCursor -> 0x{0:X}" -f [Int64]$h)

$t = $nv.GetMethod('TryGetMonitorRect', $f)
$args = [object[]]@($h, $null)
$ok = $t.Invoke($null, $args)
Write-Host ("TryGetMonitorRect -> {0} rect={1}" -f $ok, $args[1])

Write-Host ("GetWorkAreaForCursor -> {0}" -f $nv.GetMethod('GetWorkAreaForCursor', $f).Invoke($null, @()))

# raw P/Invoke, independent of QuickDrawer's declarations
Add-Type -Namespace Diag -Name M -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
[DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(int x, int y, uint flags);
[DllImport("user32.dll")] public static extern bool GetMonitorInfo(IntPtr h, ref MONITORINFO mi);
public struct POINT { public int X; public int Y; }
public struct RECT { public int Left, Top, Right, Bottom; }
public struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
'@

$p = New-Object Diag.M+POINT
$okp = [Diag.M]::GetCursorPos([ref]$p)
Write-Host ("GetCursorPos -> {0} at {1},{2}" -f $okp, $p.X, $p.Y)

$hm = [Diag.M]::MonitorFromPoint($p.X, $p.Y, 2)
Write-Host ("MonitorFromPoint -> 0x{0:X}" -f [Int64]$hm)

$mi = New-Object Diag.M+MONITORINFO
$mi.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($mi)
$oki = [Diag.M]::GetMonitorInfo($hm, [ref]$mi)
Write-Host ("GetMonitorInfo -> {0} cbSize={1} monitor={2},{3}-{4},{5}" -f $oki, $mi.cbSize, $mi.rcMonitor.Left, $mi.rcMonitor.Top, $mi.rcMonitor.Right, $mi.rcMonitor.Bottom)
