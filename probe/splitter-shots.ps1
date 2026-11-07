param(
    [string]$Exe = ''
)

# Visual evidence for the splitter: default layout, then after a real drag up 120px.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrEmpty($Exe)) {
    $Exe = Join-Path $root 'src\QuickDrawer\bin\x64\Release\net10.0-windows\win-x64\QuickDrawer.exe'
}

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class S {
    [DllImport("user32.dll", SetLastError=true)] public static extern uint SendInput(uint n, INPUT[] i, int s);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
    public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit)] public struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPUTUNION u; }
    static INPUT M(uint f, int x, int y) { INPUT i = new INPUT(); i.type = 0; i.u.mi.dx = x; i.u.mi.dy = y; i.u.mi.dwFlags = f; return i; }
    public static void MoveTo(int x, int y) {
        int w = GetSystemMetrics(0), h = GetSystemMetrics(1);
        INPUT[] a = new INPUT[] { M(0x8001, (int)Math.Round(x * 65535.0 / (w - 1)), (int)Math.Round(y * 65535.0 / (h - 1))) };
        SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
    }
    public static void Down() { INPUT[] a = new INPUT[] { M(0x0002, 0, 0) }; SendInput(1, a, Marshal.SizeOf(typeof(INPUT))); }
    public static void Up() { INPUT[] a = new INPUT[] { M(0x0004, 0, 0) }; SendInput(1, a, Marshal.SizeOf(typeof(INPUT))); }
    public static IntPtr Find(uint pid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && IsWindowVisible(h)) {
                StringBuilder c = new StringBuilder(512); GetClassNameW(h, c, 512);
                if (c.ToString().StartsWith("HwndWrapper[QuickDrawer")) {
                    RECT r; GetWindowRect(h, out r);
                    if ((r.Right - r.Left) > 200) { found = h; return false; }
                }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    public static int[] Rect(IntPtr h) { RECT r; GetWindowRect(h, out r); return new int[] { r.Left, r.Top, r.Right, r.Bottom }; }
}
"@

function Shot([string]$path, [int[]]$r) {
    $w = $r[2] - $r[0]; $h = $r[3] - $r[1]
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r[0], $r[1], 0, 0, (New-Object System.Drawing.Size($w, $h)))
    $g.Dispose()
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

Get-Process -Name QuickDrawer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 800

$p = Start-Process -FilePath $Exe -WorkingDirectory (Split-Path $Exe) -PassThru
Start-Sleep -Milliseconds 400
[S]::MoveTo(1780, 400)
Start-Sleep -Milliseconds 1500

$hwnd = [S]::Find([uint32]$p.Id)
$r = [S]::Rect($hwnd)
$out1 = Join-Path $PSScriptRoot 'splitter-default.png'
Shot $out1 $r
Write-Output ("default shot: " + $out1 + " rect=" + ($r -join ","))

# Splitter screen Y with the default (auto) layout was measured earlier by probe:
# window-local y=439.6 for a 10px-tall row -> center ~= 445 (window top = 0 here).
$y = [int]($r[1] + 445)
$x = [int]($r[0] + ($r[2] - $r[0]) / 2)

[S]::MoveTo($x, $y)
Start-Sleep -Milliseconds 150
[S]::Down()
Start-Sleep -Milliseconds 120
for ($i = 1; $i -le 12; $i++) { [S]::MoveTo($x, $y - [int](120 * $i / 12)); Start-Sleep -Milliseconds 20 }
[S]::Up()
Start-Sleep -Milliseconds 700
[S]::MoveTo(1780, 400)
Start-Sleep -Milliseconds 300

$diag = Join-Path $env:APPDATA 'QuickDrawer\logs\diag.log'
foreach ($l in (Get-Content -LiteralPath $diag -Tail 8 | Select-String '\[splitter\]')) {
    Write-Output ("diag: " + $l)
}

$out2 = Join-Path $PSScriptRoot 'splitter-dragged.png'
Shot $out2 $r
Write-Output ("dragged shot: " + $out2)
Get-Process -Name QuickDrawer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
