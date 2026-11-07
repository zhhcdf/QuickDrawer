$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Core
$dll = 'D:\Documents\DeepSeek\快捷桌面项目\src\QuickDrawer\bin\Release\net48\QuickDrawer.exe'
if (-not (Test-Path $dll)) { Write-Output ("MISSING " + $dll); exit 1 }
$asm = [Reflection.Assembly]::LoadFrom($dll)
$t = $asm.GetType('QuickDrawer.ClipboardService')
$m = $t.GetMethod('ExtractTableAware', [Reflection.BindingFlags]'NonPublic,Static')
Write-Output ('ExtractTableAware found = ' + ($null -ne $m))
$find = $t.GetMethod('FindHeaderOffset', [Reflection.BindingFlags]'NonPublic,Static')

$tmp = [IO.Path]::GetTempPath()
$cases = @(
  @{ name = 'EXCEL-LIVE'; path = (Join-Path $tmp 'qd_excel_live.bin') },
  @{ name = 'EXCEL'; path = (Join-Path $tmp 'qd_excel_html.bin') },
  @{ name = 'WORD-TABLE'; path = (Join-Path $tmp 'qd_html_probe\B_word_table_html.bin') },
  @{ name = 'WORD-TEXT'; path = (Join-Path $tmp 'qd_html_probe\A_word_text_html.bin') }
)

foreach ($c in $cases) {
  if (-not (Test-Path $c.path)) { Write-Output ($c.name + ' MISSING'); continue }
  $raw = [IO.File]::ReadAllBytes($c.path)
  $head = [Text.Encoding]::ASCII.GetString($raw, 0, [Math]::Min($raw.Length, 4096))
  $sf = [int]$find.Invoke($null, @($head, 'StartFragment'))
  $ef = [int]$find.Invoke($null, @($head, 'EndFragment'))
  $frag = [string]$m.Invoke($null, @($raw, $sf, $ef))
  $hasTable = $frag.ToLower().Contains('<table')
  $hasTr = $frag.ToLower().Contains('<tr')
  $hasMarker = $frag.Contains('<!--StartFragment-->') -or $frag.Contains('<!--EndFragment-->')
  $closed = $frag.ToLower().Contains('</table>')
  Write-Output ('=== ' + $c.name + ' raw=' + $raw.Length + ' sf=' + $sf + ' ef=' + $ef)
  Write-Output ('    fragLen=' + $frag.Length + ' hasTable=' + $hasTable + ' hasCloseTable=' + $closed + ' hasTr=' + $hasTr + ' markerLeft=' + $hasMarker)
  Write-Output ('    head=' + $frag.Substring(0, [Math]::Min(70, $frag.Length)).Replace("`r", '\r').Replace("`n", '\n'))
}
