$ErrorActionPreference = 'Stop'
$out = Join-Path $env:TEMP 'qd_excel_pasteback.txt'
$lines = New-Object System.Collections.Generic.List[string]

try {
    Add-Type -AssemblyName System.Security
    # 2026-11-07 发布准备：探测目标 exe 改为运行时解析，不再写死个人发布目录。
    # 如需指向别处，先设置环境变量 QD_EXE。
    $exe = $env:QD_EXE
    if (-not $exe) { $exe = Join-Path $env:LOCALAPPDATA 'QuickDrawer\QuickDrawer.exe' }
    if (-not (Test-Path $exe)) { throw "QD_EXE not found: $exe  (set `$env:QD_EXE to the published QuickDrawer.exe)" }
    $dll = $exe
    $asm = [Reflection.Assembly]::LoadFrom($dll)
    $svcType = $asm.GetType('QuickDrawer.ClipboardService')
    $entryType = $asm.GetType('QuickDrawer.ClipEntry')
    $writeBack = $svcType.GetMethod('WriteBack', [Reflection.BindingFlags]'Public,Static')

    # Rebuild a ClipEntry carrying the captured Excel HTML fragment.
    $raw = [IO.File]::ReadAllBytes((Join-Path $env:TEMP 'qd_excel_live.bin'))
    $head = [Text.Encoding]::ASCII.GetString($raw, 0, [Math]::Min($raw.Length, 4096))
    $find = $svcType.GetMethod('FindHeaderOffset', [Reflection.BindingFlags]'NonPublic,Static')
    $extract = $svcType.GetMethod('ExtractTableAware', [Reflection.BindingFlags]'NonPublic,Static')
    $style = $svcType.GetMethod('ExtractStyleBlock', [Reflection.BindingFlags]'NonPublic,Static')
    $slice = $svcType.GetMethod('Slice', [Reflection.BindingFlags]'NonPublic,Static')

    $sf = [int]$find.Invoke($null, @($head, 'StartFragment'))
    $ef = [int]$find.Invoke($null, @($head, 'EndFragment'))
    $sh = [int]$find.Invoke($null, @($head, 'StartHTML'))
    $frag = [string]$extract.Invoke($null, @($raw, $sf, $ef))
    $headHtml = [Text.Encoding]::UTF8.GetString([byte[]]$slice.Invoke($null, @($raw, $sh, $sf)))
    $styleBlock = [string]$style.Invoke($null, @($headHtml))

    $lines.Add('fragLen=' + $frag.Length + ' styleLen=' + $styleBlock.Length)
    $lines.Add('frag hasTable=' + $frag.ToLower().Contains('<table'))

    $entry = [Activator]::CreateInstance($entryType)
    $entryType.GetProperty('Kind').SetValue($entry, [Enum]::Parse($asm.GetType('QuickDrawer.ClipKind'), 'Html'))
    $entryType.GetProperty('Text').SetValue($entry, $frag)
    $entryType.GetProperty('HtmlStyle').SetValue($entry, $styleBlock)
    $entryType.GetProperty('Preview').SetValue($entry, 'excel-verify')

    $ok = [bool]$writeBack.Invoke($null, @($entry))
    $lines.Add('WriteBack = ' + $ok)
    Start-Sleep -Milliseconds 500

    # Paste into a brand new workbook and inspect the resulting used range.
    $xl = New-Object -ComObject Excel.Application
    $xl.Visible = $false
    $xl.DisplayAlerts = $false
    $wb = $xl.Workbooks.Add()
    $ws = $wb.Worksheets.Item(1)
    $ws.Range('A1').Select() | Out-Null
    $ws.Paste() | Out-Null
    Start-Sleep -Milliseconds 800

    $used = $ws.UsedRange
    $lines.Add('used rows=' + $used.Rows.Count + ' cols=' + $used.Columns.Count)
    $cells = @()
    for ($r = 1; $r -le [Math]::Min(3, $used.Rows.Count); $r++) {
        $row = @()
        for ($c = 1; $c -le [Math]::Min(3, $used.Columns.Count); $c++) {
            $v = $ws.Cells.Item($r, $c).Text
            $row += [string]$v
        }
        $cells += ($row -join '|')
    }
    $lines.Add('grid: ' + ($cells -join ' / '))

    $wb.Close($false)
    $xl.Quit()
}
catch {
    $lines.Add('ERROR: ' + $_.Exception.Message)
    $lines.Add($_.ScriptStackTrace)
}

[IO.File]::WriteAllLines($out, $lines)
Get-Content $out
