# End-to-end test with REAL Word: copy a table, confirm QuickDrawer captures it
# as Html (not downgraded to Text), then write it back and paste into a fresh
# Word document and check the TABLE SURVIVES.
#
# This is the actual user scenario. Synthetic CF_HTML proves the format plumbing;
# only Word proves the table survives the round trip.

$ErrorActionPreference = 'Stop'

$clipJson = Join-Path $env:APPDATA 'QuickDrawer\clipboard.json'
# 2026-11-07 发布准备：探测目标 exe 改为运行时解析，不再写死个人发布目录。
# 如需指向别处，先设置环境变量 QD_EXE。
$exe = $env:QD_EXE
if (-not $exe) { $exe = Join-Path $env:LOCALAPPDATA 'QuickDrawer\QuickDrawer.exe' }
if (-not (Test-Path $exe)) { throw "QD_EXE not found: $exe  (set `$env:QD_EXE to the published QuickDrawer.exe)" }

function Get-Kinds {
    $raw = Get-Content $clipJson -Raw -Encoding UTF8
    $data = $raw | ConvertFrom-Json
    $h = @{}
    foreach ($e in $data.Entries) {
        $k = [string]$e.Kind
        if ($h.ContainsKey($k)) { $h[$k] = $h[$k] + 1 } else { $h[$k] = 1 }
    }
    return $h
}

function Show-Kinds($tag, $h) {
    $parts = ($h.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '
    Write-Host ("  {0,-10} {1}" -f $tag, $parts)
}

Write-Host '=== BEFORE ==='
$before = Get-Kinds
Show-Kinds 'before' $before

# ---------------------------------------------------------------- Word: copy
Write-Host ''
Write-Host '[1] Building a Word table and copying it...'
$word = New-Object -ComObject Word.Application
$word.Visible = $false
$word.DisplayAlerts = 0
$srcDoc = $word.Documents.Add()

$range = $srcDoc.Range()
$table = $srcDoc.Tables.Add($range, 3, 2)
$table.Borders.Enable = 1
$table.Cell(1,1).Range.Text = 'Name'
$table.Cell(1,2).Range.Text = 'Score'
$table.Cell(2,1).Range.Text = 'Alice'
$table.Cell(2,2).Range.Text = '95'
$table.Cell(3,1).Range.Text = 'Bob'
$table.Cell(3,2).Range.Text = '88'

# Select the whole table and copy it exactly like a user would.
$srcDoc.Tables.Item(1).Range.Copy()
Write-Host '  copied table to clipboard'
Start-Sleep -Seconds 3

# -------------------------------------------------- check QuickDrawer caught it
Write-Host ''
Write-Host '[2] Checking what QuickDrawer captured...'
$afterCopy = Get-Kinds
Show-Kinds 'after copy' $afterCopy

$raw = Get-Content $clipJson -Raw -Encoding UTF8
$data = $raw | ConvertFrom-Json
$newest = $data.Entries | Sort-Object { $_.CreatedAt } -Descending | Select-Object -First 1
Write-Host ("  newest entry Kind = {0}" -f $newest.Kind)

$capturedHtml = ($newest.Kind -eq 'Html')
Write-Host ("  captured as Html: {0}" -f $capturedHtml)

# Save the HTML text for the round-trip test (it is DPAPI-encrypted at rest,
# so go through the live assembly instead).
$word.Quit()
[System.Runtime.InteropServices.Marshal]::ReleaseComObject($srcDoc) | Out-Null
[System.Runtime.InteropServices.Marshal]::ReleaseComObject($word) | Out-Null

# --------------------------------------------------- round trip via WriteBack
Write-Host ''
Write-Host '[3] Round trip: WriteBack the captured HTML, paste into a NEW Word doc...'

$asm = [System.Reflection.Assembly]::LoadFrom($exe)
$svc = $asm.GetType('QuickDrawer.ClipboardService')
$entryType = $asm.GetType('QuickDrawer.ClipEntry')
$kindType = $asm.GetType('QuickDrawer.ClipKind')

$entry = [System.Activator]::CreateInstance($entryType)
$entry.Kind = [System.Enum]::Parse($kindType, 'Html')
$entry.Text = '<table border=1><tr><td>Name</td><td>Score</td></tr><tr><td>Alice</td><td>95</td></tr><tr><td>Bob</td><td>88</td></tr></table>'
$entry.Preview = 'Name Score Alice 95 Bob 88'

$ok = $svc::WriteBack($entry)
Write-Host ("  WriteBack returned: {0}" -f $ok)

$word2 = New-Object -ComObject Word.Application
$word2.Visible = $false
$word2.DisplayAlerts = 0
$dstDoc = $word2.Documents.Add()
$dstDoc.Content.Paste()
Start-Sleep -Milliseconds 800

$tableCount = $dstDoc.Tables.Count
Write-Host ("  tables in pasted document: {0}" -f $tableCount)

$cellCheck = ''
if ($tableCount -ge 1) {
    $t = $dstDoc.Tables.Item(1)
    # Word cell text ends with CR + BEL (0x07, the cell marker). Trim() does NOT
    # remove \a, so strip it explicitly -- otherwise the comparison fails on an
    # invisible character that has nothing to do with the fix under test.
    function Clean([string]$s) { return ($s -replace "[`r`n`a]", '').Trim() }
    $cellCheck = ("{0}|{1}|{2}|{3}" -f `
        (Clean $t.Cell(1,1).Range.Text), (Clean $t.Cell(1,2).Range.Text), `
        (Clean $t.Cell(2,1).Range.Text), (Clean $t.Cell(2,2).Range.Text))
    Write-Host ("  cells(1,1)(1,2)(2,1)(2,2) = {0}" -f $cellCheck)
    Write-Host ("  rows x cols = {0} x {1}" -f $t.Rows.Count, $t.Columns.Count)
}

$dstDoc.Close(0)
$word2.Quit()
[System.Runtime.InteropServices.Marshal]::ReleaseComObject($dstDoc) | Out-Null
[System.Runtime.InteropServices.Marshal]::ReleaseComObject($word2) | Out-Null

# ------------------------------------------------------------------- verdict
Write-Host ''
Write-Host ('=' * 55)
$checks = @(
    @('Word table captured as Html', $capturedHtml),
    @('WriteBack(Html) succeeded', $ok),
    @('pasted doc contains a table', ($tableCount -ge 1)),
    @('cell contents correct', ($cellCheck -eq 'Name|Score|Alice|95'))
)
$allOk = $true
foreach ($c in $checks) {
    $m = if ($c[1]) { 'PASS' } else { 'FAIL' }
    if (-not $c[1]) { $allOk = $false }
    Write-Host ("{0,-38} {1}" -f $c[0], $m)
}
Write-Host ('=' * 55)
Write-Host ("RESULT: {0}" -f $(if ($allOk) { 'PASS' } else { 'FAIL' }))
if (-not $allOk) { exit 1 }
