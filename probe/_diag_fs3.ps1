# Temp diagnostic 3: is MonitorFromPoint declared correctly in Native.cs?
# Hypothesis: Native.cs:467 declares MonitorFromPoint(int x, int y, uint flags).
# On x64 a POINT (8 bytes) is passed in ONE register, so splitting it into two
# int parameters shifts dwFlags into the wrong slot -> user32 sees garbage
# flags and returns NULL. Declaring it as (POINT pt, uint flags) is correct.
# ASCII only.

$ErrorActionPreference = 'Stop'

Add-Type -Namespace D3 -Name M -MemberDefinition @'
[DllImport("user32.dll", SetLastError=true)] public static extern bool GetCursorPos(out POINT p);
// correct signature: POINT by value + flags
[DllImport("user32.dll", SetLastError=true, EntryPoint="MonitorFromPoint")] public static extern IntPtr MonPtStruct(POINT pt, uint flags);
// the shape Native.cs currently uses: two ints + flags
[DllImport("user32.dll", SetLastError=true, EntryPoint="MonitorFromPoint")] public static extern IntPtr MonPtInts(int x, int y, uint flags);
[DllImport("user32.dll", SetLastError=true)] public static extern bool GetMonitorInfo(IntPtr h, ref MONITORINFO mi);
public struct POINT { public int X; public int Y; }
public struct RECT { public int Left, Top, Right, Bottom; }
public struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
'@

$p = New-Object D3.M+POINT
[void][D3.M]::GetCursorPos([ref]$p)
Write-Host ("cursor at {0},{1}" -f $p.X, $p.Y)

$hStruct = [D3.M]::MonPtStruct($p, [uint32]2)
Write-Host ("MonitorFromPoint(POINT,2)  -> 0x{0:X}" -f [Int64]$hStruct)

$hInts = [D3.M]::MonPtInts($p.X, $p.Y, [uint32]2)
Write-Host ("MonitorFromPoint(i,i,2)    -> 0x{0:X}" -f [Int64]$hInts)

foreach ($pair in @(@('struct', $hStruct), @('ints', $hInts))) {
    $name = $pair[0]; $h = [IntPtr]$pair[1]
    if ($h -eq [IntPtr]::Zero) { Write-Host ("  [{0}] NULL handle, GetMonitorInfo skipped" -f $name); continue }
    $mi = New-Object D3.M+MONITORINFO
    $mi.cbSize = 40
    $ok = [D3.M]::GetMonitorInfo($h, [ref]$mi)
    Write-Host ("  [{0}] GetMonitorInfo={1} rcMonitor={2},{3}-{4},{5} rcWork={6},{7}-{8},{9}" -f $name, $ok, `
        $mi.rcMonitor.Left, $mi.rcMonitor.Top, $mi.rcMonitor.Right, $mi.rcMonitor.Bottom, `
        $mi.rcWork.Left, $mi.rcWork.Top, $mi.rcWork.Right, $mi.rcWork.Bottom)
}
