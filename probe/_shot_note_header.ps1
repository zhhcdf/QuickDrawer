$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing, System.Windows.Forms
Add-Type @"
using System; using System.Text; using System.Runtime.InteropServices;
public static class NH {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    public struct RECT { public int Left, Top, Right, Bottom; }
    public static IntPtr Find(uint procId, string title) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == procId) { StringBuilder t = new StringBuilder(256); GetWindowTextW(h, t, 256);
                if (t.ToString() == title) { found = h; return false; } }
            return true; }, IntPtr.Zero);
        return found;
    }
}
"@
$proc = Get-Process -Name QuickDrawer | Select-Object -First 1
# 把鼠标移到屏幕右边缘，触发面板滑出
[void][NH]::SetCursorPos(1915, 500)
Start-Sleep -Milliseconds 1500
$h = [NH]::Find([uint32]$proc.Id, 'QuickDrawer')
if ($h -eq [IntPtr]::Zero) { Write-Output 'FAIL=no-window'; exit 1 }
$r = New-Object NH+RECT
[void][NH]::GetWindowRect($h, [ref]$r)
Write-Output ("drawer rect = {0},{1} {2}x{3}" -f $r.Left, $r.Top, ($r.Right-$r.Left), ($r.Bottom-$r.Top))

$AE = [Windows.Automation.AutomationElement]
$root = $AE::FromHandle($h)

# 找到第一张便签卡片的标题框，用它来定位截图区域
$c = New-Object Windows.Automation.PropertyCondition($AE::AutomationIdProperty, 'CardTitle')
$e = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $c)
if ($e) {
    $b = $e.Current.BoundingRectangle
    Write-Output ("CardTitle rect={0},{1} {2}x{3}" -f [int]$b.X, [int]$b.Y, [int]$b.Width, [int]$b.Height)
} else {
    Write-Output 'CardTitle : NOT FOUND'
}

# 截整个抽屉
$w = $r.Right - $r.Left; $ht = $r.Bottom - $r.Top
$bmp = New-Object System.Drawing.Bitmap($w, $ht)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size($w, $ht)))
$out = Join-Path $env:TEMP 'qd_note_header.png'
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
Write-Output "shot = $out"

# 单独放大第一张卡片（宽 = 面板宽，高 160）
if ($e) {
    $b = $e.Current.BoundingRectangle
    $cx = [int]$b.X - 12
    $cy = [int]$b.Y - 30
    $cw = $w - 8
    $ch = 190
    if ($cy -lt 0) { $cy = 0 }
    $bmp2 = New-Object System.Drawing.Bitmap($cw, $ch)
    $g2 = [System.Drawing.Graphics]::FromImage($bmp2)
    $g2.CopyFromScreen($cx, $cy, 0, 0, (New-Object System.Drawing.Size($cw, $ch)))
    # 放大 2 倍便于看清
    $bmp3 = New-Object System.Drawing.Bitmap($bmp2, ($cw*2), ($ch*2))
    $out2 = Join-Path $env:TEMP 'qd_note_card_zoom.png'
    $bmp3.Save($out2, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp2.Dispose(); $bmp3.Dispose(); $g2.Dispose()
    Write-Output "card = $out2"
}

# 采样像素：正文底色 vs 标题栏底色（取同一张卡片内的两点）
Start-Sleep -Milliseconds 200
$bmpS = New-Object System.Drawing.Bitmap($w, $ht)
$gS = [System.Drawing.Graphics]::FromImage($bmpS)
$gS.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size($w, $ht)))
if ($e) {
    $b = $e.Current.BoundingRectangle
    $relX = [int]$b.X - $r.Left + 8
    $titleY = [int]$b.Y - $r.Top
    $c1 = $bmpS.GetPixel($relX, $titleY)
    $c2 = $bmpS.GetPixel($relX, $titleY + 70)
    Write-Output ("pixel header = #{0:X2}{1:X2}{2:X2} at ({3},{4})" -f $c1.R, $c1.G, $c1.B, $relX, $titleY)
    Write-Output ("pixel body   = #{0:X2}{1:X2}{2:X2} at ({3},{4})" -f $c2.R, $c2.G, $c2.B, $relX, ($titleY+70))
    $lum1 = 0.2126*$c1.R + 0.7152*$c1.G + 0.0722*$c1.B
    $lum2 = 0.2126*$c2.R + 0.7152*$c2.G + 0.0722*$c2.B
    Write-Output ("luminance header={0:F1} body={1:F1} -> header is {2}" -f $lum1, $lum2, $(if ($lum1 -lt $lum2) {'DARKER'} else {'LIGHTER-or-equal'}))
}
$gS.Dispose(); $bmpS.Dispose()
