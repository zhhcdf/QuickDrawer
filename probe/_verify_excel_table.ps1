# Excel table round trip.
#
# The user explicitly reported Excel alongside Word. Excel's clipboard payload
# differs from Word's: it also publishes BIFF/CSV and its HTML uses a <table>
# with inline styles. Verify capture-as-Html AND that pasting back into Excel
# still produces a real grid, not one column of text.

$ErrorActionPreference = 'Stop'

$clipJson = Join-Path $env:APPDATA 'QuickDrawer\clipboard.json'
# 2026-11-07 发布准备：探测目标 exe 改为运行时解析，不再写死个人发布目录。
# 如需指向别处，先设置环境变量 QD_EXE。
$exe = $env:QD_EXE
if (-not $exe) { $exe = Join-Path $env:LOCALAPPDATA 'QuickDrawer\QuickDrawer.exe' }
if (-not (Test-Path $exe)) { throw "QD_EXE not found: $exe  (set `$env:QD_EXE to the published QuickDrawer.exe)" }

function Get-Kinds {
    $d = (Get-Content $clipJson -Raw -Encoding UTF8) | ConvertFrom-Json
    $h = @{}
    foreach ($e in $d.Entries) {
        $k = [string]$e.Kind
        if ($h.ContainsKey($k)) { $h[$k] = $h[$k] + 1 } else { $h[$k] = 1 }
    }
    return $h
}

function Show($tag, $h) {
    $s = ($h.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '
    Write-Host ("  {0,-12} {1}" -f $tag, $s)
}

Write-Host '=== BEFORE ==='
Show 'before' (Get-Kinds)

# ---------------------------------------------------------------- Excel copy
Write-Host ''
Write-Host '[1] Building an Excel range and copying it...'
$xl = New-Object -ComObject Excel.Application
$xl.Visible = $false
$xl.DisplayAlerts = $false
$wb = $xl.Workbooks.Add()
$ws = $wb.Worksheets.Item(1)

$ws.Cells.Item(1,1).Value2 = 'Product'
$ws.Cells.Item(1,2).Value2 = 'Qty'
$ws.Cells.Item(1,3).Value2 = 'Price'
$ws.Cells.Item(2,1).Value2 = 'Widget'
$ws.Cells.Item(2,2).Value2 = 12
$ws.Cells.Item(2,3).Value2 = 9.5
$ws.Cells.Item(3,1).Value2 = 'Gadget'
$ws.Cells.Item(3,2).Value2 = 7
$ws.Cells.Item(3,3).Value2 = 24.25

$range = $ws.Range('A1:C3')
$range.Copy()
Write-Host '  copied A1:C3'
Start-Sleep -Seconds 3

# ------------------------------------------------------------- what we caught
Write-Host ''
Write-Host '[2] What QuickDrawer captured...'
$after = Get-Kinds
Show 'after copy' $after

$d = (Get-Content $clipJson -Raw -Encoding UTF8) | ConvertFrom-Json
$newest = $d.Entries | Sort-Object CreatedAt -Descending | Select-Object -First 1
Write-Host ("  newest Kind = {0}, size = {1}" -f $newest.Kind, $newest.SizeBytes)

$xl.Quit()
[System.Runtime.InteropServices.Marshal]::ReleaseComObject($ws) | Out-Null
[System.Runtime.InteropServices.Marshal]::ReleaseComObject($wb) | Out-Null
[System.Runtime.InteropServices.Marshal]::ReleaseComObject($xl) | Out-Null
[GC]::Collect()

# --------------------------------------------------------------- paste back
Write-Host ''
Write-Host '[3] WriteBack + paste into a fresh workbook...'

$asm = [System.Reflection.Assembly]::LoadFrom($exe)
$svc = $asm.GetType('QuickDrawer.ClipboardService')
$entryType = $asm.GetType('QuickDrawer.ClipEntry')
$kindType = $asm.GetType('QuickDrawer.ClipKind')

$entry = [System.Activator]::CreateInstance($entryType)
$entry.Kind = [System.Enum]::Parse($kindType, 'Html')
$entry.Text = '<table><tr><td>Product</td><td>Qty</td><td>Price</td></tr><tr><td>Widget</td><td>12</td><td>9.5</td></tr><tr><td>Gadget</td><td>7</td><td>24.25</td></tr></table>'
$entry.Preview = 'Product Qty Price Widget 12 9.5 Gadget 7 24.25'

$ok = $svc::WriteBack($entry)
Write-Host ("  WriteBack returned: {0}" -f $ok)

$xl2 = New-Object -ComObject Excel.Application
$xl2.Visible = $false
$xl2.DisplayAlerts = $false
$wb2 = $xl2.Workbooks.Add()
$ws2 = $wb2.Worksheets.Item(1)
$ws2.Range('A1').Select()
$ws2.Paste()
Start-Sleep -Milliseconds 900

# Read back the grid.
$vals = @()
foreach ($r in 1..3) {
    $row = @()
    foreach ($c in 1..3) {
        $v = $ws2.Cells.Item($r, $c).Value2
        $row += $(if ($null -eq $v) { '' } else { [string]$v })
    }
    $vals += ($row -join '|')
    Write-Host ("  row{0}: {1}" -f $r, ($row -join '|'))
}

$xl2.Quit()
[System.Runtime.InteropServices.Marshal]::ReleaseComObject($ws2) | Out-Null
[System.Runtime.InteropServices.Marshal]::ReleaseComObject($wb2) | Out-Null
[System.Runtime.InteropServices.Marshal]::ReleaseComObject($xl2) | Out-Null
[GC]::Collect()

Write-Host ''
Write-Host ('=' * 55)
$gridOk = ($vals.Count -eq 3 -and $vals[0] -eq 'Product|Qty|Price' -and $vals[1] -like 'Widget|12*' -and $vals[2] -like 'Gadget|7*')
$checks = @(
    @('Excel range captured as Html', ($newest.Kind -eq 'Html')),
    @('WriteBack(Html) succeeded', $ok),
    @('pasted as a real 3-column grid', $gridOk)
)
$allOk = $true
foreach ($c in $checks) {
    $m = if ($c[1]) { 'PASS' } else { 'FAIL' }
    if (-not $c[1]) { $allOk = $false }
    Write-Host ("{0,-36} {1}" -f $c[0], $m)
}
Write-Host ('=' * 55)
Write-Host ("RESULT: {0}" -f $(if ($allOk) { 'PASS' } else { 'FAIL' }))
if (-not $allOk) { exit 1 }
