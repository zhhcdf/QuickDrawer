$ErrorActionPreference = 'Stop'
$out = Join-Path $env:TEMP 'qd_strip_rtf.txt'
$lines = New-Object System.Collections.Generic.List[string]

try {
    $dll = 'D:\Documents\DeepSeek\快捷桌面项目\src\QuickDrawer\bin\Release\net48\QuickDrawer.exe'
    $asm = [Reflection.Assembly]::LoadFrom($dll)
    $t = $asm.GetType('QuickDrawer.ClipboardService')
    $m = $t.GetMethod('StripRtf', [Reflection.BindingFlags]'NonPublic,Static')
    $lines.Add('StripRtf found = ' + ($null -ne $m))

    $rtfPath = Join-Path $env:TEMP 'qd_excel_rtf.rtf'
    if (-not (Test-Path $rtfPath)) { $lines.Add('MISSING rtf file'); [IO.File]::WriteAllLines($out, $lines); Get-Content $out; exit 1 }
    $rtf = [IO.File]::ReadAllText($rtfPath, [Text.Encoding]::GetEncoding(936))
    $lines.Add('rtf len = ' + $rtf.Length)

    $plain = [string]$m.Invoke($null, @($rtf))
    $lines.Add('plain len = ' + $plain.Length)
    $lines.Add('has font names = ' + ($plain.Contains('fcharset') -or $plain.Contains('fnil')))
    $lines.Add('head = ' + $plain.Substring(0, [Math]::Min(160, $plain.Length)).Replace("`r", '\r').Replace("`n", '\n'))

    # Codepoints of the head so console codepage cannot fool us.
    $head = $plain.Substring(0, [Math]::Min(40, $plain.Length))
    $cps = @()
    foreach ($ch in $head.ToCharArray()) { $cps += ('{0:X4}' -f [int][char]$ch) }
    $lines.Add('head codepoints = ' + ($cps -join ' '))
}
catch {
    $lines.Add('ERROR: ' + $_.Exception.Message)
    $lines.Add($_.ScriptStackTrace)
}

[IO.File]::WriteAllLines($out, $lines)
Get-Content $out
