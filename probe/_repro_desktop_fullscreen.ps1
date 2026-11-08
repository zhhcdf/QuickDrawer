# Repro: is the bare desktop (Progman / WorkerW) misdetected as fullscreen?
# Pure ASCII on purpose: Windows PowerShell 5.1 reads BOM-less files as ANSI,
# and any Chinese comment here would shift byte offsets and break parsing.
param(
    [string]$Exe = $env:QD_EXE
)
if (-not $Exe) { $Exe = 'D:\software\QuickDrawer-publish-net48\QuickDrawer.exe' }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$asm = [Reflection.Assembly]::LoadFrom($Exe)
$nm = $asm.GetType('QuickDrawer.Native.NativeMethods')
$fsMethod = $nm.GetMethod('IsForegroundFullscreenOnCursorMonitor')
$fgMethod = $nm.GetMethod('GetForegroundWindow')
$cnMethod = $nm.GetMethod('ClassNameOf')

function Probe-State([string]$label) {
    $a = [object[]]@([IntPtr]::Zero, '')
    $verdict = $fsMethod.Invoke($null, $a)
    $fg = $fgMethod.Invoke($null, @())
    $cls = $cnMethod.Invoke($null, @($fg))
    Write-Host ""
    Write-Host "[$label]"
    Write-Host ("  foreground = 0x{0:X}  class={1}" -f [int64]$fg, $cls)
    Write-Host ("  fullscreen verdict = {0}   reason = {1}" -f $verdict, $a[1])
    return $verdict
}

Write-Host "assembly: $Exe"
Write-Host "--- 1. current state ---"
$before = Probe-State 'before'

Write-Host ""
Write-Host "--- 2. show desktop (Shell.Application.ToggleDesktop) ---"
$shell = New-Object -ComObject Shell.Application
$shell.ToggleDesktop()
Start-Sleep -Milliseconds 1200
$during = Probe-State 'desktop shown'

Write-Host ""
Write-Host "--- 3. restore desktop ---"
$shell.ToggleDesktop()
Start-Sleep -Milliseconds 1200
$after = Probe-State 'restored'

Write-Host ""
Write-Host "=== summary ==="
Write-Host ("  desktop shown treated as fullscreen : {0}" -f $during)
Write-Host ("  restored state treated as fullscreen: {0}" -f $after)

if ($during -eq $true) {
    Write-Host ""
    Write-Host "RESULT: REPRODUCED - bare desktop is misdetected as fullscreen"
    exit 1
} else {
    Write-Host ""
    Write-Host "RESULT: OK - bare desktop not treated as fullscreen"
    exit 0
}
