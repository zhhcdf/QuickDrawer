# End-to-end check that the running QuickDrawer instance now stores REAL Chinese for
# an HTML capture from Word (before the fix it stored UTF-8-as-UTF-16 mojibake).
#
# We never print Chinese to the console - the codepage mangles it and that mangling is
# indistinguishable from real corruption. We assert on codepoint properties instead.

$ErrorActionPreference = 'Stop'

$word = $null
$doc  = $null
try {
    $word = New-Object -ComObject Word.Application
    $word.Visible = $false
    $word.DisplayAlerts = 0
    $doc = $word.Documents.Add()

    $tbl = $doc.Tables.Add($doc.Content, 2, 2)
    # 免费开源 = U+514D U+8D39 U+5F00 U+6E90
    $tbl.Cell(1,1).Range.Text = [string][char]0x514D + [string][char]0x8D39
    $tbl.Cell(1,2).Range.Text = 'B1'
    $tbl.Cell(2,1).Range.Text = [string][char]0x5F00 + [string][char]0x6E90
    $tbl.Cell(2,2).Range.Text = 'B2'
    $tbl.Range.Copy()
    Write-Host 'copied Chinese table from Word'
    Start-Sleep -Seconds 4
}
finally {
    if ($doc  -ne $null) { try { $doc.Close(0) } catch {} }
    if ($word -ne $null) { try { $word.Quit(0) } catch {} }
}

# Wait for the app's background DPAPI save to land.
Start-Sleep -Seconds 3

$path = Join-Path $env:APPDATA 'QuickDrawer\clipboard.json'
$raw = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
$json = $raw | ConvertFrom-Json
$entries = $json.Entries
Write-Host ('entries = ' + $entries.Count)

# Newest Html entry
$html = @($entries | Where-Object { $_.Kind -eq 'Html' })
Write-Host ('html entries = ' + $html.Count)
if ($html.Count -eq 0) { Write-Host 'FAIL: no Html entry captured'; exit 1 }

$newest = $html[0]
Write-Host ('newest created = ' + $newest.CreatedAt + ' sizeBytes = ' + $newest.SizeBytes)

Add-Type -AssemblyName System.Security
$cipher = [Convert]::FromBase64String($newest.EncryptedPayload)
$plain  = [Security.Cryptography.ProtectedData]::Unprotect(
              $cipher, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
$inner  = [Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json
$text   = $inner.Text
Write-Host ('decrypted text length = ' + $text.Length)

$hasCjk   = $false
$hasFffd  = $false
foreach ($c in $text.ToCharArray()) {
    if ($c -eq [char]0xFFFD) { $hasFffd = $true }
    elseif ($c -ge [char]0x4E00 -and $c -le [char]0x9FFF) { $hasCjk = $true }
}

$needle     = [string][char]0x514D + [string][char]0x8D39        # 免费
$needle2    = [string][char]0x5F00 + [string][char]0x6E90        # 开源
$entity     = '&#20813;&#36153;'
$entity2    = '&#24320;&#28304;'

$hasNeedle  = $text.Contains($needle)  -or $text.Contains($entity)
$hasNeedle2 = $text.Contains($needle2) -or $text.Contains($entity2)
$hasTable   = $text.Contains('<table') -or $text.Contains('<TABLE')
$hasVer     = $text.Contains('Version:')

Write-Host ("hasCjk=$hasCjk hasFFFD=$hasFffd")
Write-Host ("needle(免费) raw-or-entity = $hasNeedle")
Write-Host ("needle(开源) raw-or-entity = $hasNeedle2")
Write-Host ("<table> present = $hasTable")

$ok = $true
if (-not $hasTable)   { Write-Host 'FAIL: stored fragment lost the <table> markup'; $ok = $false }
if (-not $hasNeedle)  { Write-Host 'FAIL: stored fragment lost 免费 (neither raw nor entity form)'; $ok = $false }
if (-not $hasNeedle2) { Write-Host 'FAIL: stored fragment lost 开源 (neither raw nor entity form)'; $ok = $false }
if ($hasFffd)         { Write-Host 'FAIL: stored fragment contains U+FFFD'; $ok = $false }
if ($hasVer)          { Write-Host 'WARN: stored fragment still contains the Version header (fragment extraction off)' }
if ($ok) { Write-Host 'PASS: Word HTML capture now stores readable Chinese with table markup intact' }
