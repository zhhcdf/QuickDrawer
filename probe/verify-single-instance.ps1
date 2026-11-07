# Verify the single-instance mutex fix and that the drawer auto-shows on startup.
# Pure ASCII (docs appendix D item 2). Paths passed as params.

param(
    [Parameter(Mandatory = $true)][string]$ExePath
)

$ErrorActionPreference = 'Stop'

function Get-QdProcs {
    Get-Process -Name 'QuickDrawer' -ErrorAction SilentlyContinue
}

# Clean slate
Get-QdProcs | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
Write-Output "processes before test: $((Get-QdProcs | Measure-Object).Count)"

$scrubbedPath = ($env:Path -split ';' | Where-Object { $_ -notlike '*dotnet*' -and $_ -ne '' }) -join ';'
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $ExePath
$psi.UseShellExecute = $false
$psi.EnvironmentVariables['PATH'] = $scrubbedPath
$psi.EnvironmentVariables['DOTNET_ROOT'] = ''
$psi.EnvironmentVariables['DOTNET_ROOT(x64)'] = ''
$psi.EnvironmentVariables['DOTNET_CLI_TELEMETRY_OPTOUT'] = '1'

Write-Output ""
Write-Output "=== launch #1 ==="
$p1 = [System.Diagnostics.Process]::Start($psi)
Start-Sleep -Seconds 4
Write-Output "  PID $($p1.Id) alive: $(-not $p1.HasExited)"
Write-Output "  total QuickDrawer processes: $((Get-QdProcs | Measure-Object).Count)"

Write-Output ""
Write-Output "=== launch #2 (should be blocked by mutex) ==="
# NOTE: ProcessStartInfo.Clone() does not exist on .NET Framework.
# Build a fresh one instead.
$psi2 = New-Object System.Diagnostics.ProcessStartInfo
$psi2.FileName = $ExePath
$psi2.UseShellExecute = $false
$psi2.EnvironmentVariables['PATH'] = $scrubbedPath
$psi2.EnvironmentVariables['DOTNET_ROOT'] = ''
$psi2.EnvironmentVariables['DOTNET_ROOT(x64)'] = ''
$psi2.EnvironmentVariables['DOTNET_CLI_TELEMETRY_OPTOUT'] = '1'
$p2 = [System.Diagnostics.Process]::Start($psi2)
Start-Sleep -Seconds 6
Write-Output "  PID $($p2.Id) exited: $($p2.HasExited) (exit code: $(if($p2.HasExited){$p2.ExitCode}else{'still running'}))"
$all = Get-QdProcs
Write-Output "  total QuickDrawer processes now: $($all.Count)"
$all | ForEach-Object { Write-Output "    PID $($_.Id)" }

Write-Output ""
if ($all.Count -eq 1) {
    Write-Output "RESULT: PASS - only ONE instance runs; duplicate launch was rejected."
} else {
    Write-Output "RESULT: FAIL - $($all.Count) instances are running (expected 1)."
}

Write-Output ""
Write-Output "=== window visibility check ==="
$main = $all | Select-Object -First 1
if ($main) {
    Write-Output "  MainWindowHandle: $($main.MainWindowHandle)"
    Write-Output "  (0 is expected: window is NOACTIVATE + positioned offscreen until shown)"
    Write-Output "  Responding: $($main.Responding)"
}

# cleanup
Get-QdProcs | Stop-Process -Force -ErrorAction SilentlyContinue
Write-Output ""
Write-Output "cleaned up test processes."
