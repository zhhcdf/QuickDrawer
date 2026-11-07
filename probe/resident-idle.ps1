# Idle-release verification (2026-10-29): a resident site must be released once it
# sits unused longer than assistant.residentMinutes.
#
# The test lowers residentMinutes to 1 so the wait stays short, then restores the
# original config.json byte-for-byte.
#
# ASCII only; paths derive from $PSScriptRoot.

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_helpers.ps1')
$resultPath = Join-Path $PSScriptRoot 'resident-idle.txt'

$backup = Join-Path $PSScriptRoot 'config-idle-backup.json'
$raw = [System.IO.File]::ReadAllText($configPath)
[System.IO.File]::WriteAllText($backup, $raw)

function Get-WebView2Mb {
    $procs = @(Get-Process msedgewebview2 -ErrorAction SilentlyContinue)
    $sum = 0
    foreach ($p in $procs) { $sum += $p.WorkingSet64 }
    return [int]($sum / 1MB)
}

function Count-Diag([string]$pattern) {
    return @(Get-Content -LiteralPath $diagPath | Select-String -Pattern $pattern).Count
}

function Click-Chip([string]$name) {
    $d = Get-DrawerWindow
    if (-not $d) { return $false }
    $el = Find-Ctl $d $name
    if (-not $el) { return $false }
    Click-El $el 0.5
    return $true
}

function Set-ResidentMinutes([int]$minutes) {
    $cfg = $raw | ConvertFrom-Json
    if ($null -eq $cfg.assistant) { return }
    $cfg.assistant | Add-Member -NotePropertyName residentMinutes -NotePropertyValue $minutes -Force
    $json = $cfg | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($configPath, $json, (New-Object System.Text.UTF8Encoding($true)))
}

try {
    Stop-App
    Start-Sleep -Milliseconds 600

    Set-ResidentMinutes 1
    Say 'config: assistant.residentMinutes = 1 (temporary)'

    Start-App
    Ensure-DrawerOpen | Out-Null
    [U4]::MoveTo(1780, 400)

    $cfg = Read-Config
    if ($cfg.dock.pinPanel -eq $true) {
        $d = Get-DrawerWindow
        $pin = Find-Ctl $d 'PinPanel'
        if ($pin) { Click-El $pin 0.5; Start-Sleep -Milliseconds 600 }
        Say 'unpinned the panel for the run'
    }

    Click-Tab 'TabAssistant' | Out-Null
    Start-Sleep -Seconds 4

    # make sure two sites exist, with deepseek active and kimi idle
    Click-Chip 'ChipKimi' | Out-Null
    Start-Sleep -Seconds 4
    Click-Chip 'ChipDeepSeek' | Out-Null
    Start-Sleep -Milliseconds 1500
    Click-Chip 'ChipKimi' | Out-Null
    Start-Sleep -Milliseconds 1500
    Click-Chip 'ChipDeepSeek' | Out-Null
    Start-Sleep -Milliseconds 1500

    $createdBefore = Count-Diag 'site created: kimi'
    $releasedBefore = Count-Diag 'site released: kimi'
    $memBefore = Get-WebView2Mb
    Say ("before idle: kimiCreated={0} kimiReleased={1} webview2={2}MB" -f $createdBefore, $releasedBefore, $memBefore)

    # sweep runs every 30 s and the threshold is 1 minute, so 100 s is enough
    Say 'waiting 100s for the idle sweep...'
    Start-Sleep -Seconds 100

    $releasedAfter = Count-Diag 'site released: kimi'
    $memAfter = Get-WebView2Mb
    Say ("after idle: kimiReleased={0} webview2={1}MB (delta {2}MB)" -f $releasedAfter, $memAfter, ($memAfter - $memBefore))

    Check 'idle site was released' ($releasedAfter -gt $releasedBefore)
    Check 'releasing the idle site frees memory' ($memAfter -lt $memBefore)

    # visiting the released site again must build a fresh instance (and navigate)
    Click-Chip 'ChipKimi' | Out-Null
    Start-Sleep -Seconds 4
    $createdAfter = Count-Diag 'site created: kimi'
    Say ("after revisit: kimiCreated={0} (was {1})" -f $createdAfter, $createdBefore)
    Check 'revisiting a released site recreates it' ($createdAfter -gt $createdBefore)
}
finally {
    Flush
    Stop-App
    [System.IO.File]::WriteAllText($configPath, $raw)
    Remove-Item -LiteralPath $backup -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 400
    Start-App
    Say 'config restored'
}
