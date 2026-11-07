$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# 用 XamlReader 单独解析主题字典，验证：
#   1. XML 能正常解析（暗色字典若有语法错，只有深色主题用户启动时才会崩，浅色下永远测不到）
#   2. 五个 Note*Header 键都在，且颜色值正确
#   3. 每个 Header 的亮度都低于同色系正文 Note*（这是用户需求"比正文底色深一点"的定义）
function Load-Dict([string]$path) {
    $xaml = Get-Content -Path $path -Raw -Encoding UTF8
    $sr = New-Object System.IO.StringReader($xaml)
    $xr = New-Object System.Windows.Markup.XamlReader
    return $xr.Load($sr)
}

function HexOf($brush) {
    $c = $brush.Color
    return ('#{0:X2}{1:X2}{2:X2}' -f $c.R, $c.G, $c.B)
}

function Lum($brush) {
    $c = $brush.Color
    return 0.2126 * $c.R + 0.7152 * $c.G + 0.0722 * $c.B
}

$colors = @('Yellow', 'Green', 'Blue', 'Pink', 'Gray')
$root = Split-Path -Parent $PSScriptRoot
foreach ($theme in @('Dark', 'Light')) {
    $path = Join-Path $root "src\QuickDrawer\Themes\$theme.xaml"
    Write-Output "=== $theme : $path"
    $d = $null
    try {
        $d = Load-Dict $path
        Write-Output '  parse: OK'
    } catch {
        Write-Output ("  parse: FAIL - {0}" -f $_.Exception.Message)
        continue
    }
    foreach ($c in $colors) {
        $bodyKey = "Note$c"
        $headKey = "Note${c}Header"
        $body = $d[$bodyKey]
        $head = $d[$headKey]
        if ($body -eq $null) { Write-Output ("  {0}: MISSING body key {1}" -f $c, $bodyKey); continue }
        if ($head -eq $null) { Write-Output ("  {0}: MISSING header key {1}" -f $c, $headKey); continue }
        $lb = Lum $body; $lh = Lum $head
        $verdict = if ($lh -lt $lb) { 'DARKER' } else { 'NOT-DARKER' }
        $ratio = if ($lb -gt 0) { $lh / $lb } else { 0 }
        Write-Output ("  {0,-6} body={1} head={2}  lum {3:F1} -> {4:F1} (x{5:F3})  {6}" -f $c, (HexOf $body), (HexOf $head), $lb, $lh, $ratio, $verdict)
    }
}
