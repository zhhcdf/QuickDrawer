# Verify the "Normal 0" defect is gone: copy plain TEXT from Word (not a table)
# and inspect what QuickDrawer actually stored.
#
# Two traps this script works around:
#   1. Entries are stored NEWEST-FIRST, so $entries[-1] is the OLDEST one.
#      Always pick by max(CreatedAt), never by position.
#   2. Word renders the HTML Format lazily, so Word must stay alive while we read.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

$mianfei = [string]([char]0x514D) + [string]([char]0x8D39)
$kaiyuan = [string]([char]0x5F00) + [string]([char]0x6E90)
$de      = [string]([char]0x7684)
$jiantie = [string]([char]0x526A) + [string]([char]0x8D34) + [string]([char]0x677F)
$sentence = $mianfei + $kaiyuan + $de + $jiantie

$json = Join-Path $env:APPDATA 'QuickDrawer\clipboard.json'
$before = @((Get-Content $json -Raw -Encoding UTF8 | ConvertFrom-Json).Entries).Count
Write-Output ("entries before = " + $before)

$word = New-Object -ComObject Word.Application
$word.Visible = $true
$doc = $word.Documents.Add()
$doc.Content.Text = $sentence
$doc.Content.Select()
Start-Sleep -Milliseconds 400
$doc.Content.Copy()
Start-Sleep -Seconds 4

$entries = @((Get-Content $json -Raw -Encoding UTF8 | ConvertFrom-Json).Entries)
Write-Output ("entries after  = " + $entries.Count)

$newest = $entries | Sort-Object { [datetime]$_.CreatedAt } -Descending | Select-Object -First 1
Write-Output ("newest kind    = " + $newest.Kind)
Write-Output ("newest created = " + $newest.CreatedAt)

$cipher = [Convert]::FromBase64String($newest.EncryptedPayload)
$plain = [System.Security.Cryptography.ProtectedData]::Unprotect(
    $cipher, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
$payload = [Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json

$preview = [string]$payload.Preview
$text = [string]$payload.Text
$style = [string]$payload.HtmlStyle

Write-Output ("preview len    = " + $preview.Length)
Write-Output ("preview cps    = " + (($preview.ToCharArray() | ForEach-Object { '{0:X4}' -f [int]$_ }) -join ' '))
Write-Output ("text len       = " + $text.Length)
Write-Output ("style len      = " + $style.Length)

$hasNormal = $preview -match 'Normal\s+0'
$hasSentence = $preview.Contains($sentence)
$styleOk = ($style.Length -eq 0) -or ($style -match '<style')

Write-Output ("contains 'Normal 0' = " + $hasNormal)
Write-Output ("preview == sentence = " + $hasSentence)
Write-Output ("style block usable  = " + $styleOk)

$word.Quit()
[void][Runtime.InteropServices.Marshal]::ReleaseComObject($doc)
[void][Runtime.InteropServices.Marshal]::ReleaseComObject($word)

if ($hasNormal) { Write-Output 'FAIL: preview still contains the CSS residue' }
elseif (-not $hasSentence) { Write-Output 'FAIL: preview is not the copied sentence' }
elseif (-not $styleOk) { Write-Output 'FAIL: stored HtmlStyle has no <style> block' }
else { Write-Output 'PASS: Word text capture stores the real content, no CSS residue, style retained' }
