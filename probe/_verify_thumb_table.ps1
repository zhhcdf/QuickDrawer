# Verify the new thumbnail + table-preview helpers against the PUBLISHED assembly.
# Loads QuickDrawer.exe by reflection and calls the public statics directly.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# 2026-11-07 发布准备：探测目标 exe 改为运行时解析，不再写死个人发布目录。
# 如需指向别处，先设置环境变量 QD_EXE。
$exe = $env:QD_EXE
if (-not $exe) { $exe = Join-Path $env:LOCALAPPDATA 'QuickDrawer\QuickDrawer.exe' }
if (-not (Test-Path $exe)) { throw "QD_EXE not found: $exe  (set `$env:QD_EXE to the published QuickDrawer.exe)" }
$asm = [Reflection.Assembly]::LoadFrom($exe)
$svc = $asm.GetType('QuickDrawer.ClipboardService')
if ($null -eq $svc) { Write-Output 'FAIL: ClipboardService type not found'; exit 1 }

$blobs = Join-Path $env:APPDATA 'QuickDrawer\blobs'
$dib = Get-ChildItem $blobs -Filter *.dib | Sort-Object Length -Descending | Select-Object -First 1
Write-Output ("dib = " + $dib.Name + "  bytes = " + $dib.Length)

$load = $svc.GetMethod('LoadThumbnail')
$thumb = $load.Invoke($null, @($dib.FullName, 88))
if ($null -eq $thumb) {
    Write-Output 'FAIL: LoadThumbnail returned null'
} else {
    Write-Output ("thumbnail = " + $thumb.PixelWidth + " x " + $thumb.PixelHeight +
                  "  frozen=" + $thumb.IsFrozen + "  fmt=" + $thumb.Format)
}

# A DIB that does not exist must return null, not throw.
$missing = $load.Invoke($null, @('C:\nonexistent\zzz.dib', 88))
Write-Output ("missing path -> " + $(if ($null -eq $missing) { 'null (ok)' } else { 'UNEXPECTED' }))
$nullPath = $load.Invoke($null, @($null, 88))
Write-Output ("null path    -> " + $(if ($null -eq $nullPath) { 'null (ok)' } else { 'UNEXPECTED' }))

$parse = $svc.GetMethod('ParseTableRows')
$tableHtml = @'
<table border=1><tr><td>Product</td><td>Qty</td><td>Price</td></tr>
<tr><td>Widget</td><td>12</td><td>9.5</td></tr>
<tr><td>Gadget</td><td>7</td><td>24.25</td></tr></table>
'@
$rows = $parse.Invoke($null, @($tableHtml, 4, 6))
Write-Output ("table rows = " + $rows.Count)
foreach ($r in $rows) { Write-Output ("  row: " + ($r -join ' | ')) }

# Non-table HTML must produce zero rows (so the mini-table box stays hidden).
$plain = $parse.Invoke($null, @('<span>hello world</span>', 4, 6))
Write-Output ("plain html rows = " + $plain.Count + $(if ($plain.Count -eq 0) { ' (ok)' } else { ' (UNEXPECTED)' }))

# Word's real export wraps cells in <p class=MsoNormal>; StripTags must still work.
$wordish = '<table><tr><td><p class=MsoNormal><span lang=ZH-CN>免费</span></p></td><td><p class=MsoNormal>1</p></td></tr></table>'
$wrows = $parse.Invoke($null, @($wordish, 4, 6))
$joined = ($wrows | ForEach-Object { $_ -join '|' }) -join ' / '
Write-Output ("word-style rows = " + $wrows.Count + " -> " + $joined)
$cps = ($joined.ToCharArray() | Select-Object -First 2 | ForEach-Object { '{0:X4}' -f [int]$_ }) -join ' '
Write-Output ("first two codepoints = " + $cps + $(if ($cps -eq '514D 8D39') { ' (ok)' } else { ' (UNEXPECTED)' }))
