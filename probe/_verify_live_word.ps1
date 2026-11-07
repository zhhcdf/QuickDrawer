# Live check: copy a real Word table, confirm the running instance stores readable HTML.
$ErrorActionPreference = 'Stop'

# 2026-11-07 发布准备：探测目标 exe 改为运行时解析，不再写死个人发布目录。
# 如需指向别处，先设置环境变量 QD_EXE。
$exe = $env:QD_EXE
if (-not $exe) { $exe = Join-Path $env:LOCALAPPDATA 'QuickDrawer\QuickDrawer.exe' }
if (-not (Test-Path $exe)) { throw "QD_EXE not found: $exe  (set `$env:QD_EXE to the published QuickDrawer.exe)" }
Write-Host ('exe size = ' + (Get-Item $exe).Length + '  mtime = ' + (Get-Item $exe).LastWriteTime)

$word = New-Object -ComObject Word.Application
$word.Visible = $false
$word.DisplayAlerts = 0
$doc = $word.Documents.Add()
$tbl = $doc.Tables.Add($doc.Range(0, 0), 2, 2)
$tbl.Borders.Enable = 1
$tbl.Cell(1, 1).Range.Text = [char]0x514D + [char]0x8D39
$tbl.Cell(1, 2).Range.Text = [char]0x5F00 + [char]0x6E90
$tbl.Cell(2, 1).Range.Text = [char]0x672C + [char]0x5730
$tbl.Cell(2, 2).Range.Text = [char]0x79BB + [char]0x7EBF

$tbl.Range.Copy()
Start-Sleep -Seconds 4

# Word must stay alive until the app has rendered + captured the clipboard data.
$doc.Close(0)
$word.Quit()
[void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($word)

Start-Sleep -Seconds 2

$json = Join-Path $env:APPDATA 'QuickDrawer\clipboard.json'
$data = Get-Content $json -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Host ('entries = ' + $data.Entries.Count)
$newest = $data.Entries[0]
Write-Host ('newest = ' + $newest.CreatedAt + '  kind = ' + $newest.Kind + '  size = ' + $newest.SizeBytes)

if ($newest.Kind -ne 'Html') { Write-Host 'FAIL: newest entry is not Html'; exit 1 }

# Decrypt the payload with DPAPI and check the Chinese survived.
Add-Type -AssemblyName System.Security
$raw = [Convert]::FromBase64String($newest.EncryptedPayload)
$plain = [System.Security.Cryptography.ProtectedData]::Unprotect($raw, $null, 'CurrentUser')
$obj = [System.Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json
$text = $obj.Text

Write-Host ('decrypted length = ' + $text.Length)
$ok = $true
foreach ($ch in @(0x514D, 0x8D39, 0x5F00, 0x6E90)) {
    $lit = [char]$ch
    $ent = '&#' + $ch + ';'
    $hit = $text.Contains($lit) -or $text.Contains($ent)
    Write-Host ('  U+' + ('{0:X4}' -f $ch) + ' present = ' + $hit)
    if (-not $hit) { $ok = $false }
}
$hasTable = $text -match '<table'
Write-Host ('  <table> present = ' + $hasTable)
if (-not $hasTable) { $ok = $false }
$hasFFFD = $text.Contains([char]0xFFFD)
Write-Host ('  contains U+FFFD = ' + $hasFFFD)

if ($ok) { Write-Host 'PASS: running instance captured a readable Word table' }
else { Write-Host 'FAIL: captured HTML is not readable'; exit 1 }
