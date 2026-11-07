# The real invariant behind "pasting spawns a duplicate entry".
#
# SuppressRecapture(entry) registers ComputeKey(entry), which hashes entry.Text.
# When our own listener sees the WM_CLIPBOARDUPDATE caused by WriteBack, it
# re-reads the clipboard and hashes whatever TryExtractHtml produced. If that
# round-trip yields a DIFFERENT fragment, the keys differ, the suppress entry
# misses, and a duplicate row appears - exactly what the user reported.
#
# So the invariant to prove is: WriteBack -> re-read gives back the same Text.
# Testing the entry count alone is too weak, because the key may already sit in
# _seen from the original capture.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
# 2026-11-07 发布准备：探测目标 exe 改为运行时解析，不再写死个人发布目录。
# 如需指向别处，先设置环境变量 QD_EXE。
$exe = $env:QD_EXE
if (-not $exe) { $exe = Join-Path $env:LOCALAPPDATA 'QuickDrawer\QuickDrawer.exe' }
if (-not (Test-Path $exe)) { throw "QD_EXE not found: $exe  (set `$env:QD_EXE to the published QuickDrawer.exe)" }
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$json = Join-Path $env:APPDATA 'QuickDrawer\clipboard.json'
$entries = @((Get-Content $json -Raw -Encoding UTF8 | ConvertFrom-Json).Entries)
$target = $entries |
    Where-Object { $_.Kind -eq 'Html' } |
    Sort-Object { [datetime]$_.CreatedAt } -Descending |
    Select-Object -First 1

$cipher = [Convert]::FromBase64String($target.EncryptedPayload)
$plain = [System.Security.Cryptography.ProtectedData]::Unprotect(
    $cipher, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
$payload = [Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json

$asm = [Reflection.Assembly]::LoadFrom($exe)
$svc = $asm.GetType('QuickDrawer.ClipboardService')
$entryType = $asm.GetType('QuickDrawer.ClipEntry')
$kindType = $asm.GetType('QuickDrawer.ClipKind')

$entry = [Activator]::CreateInstance($entryType)
$entry.Kind = [Enum]::Parse($kindType, $target.Kind)
$entry.Text = [string]$payload.Text
$entry.Preview = [string]$payload.Preview
$entry.HtmlStyle = [string]$payload.HtmlStyle

$storedText = [string]$payload.Text
$storedCps = (($storedText.ToCharArray() | Select-Object -First 10 | ForEach-Object { '{0:X4}' -f [int]$_ }) -join ' ')
Write-Output ("stored text len  = " + $storedText.Length)
Write-Output ("stored text cps  = " + $storedCps)
Write-Output ("stored style len = " + ([string]$payload.HtmlStyle).Length)

# Push it to the clipboard the same way PasteEntry does.
$ok = $svc.GetMethod('WriteBack').Invoke($null, @($entry))
Write-Output ("WriteBack        = " + $ok)
Start-Sleep -Milliseconds 500

# Now re-read through the very same code path the listener uses.
# ReadHtml is a private INSTANCE method, so we need a live ClipboardService
# instance - a static Invoke($null, ...) would throw TargetException.
$cfg = [Activator]::CreateInstance($asm.GetType('QuickDrawer.AppConfig'))
$svcInstance = [Activator]::CreateInstance($svc, @($cfg))
# ReadHtml() assumes the caller already opened the clipboard, so calling it
# directly returns null. TryReadClipboard() is the entry point that opens it.
$read = $svc.GetMethod('TryReadClipboard', [Reflection.BindingFlags]'NonPublic,Instance')
$reread = $read.Invoke($svcInstance, @())
if ($null -eq $reread) {
    Write-Output 'FAIL: re-read produced nothing (WriteBack payload is unreadable)'
    exit 1
}

$rereadText = [string]$reread.Text
$rereadCps = (($rereadText.ToCharArray() | Select-Object -First 10 | ForEach-Object { '{0:X4}' -f [int]$_ }) -join ' ')
Write-Output ("reread text len  = " + $rereadText.Length)
Write-Output ("reread text cps  = " + $rereadCps)
Write-Output ("reread style len = " + ([string]$reread.HtmlStyle).Length)

# Compare the hash the listener would compute against the one SuppressRecapture
# registered. ComputeKey is private static; call it for both sides.
$computeKey = $svc.GetMethod('ComputeKey', [Reflection.BindingFlags]'NonPublic,Static')
$keyStored = $computeKey.Invoke($null, @($entry))
$keyReread = $computeKey.Invoke($null, @($reread))
Write-Output ("key(stored)      = " + $keyStored)
Write-Output ("key(reread)      = " + $keyReread)

$sameText = ($rereadText -ceq $storedText)
$sameKey = ($keyStored -ceq $keyReread)
Write-Output ("text round-trips = " + $sameText)
Write-Output ("key matches      = " + $sameKey)

if (-not $sameText) { Write-Output 'FAIL: fragment changed through the write-back round-trip' }
elseif (-not $sameKey) { Write-Output 'FAIL: key differs, listener would capture a duplicate' }
else { Write-Output 'PASS: write-back round-trip is stable, no duplicate capture' }
