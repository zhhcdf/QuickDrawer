param(
    [string]$Exe = ''
)

# Regression check for wrapping the categories list in a ScrollViewer:
# with the path area squeezed to 140px, a mouse wheel over the categories list must scroll it.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrEmpty($Exe)) {
    $Exe = Join-Path $root 'src\QuickDrawer\bin\x64\Release\net10.0-windows\win-x64\QuickDrawer.exe'
}
$cfg = Join-Path $env:APPDATA 'QuickDrawer\config.json'
$out = Join-Path $PSScriptRoot 'path-scroll-result.txt'

Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing @"
using System;
using System.Text;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class W2 {
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
    static INPUT M(uint f, int dx, int dy, uint data) {
        INPUT i = new INPUT(); i.type = 0; i.u.mi.dx = dx; i.u.mi.dy = dy;
        i.u.mi.mouseData = data; i.u.mi.dwFlags = f; return i;
    }
    public static void MoveTo(int x, int y) {
        int w = GetSystemMetrics(0), h = GetSystemMetrics(1);
        INPUT[] a = new INPUT[] { M(0x8001, (int)Math.Round(x * 65535.0 / (w - 1)), (int)Math.Round(y * 65535.0 / (h - 1)), 0) };
        SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
    }
    public static void Wheel(int notches) {
        INPUT[] a = new INPUT[] { M(0x0800, 0, 0, (uint)(-120 * notches)) };
        SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
    }
    public static void Click(int x, int y) {
        MoveTo(x, y);
        System.Threading.Thread.Sleep(120);
        INPUT[] d = new INPUT[] { M(0x0002, 0, 0, 0) };
        SendInput(1, d, Marshal.SizeOf(typeof(INPUT)));
        System.Threading.Thread.Sleep(90);
        INPUT[] u = new INPUT[] { M(0x0004, 0, 0, 0) };
        SendInput(1, u, Marshal.SizeOf(typeof(INPUT)));
        System.Threading.Thread.Sleep(250);
    }

    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();

    // Deliver WM_MOUSEWHEEL straight to the drawer hwnd: the drawer never takes focus
    // (ShowActivated=false), so a synthesized wheel would go to whatever is focused.
    public static void WheelToHwnd(IntPtr hwnd, int screenX, int screenY, int notches) {
        int delta = -120 * notches;
        IntPtr w = new IntPtr(delta << 16);
        IntPtr l = new IntPtr(((screenY & 0xFFFF) << 16) | (screenX & 0xFFFF));
        for (int i = 0; i < Math.Abs(notches); i++) {
            SendMessage(hwnd, 0x020A, w, l);
            System.Threading.Thread.Sleep(60);
        }
    }

    public static uint ForegroundPid() {
        uint pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid); return pid;
    }
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

    public static void Shot(string path, int x, int y, int w, int h) {
        using (Bitmap bmp = new Bitmap(w, h))
        using (Graphics g = Graphics.FromImage(bmp)) {
            g.CopyFromScreen(x, y, 0, 0, new Size(w, h));
            bmp.Save(path, ImageFormat.Png);
        }
    }

    public static long DiffCount(string p1, string p2) {
        using (Bitmap b1 = new Bitmap(p1))
        using (Bitmap b2 = new Bitmap(p2)) {
            if (b1.Width != b2.Width || b1.Height != b2.Height) return -1;
            BitmapData d1 = b1.LockBits(new Rectangle(0, 0, b1.Width, b1.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            BitmapData d2 = b2.LockBits(new Rectangle(0, 0, b2.Width, b2.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            byte[] a1 = new byte[d1.Stride * b1.Height];
            byte[] a2 = new byte[d2.Stride * b2.Height];
            Marshal.Copy(d1.Scan0, a1, 0, a1.Length);
            Marshal.Copy(d2.Scan0, a2, 0, a2.Length);
            b1.UnlockBits(d1); b2.UnlockBits(d2);
            long c = 0;
            for (int y = 0; y < b1.Height; y++) {
                for (int x = 0; x < b1.Width; x++) {
                    int i1 = y * d1.Stride + x * 4, i2 = y * d2.Stride + x * 4;
                    if (Math.Abs(a1[i1] - a2[i2]) + Math.Abs(a1[i1+1] - a2[i2+1]) + Math.Abs(a1[i1+2] - a2[i2+2]) > 12) c++;
                }
            }
            return c;
        }
    }
}
"@

Get-Process -Name QuickDrawer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 700

# squeeze the path area so the categories list must scroll
$j = Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json
$j.layout | Add-Member -NotePropertyName pathAreaHeight -NotePropertyValue 140 -Force
$j | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $cfg -Encoding UTF8

$p = Start-Process -FilePath $Exe -WorkingDirectory (Split-Path $Exe) -PassThru
Start-Sleep -Milliseconds 400
[W2]::MoveTo(1780, 300)
Start-Sleep -Milliseconds 1600

$hwnd = [W2]::Find([uint32]$p.Id)
$r = [W2]::Rect($hwnd)
$w = $r[2] - $r[0]; $h = $r[3] - $r[1]
# wheel needs the drawer to be the active window: click empty notes background first
[W2]::Click(($r[0] + 200), ($r[1] + 780))
Start-Sleep -Milliseconds 300
$shotA = Join-Path $PSScriptRoot 'path-scroll-before.png'
[W2]::Shot($shotA, $r[0], $r[1], $w, $h)

# wheel down 3 notches over the categories list, delivered straight to the drawer hwnd
$hoverX = $r[0] + 200
$hoverY = $r[1] + 250
[W2]::MoveTo($hoverX, $hoverY)
Start-Sleep -Milliseconds 200
[W2]::WheelToHwnd($hwnd, $hoverX, $hoverY, 3)
Start-Sleep -Milliseconds 700
$shotB = Join-Path $PSScriptRoot 'path-scroll-after.png'
[W2]::Shot($shotB, $r[0], $r[1], $w, $h)

$diff = [W2]::DiffCount($shotA, $shotB)

"rect=$($r -join ',')"
"foregroundPid=$([W2]::ForegroundPid()) appPid=$($p.Id)"
"shots=$shotA | $shotB"
"diffPixels=$diff"
"VERDICT=" + $(if ($diff -gt 800) { 'PASS (categories list scrolled)' } else { 'FAIL (no scroll)' })

Get-Process -Name QuickDrawer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

# restore auto layout
$j2 = Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json
$j2.layout.pathAreaHeight = 0
$j2 | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $cfg -Encoding UTF8
