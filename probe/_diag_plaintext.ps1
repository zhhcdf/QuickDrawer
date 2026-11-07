# 追查 S5 的差异：真实 WriteBack 走的 plain 到底算出什么。
# 假设：PowerShell 给 string 属性赋 $null 时可能落成 ""（空串），
# 于是 `entry.PlainText ?? HtmlToPlainText(...)` 里的 ?? 不触发，plain 为空，
# 纯文本写入被 `if (plain.Length > 0)` 跳过 —— 脚本自己制造的假故障。
$ErrorActionPreference = 'Stop'

$exe = $env:QD_EXE
if (-not $exe) { $exe = Join-Path $env:LOCALAPPDATA 'QuickDrawer\QuickDrawer.exe' }
$asm = [System.Reflection.Assembly]::LoadFrom($exe)
$entryType = $asm.GetType('QuickDrawer.ClipEntry')
$kindType = $asm.GetType('QuickDrawer.ClipKind')
$svc = $asm.GetType('QuickDrawer.ClipboardService')
$prop = $entryType.GetProperty('PlainText')
$toPlain = $svc.GetMethod('HtmlToPlainText', [System.Reflection.BindingFlags]'Public,NonPublic,Static')

$html = '<table border=1><tr><td>A1</td><td>B1</td></tr></table>'

Write-Host '=== A. brand new entry (never touched) ==='
$a = [System.Activator]::CreateInstance($entryType)
Write-Host ("  PlainText is `$null : {0}" -f ($null -eq $prop.GetValue($a)))
Write-Host ("  PlainText is ''    : {0}" -f ('' -eq $prop.GetValue($a)))

Write-Host '=== B. after PowerShell assigns $null ==='
$b = [System.Activator]::CreateInstance($entryType)
$b.PlainText = $null
Write-Host ("  PlainText is `$null : {0}" -f ($null -eq $prop.GetValue($b)))
Write-Host ("  PlainText is ''    : {0}" -f ('' -eq $prop.GetValue($b)))

Write-Host '=== C. what WriteBack would compute as plain ==='
$derived = $toPlain.Invoke($null, @($html))
Write-Host ("  HtmlToPlainText   -> [{0}] len={1}" -f ($derived -replace "`t", '\t'), $derived.Length)
foreach ($case in @(@('new entry', $a), @('null-assigned', $b))) {
    $e = $case[1]
    $pt = $prop.GetValue($e)
    $plain = if ($null -ne $pt) { $pt } else { $derived }
    Write-Host ("  [{0}] PlainText=[{1}] -> plain len={2} (writes text: {3})" -f `
        $case[0], $pt, $plain.Length, ($plain.Length -gt 0))
}

Write-Host '=== D. WriteBack with an untouched entry ==='
$e = [System.Activator]::CreateInstance($entryType)
$e.Kind = [System.Enum]::Parse($kindType, 'Html')
$e.Text = $html
$e.Preview = 'A1 B1'
Write-Host ("  WriteBack -> {0}" -f $svc::WriteBack($e))
