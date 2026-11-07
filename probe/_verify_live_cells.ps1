# Verify pasted cell text by code point, not by console rendering.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
# 2026-11-07 发布准备：探测目标 exe 改为运行时解析，不再写死个人发布目录。
# 如需指向别处，先设置环境变量 QD_EXE。
$exe = $env:QD_EXE
if (-not $exe) { $exe = Join-Path $env:LOCALAPPDATA 'QuickDrawer\QuickDrawer.exe' }
if (-not (Test-Path $exe)) { throw "QD_EXE not found: $exe  (set `$env:QD_EXE to the published QuickDrawer.exe)" }

$asm = [Reflection.Assembly]::LoadFrom($exe)
$svc = $asm.GetType('QuickDrawer.ClipboardService')
$entryType = $asm.GetType('QuickDrawer.ClipEntry')

$json = Join-Path $env:APPDATA 'QuickDrawer\clipboard.json'
$data = Get-Content $json -Raw -Encoding UTF8 | ConvertFrom-Json
$newest = $data.Entries[0]

$entry = [Activator]::CreateInstance($entryType)
$entryType.GetProperty('Kind').SetValue($entry, [Enum]::Parse($asm.GetType('QuickDrawer.ClipKind'), $newest.Kind))
$entryType.GetProperty('CreatedAt').SetValue($entry, [datetime]::Parse($newest.CreatedAt))
$raw = [Convert]::FromBase64String($newest.EncryptedPayload)
$plain = [System.Security.Cryptography.ProtectedData]::Unprotect($raw, $null, 'CurrentUser')
$obj = [System.Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json
$entryType.GetProperty('Text').SetValue($entry, $obj.Text)
$entryType.GetProperty('Preview').SetValue($entry, $obj.Preview)

$writeBack = $svc.GetMethod('WriteBack', [Reflection.BindingFlags]::Public -bor [Reflection.BindingFlags]::Static)
$null = $writeBack.Invoke($null, @($entry))
Start-Sleep -Milliseconds 500

$word = New-Object -ComObject Word.Application
$word.Visible = $false
$word.DisplayAlerts = 0
$doc = $word.Documents.Add()
$doc.Content.Paste()
Start-Sleep -Milliseconds 800

$t = $doc.Tables.Item(1)
Write-Host ('tables = ' + $doc.Tables.Count + '  rows x cols = ' + $t.Rows.Count + ' x ' + $t.Columns.Count)
$ok = $true
foreach ($c in $t.Range.Cells) {
    $s = $c.Range.Text -replace "[`r`n`a]", ''
    $hex = ($s.ToCharArray() | ForEach-Object { '{0:X4}' -f [int]$_ }) -join ' '
    Write-Host ('  cell[' + $c.RowIndex + ',' + $c.ColumnIndex + '] = ' + $hex)
    if ($s.Length -ne 2) { $ok = $false }
}
$doc.Close(0)
$word.Quit()
[void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($word)

# Expected: 514D 8D39 / 5F00 6E90 / 672C 5730 / 79BB 7EBF
if ($ok) { Write-Host 'PASS: all four cells hold exactly 2 CJK chars' }
else { Write-Host 'FAIL: cell text length unexpected'; exit 1 }
