# Focused re-test of the appbar work-area reservation, which failed in the first probe.
$ErrorActionPreference = 'Stop'

$src = @'
using System;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential)]
public struct RECT { public int Left, Top, Right, Bottom; }

[StructLayout(LayoutKind.Sequential)]
public struct APPBARDATA {
    public uint cbSize;
    public IntPtr hWnd;
    public uint uCallbackMessage;
    public uint uEdge;
    public RECT rc;
    public int lParam;
}

public class W2 {
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern IntPtr CreateWindowEx(uint ex, string cls, string name, uint style,
        int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll")] public static extern bool DestroyWindow(IntPtr h);
    [DllImport("shell32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern IntPtr SHAppBarMessage(uint msg, ref APPBARDATA data);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool SystemParametersInfo(uint a, uint b, ref RECT r, uint u);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hgt, bool repaint);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern uint GetLastError();
}
'@

Add-Type -TypeDefinition $src

$hwnd = [W2]::CreateWindowEx([uint32]0, 'Static', 'appbar-probe', [uint32]2147483648, 0,0, 1,1,
    [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)

$abd = New-Object APPBARDATA
$abd.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($abd)
$abd.hWnd = $hwnd
$abd.uCallbackMessage = 0x0400 + 1
$abd.uEdge = 0

$wa0 = New-Object RECT
[void][W2]::SystemParametersInfo(0x0030, 0, [ref]$wa0, 0)
Write-Output ("work area before      : L={0} T={1} R={2} B={3}" -f $wa0.Left,$wa0.Top,$wa0.Right,$wa0.Bottom)

$r = [W2]::SHAppBarMessage(0x00000000, [ref]$abd)
$e = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
Write-Output ("ABM_NEW               : ret={0} lastError={1}" -f $r, $e)

$abd.rc.Left = 0; $abd.rc.Top = 0; $abd.rc.Right = 300; $abd.rc.Bottom = $wa0.Bottom
$r = [W2]::SHAppBarMessage(0x00000002, [ref]$abd)
Write-Output ("ABM_QUERYPOS          : ret={0} rc=L{1} T{2} R{3} B{4}" -f $r, $abd.rc.Left, $abd.rc.Top, $abd.rc.Right, $abd.rc.Bottom)

$abd.rc.Left = 0; $abd.rc.Right = 300
$r = [W2]::SHAppBarMessage(0x00000003, [ref]$abd)
$e = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
Write-Output ("ABM_SETPOS            : ret={0} rc=L{1} T{2} R{3} B{4} err={5}" -f $r, $abd.rc.Left, $abd.rc.Top, $abd.rc.Right, $abd.rc.Bottom, $e)

Start-Sleep -Milliseconds 600

$wa1 = New-Object RECT
[void][W2]::SystemParametersInfo(0x0030, 0, [ref]$wa1, 0)
Write-Output ("work area after SETPOS: L={0} T={1} R={2} B={3}" -f $wa1.Left,$wa1.Top,$wa1.Right,$wa1.Bottom)

$shrunk = $wa1.Left - $wa0.Left
if ($shrunk -ge 300) {
    Write-Output "VERDICT: appbar work-area reservation WORKS ($shrunk px reserved)"
} elseif ($shrunk -gt 0) {
    Write-Output "VERDICT: partially reserved ($shrunk px) -- less than requested 300"
} else {
    Write-Output "VERDICT: work area NOT reserved (0 px). AppBar registration did not shrink the desktop work area."
}

[void][W2]::SHAppBarMessage(0x00000001, [ref]$abd)
[void][W2]::DestroyWindow($hwnd)
Start-Sleep -Milliseconds 400

$wa2 = New-Object RECT
[void][W2]::SystemParametersInfo(0x0030, 0, [ref]$wa2, 0)
Write-Output ("work area after REMOVE: L={0} T={1} R={2} B={3}" -f $wa2.Left,$wa2.Top,$wa2.Right,$wa2.Bottom)
if ($wa2.Left -eq $wa0.Left) { Write-Output "cleanup OK: work area restored" } else { Write-Output "cleanup WARNING: work area not restored" }
