"""从发布 exe 提取关联图标，验证资源管理器会显示的新图标。

上一版用 ExtractIconEx + GetIconInfo + GetObject，bmWidth/bmHeight 返回 0：
原因是 ICONINFO.hbmColor 对 32 位图标可能是 DIB 段，GetObject 需要 BITMAP 结构大小
传对；改用 .NET 自带的 ExtractAssociatedIcon 更省事，它内部走 SHGetFileInfo。
"""
Add-Type -AssemblyName System.Drawing

$out = Join-Path $env:TEMP 'qd_icon_check'
# 2026-11-07 发布准备：探测目标 exe 改为运行时解析，不再写死个人发布目录。
# 如需指向别处，先设置环境变量 QD_EXE。
$exe = $env:QD_EXE
if (-not $exe) { $exe = Join-Path $env:LOCALAPPDATA 'QuickDrawer\QuickDrawer.exe' }
if (-not (Test-Path $exe)) { throw "QD_EXE not found: $exe  (set `$env:QD_EXE to the published QuickDrawer.exe)" }

$ico = [System.Drawing.Icon]::ExtractAssociatedIcon($exe)
"extract ok: $($ico -ne $null)  size=$($ico.Width)x$($ico.Height)"
$bmp = $ico.ToBitmap()
$p = Join-Path $out 'exe_assoc_icon.png'
$bmp.Save($p, [System.Drawing.Imaging.ImageFormat]::Png)
"$p  ($($bmp.Width)x$($bmp.Height))"

# 统计金黄像素（Y2 = #F9C424）
$cnt = 0
for ($y = 0; $y -lt $bmp.Height; $y++) {
    for ($x = 0; $x -lt $bmp.Width; $x++) {
        $px = $bmp.GetPixel($x, $y)
        if ($px.A -gt 200 -and [math]::Abs($px.R - 0xF9) -le 24 -and [math]::Abs($px.G - 0xC4) -le 24 -and [math]::Abs($px.B - 0x24) -le 24) { $cnt++ }
    }
}
"golden pixels: $cnt / $($bmp.Width * $bmp.Height)"
$bmp.Dispose()
$ico.Dispose()

# 放大 12 倍看清楚
$b2 = [System.Drawing.Bitmap]::FromFile($p)
$big = New-Object System.Drawing.Bitmap(($b2.Width * 12), ($b2.Height * 12))
$g = [System.Drawing.Graphics]::FromImage($big)
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
$g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
$g.DrawImage($b2, 0, 0, $big.Width, $big.Height)
$g.Dispose()
$p3 = Join-Path $out 'exe_assoc_icon_x12.png'
$big.Save($p3, [System.Drawing.Imaging.ImageFormat]::Png)
"$p3  ($($big.Width)x$($big.Height))"
$big.Dispose()
$b2.Dispose()
