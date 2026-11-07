$ErrorActionPreference = 'SilentlyContinue'
$p = Get-Process QuickDrawer
if ($p) {
    foreach ($proc in $p) { Stop-Process -Id $proc.Id -Force }
    for ($i = 0; $i -lt 40; $i++) {
        if (-not (Get-Process QuickDrawer)) { break }
        Start-Sleep -Milliseconds 250
    }
}
if (Get-Process QuickDrawer) { 'STILL-RUNNING' } else { 'STOPPED' }
