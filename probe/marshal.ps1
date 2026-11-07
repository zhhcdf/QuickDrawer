# Verify APPBARDATA marshalling and whether PowerShell nested struct field assignment works.
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

public class W3 {
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern IntPtr CreateWindowEx(uint ex, string cls, string name, uint style,
        int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll")] public static extern bool DestroyWindow(IntPtr h);
    [DllImport("shell32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern IntPtr SHAppBarMessage(uint msg, ref APPBARDATA data);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool SystemParametersInfo(uint a, uint b, ref RECT r, uint u);
}
'@
Add-Type -TypeDefinition $src

$abd = New-Object APPBARDATA
$abd.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($abd)
Write-Output "sizeof(APPBARDATA) = $($abd.cbSize) (expected 48 on x64)"
Write-Output "sizeof(RECT)        = $([Runtime.InteropServices.Marshal]::SizeOf([RECT]))"

# nested assignment test
$abd.uEdge = 0
$abd.rc.Left = 10
$abd.rc.Top  = 20
$abd.rc.Right = 300
$abd.rc.Bottom = 1032
Write-Output "after nested assign: rc=L$($abd.rc.Left) T$($abd.rc.Top) R$($abd.rc.Right) B$($abd.rc.Bottom)"

# now the whole-RECT replacement approach
$r = New-Object RECT
$r.Left = 0; $r.Top = 0; $r.Right = 300; $r.Bottom = 1032
$abd.rc = $r
Write-Output "after RECT replace : rc=L$($abd.rc.Left) T$($abd.rc.Top) R$($abd.rc.Right) B$($abd.rc.Bottom)"

$hwnd = [W3]::CreateWindowEx([uint32]0, 'Static', 'appbar-probe2', [uint32]2147483648, 0,0, 1,1,
    [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
$abd.hWnd = $hwnd
$abd.uCallbackMessage = 0x0401

$wa0 = New-Object RECT
[void][W3]::SystemParametersInfo(0x0030, 0, [ref]$wa0, 0)
Write-Output ("workarea before    : L={0} T={1} R={2} B={3}" -f $wa0.Left,$wa0.Top,$wa0.Right,$wa0.Bottom)

$ret = [W3]::SHAppBarMessage(0x00000000, [ref]$abd)
Write-Output "ABM_NEW ret=$ret err=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())"

$q = New-Object APPBARDATA
$q.cbSize = $abd.cbSize
$q.hWnd = $hwnd
$q.uEdge = 0
$q.rc = $r
$ret = [W3]::SHAppBarMessage(0x00000002, [ref]$q)
Write-Output ("ABM_QUERYPOS ret={0} rc=L{1} T{2} R{3} B{4}" -f $ret,$q.rc.Left,$q.rc.Top,$q.rc.Right,$q.rc.Bottom)

$q.rc = $r
$ret = [W3]::SHAppBarMessage(0x00000003, [ref]$q)
Write-Output ("ABM_SETPOS  ret={0} rc=L{1} T{2} R{3} B{4}" -f $ret,$q.rc.Left,$q.rc.Top,$q.rc.Right,$q.rc.Bottom)
Start-Sleep -Milliseconds 700

$wa1 = New-Object RECT
[void][W3]::SystemParametersInfo(0x0030, 0, [ref]$wa1, 0)
Write-Output ("workarea after     : L={0} T={1} R={2} B={3}" -f $wa1.Left,$wa1.Top,$wa1.Right,$wa1.Bottom)
$shrunk = $wa1.Left - $wa0.Left
Write-Output "reserved = $shrunk px"

[void][W3]::SHAppBarMessage(0x00000001, [ref]$q)
[void][W3]::DestroyWindow($hwnd)
