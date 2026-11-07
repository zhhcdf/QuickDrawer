"""验证 Y2 图标在实际产物里的表现。

两条独立证据：
1) 从发布 exe 里 ExtractIconEx 提取 16/32/48/256 图标 —— 这是资源管理器显示的文件图标，
   直接由 src/QuickDrawer/assets/QuickDrawer.ico 决定（ApplicationIcon 编译进 exe）。
2) 保留展开托盘的截图，供人工确认托盘图标。
"""
Add-Type -AssemblyName System.Drawing, System.Windows.Forms

$out = Join-Path $env:TEMP 'qd_icon_check'
# 2026-11-07 发布准备：探测目标 exe 改为运行时解析，不再写死个人发布目录。
# 如需指向别处，先设置环境变量 QD_EXE。
$exe = $env:QD_EXE
if (-not $exe) { $exe = Join-Path $env:LOCALAPPDATA 'QuickDrawer\QuickDrawer.exe' }
if (-not (Test-Path $exe)) { throw "QD_EXE not found: $exe  (set `$env:QD_EXE to the published QuickDrawer.exe)" }
"exe: $exe  exists=$([System.IO.File]::Exists($exe))"

$sig = @'
using System;
using System.Runtime.InteropServices;
public static class Ico2 {
    [DllImport("shell32.dll", CharSet=CharSet.Unicode)]
    public static extern uint ExtractIconExW(string file, int index, IntPtr[] large, IntPtr[] small, uint count);
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetIconInfo(IntPtr h, out ICONINFO ii);
    [DllImport("user32.dll")] public static extern int GetObject(IntPtr h, int n, ref BITMAP b);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr h);
    [StructLayout(LayoutKind.Sequential)] public struct ICONINFO { public bool fIcon; public int x; public int y; public IntPtr hbmMask; public IntPtr hbmColor; }
    [StructLayout(LayoutKind.Sequential)] public struct BITMAP { public int bmType; public int bmWidth; public int bmHeight; public int bmWidthBytes; public short bmPlanes; public short bmBitsPixel; public IntPtr bmBits; }
}
'@
if (-not ('Ico2' -as [type])) { Add-Type -TypeDefinition $sig }

$large = New-Object IntPtr[] 1
$small = New-Object IntPtr[] 1
$n = [Ico2]::ExtractIconExW($exe, 0, $large, $small, 1)
"icons in exe (index 0): $n"

function Check([IntPtr]$h, [string]$tag) {
    if ($h -eq [IntPtr]::Zero) { "  $tag : NULL (no icon)"; return }
    $ii = New-Object Ico2+ICONINFO
    [void][Ico2]::GetIconInfo($h, [ref]$ii)
    $bmp = New-Object Ico2+BITMAP
    [void][Ico2]::GetObject($ii.hbmColor, [System.Runtime.InteropServices.Marshal]::SizeOf($bmp), [ref]$bmp)
    $w = $bmp.bmWidth; $hh = [math]::Abs($bmp.bmHeight)
    # DrawIconEx 到 32bpp 位图，取黄条像素
    $b = New-Object System.Drawing.Bitmap($w, $hh)
    $g = [System.Drawing.Graphics]::FromImage($b)
    $g.Clear([System.Drawing.Color]::Transparent)
    $hdc = $g.GetHdc()
    Add-Type -AssemblyName System.Drawing
    $di = @'
using System;
using System.Runtime.InteropServices;
public static class Drw {
    [DllImport("user32.dll")] public static extern bool DrawIconEx(IntPtr hdc, int x, int y, IntPtr h, int cx, int cy, int istep, IntPtr br, uint fi);
}
'@
    if (-not ('Drw' -as [type])) { Add-Type -TypeDefinition $di }
    [void][Drw]::DrawIconEx($hdc, 0, 0, $h, $w, $hh, 0, [IntPtr]::Zero, 3)
    $g.ReleaseHdc($hdc)
    $g.Dispose()
    $p = Join-Path $out ("exe_icon_{0}.png" -f $tag)
    $b.Save($p, [System.Drawing.Imaging.ImageFormat]::Png)
    # 统计金黄像素
    $cnt = 0
    for ($y = 0; $y -lt $hh; $y++) {
        for ($x = 0; $x -lt $w; $x++) {
            $px = $b.GetPixel($x, $y)
            if ($px.A -gt 200 -and [math]::Abs($px.R - 0xF9) -le 22 -and [math]::Abs($px.G - 0xC4) -le 22 -and [math]::Abs($px.B - 0x24) -le 22) { $cnt++ }
        }
    }
    "  $tag : {0}x{1}  goldenPx={2}  -> $p" -f $w, $hh, $cnt
    $b.Dispose()
    [void][Ico2]::DeleteObject($ii.hbmColor)
    [void][Ico2]::DeleteObject($ii.hbmMask)
    [void][Ico2]::DestroyIcon($h)
}

Check $large[0] 'large'
Check $small[0] 'small'

# 展开托盘：^ 箭头实测中心约 (1708,1055)
$msig = @'
using System;
using System.Runtime.InteropServices;
public static class M2 {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
    public static void Click(int x, int y) {
        SetCursorPos(x, y); System.Threading.Thread.Sleep(100);
        mouse_event(0x0002,0,0,0,IntPtr.Zero); System.Threading.Thread.Sleep(70);
        mouse_event(0x0004,0,0,0,IntPtr.Zero);
    }
}
'@
if (-not ('M2' -as [type])) { Add-Type -TypeDefinition $msig }

$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
[M2]::Click(1708, 1055)
Start-Sleep -Milliseconds 1200
$bmp = New-Object System.Drawing.Bitmap($screen.Width, $screen.Height)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen(0, 0, 0, 0, $bmp.Size)
$g.Dispose()
$p2 = Join-Path $out 'tray_open.png'
$bmp.Save($p2, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
"tray_open: $p2"

Get-ChildItem $out -Filter '*icon*' | Select-Object Name, Length | Format-Table -AutoSize
