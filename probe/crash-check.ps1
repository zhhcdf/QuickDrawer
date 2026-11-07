$ErrorActionPreference = 'SilentlyContinue'
$since = (Get-Date).AddMinutes(-20)
$evts = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $since } |
    Where-Object { $_.Message -match 'QuickDrawer' }
if (-not $evts) { Write-Output 'no QuickDrawer events'; exit 0 }
$evts | Select-Object -First 4 | ForEach-Object {
    Write-Output ('--- ' + $_.TimeCreated + '  ' + $_.ProviderName + '  id=' + $_.Id)
    $lines = $_.Message -split "`r?`n"
    Write-Output ($lines[0..([Math]::Min(8, $lines.Count - 1))] -join ' | ')
}
