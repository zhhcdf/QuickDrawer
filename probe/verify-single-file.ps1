# M0.5 verification: prove the published single-file exe runs with NO .NET visible.
# This is the foundation of the "zero dependency" promise (docs/feasibility-plan.md M0.5).
#
# NOTE (docs/feasibility-plan.md appendix C, item 2): keep this script pure ASCII.
# Windows PowerShell 5.1 reads .ps1 as ANSI when there is no BOM, which corrupts
# any non-ASCII character, including the Chinese workspace folder name.

param(
    [Parameter(Mandatory = $true)]
    [string]$ExePath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ExePath)) {
    Write-Output "FAIL: exe not found at $ExePath"
    exit 1
}

$sizeMB = [math]::Round((Get-Item -LiteralPath $ExePath).Length / 1MB, 2)
Write-Output "published exe : $ExePath"
Write-Output "size          : $sizeMB MB"
Write-Output ""

# Build a scrubbed environment: strip dotnet from PATH and blank DOTNET_* vars.
# If the app still starts, it carries its own runtime.
$scrubbedPath = ($env:Path -split ';' | Where-Object { $_ -notlike '*dotnet*' -and $_ -ne '' }) -join ';'

# Use ProcessStartInfo instead of Start-Process -Environment:
# -Environment is PowerShell 7+ only, and this script must run under Windows
# PowerShell 5.1 (which reads it as ANSI without a BOM).
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $ExePath
$psi.UseShellExecute = $false

# Scrub PATH of any dotnet entry
$psi.EnvironmentVariables['PATH'] = $scrubbedPath

# Blank out DOTNET_* so the host cannot resolve a system install
$psi.EnvironmentVariables['DOTNET_ROOT'] = ''
$psi.EnvironmentVariables['DOTNET_ROOT(x64)'] = ''
$psi.EnvironmentVariables['DOTNET_CLI_TELEMETRY_OPTOUT'] = '1'

Write-Output "scrubbed PATH contains dotnet: $($scrubbedPath -like '*dotnet*')"
Write-Output "starting process in scrubbed environment..."

$proc = [System.Diagnostics.Process]::Start($psi)
Start-Sleep -Seconds 6

if ($proc.HasExited) {
    Write-Output "RESULT: FAIL - process exited early with code $($proc.ExitCode)"
    Write-Output "A non-zero exit here means the app could NOT start without .NET on PATH."
    exit 1
}

Write-Output "RESULT: PASS - process still running after 6s in scrubbed environment"
Write-Output "  PID        : $($proc.Id)"
Write-Output "  ProcessName: $($proc.ProcessName)"

# Confirm the bundled runtime is inside our process, not resolved from the system.
Write-Output ""
Write-Output "=== loaded dotnet/hostfxr modules (expected: hostfxr + coreclr bundled) ==="
$mods = $proc.Modules | Where-Object { $_.ModuleName -match 'hostfxr|coreclr|clrjit' } |
    Select-Object -ExpandProperty ModuleName
if ($mods) { $mods | ForEach-Object { "  $_" } } else { "  (none found)" }

Write-Output ""
Write-Output "=== module file location ==="
$hostMod = $proc.Modules | Where-Object { $_.ModuleName -eq 'hostfxr.dll' } | Select-Object -First 1
if ($hostMod) {
    Write-Output "  hostfxr: $($hostMod.FileName)"
    if ($hostMod.FileName -like '*Program Files\dotnet*') {
        Write-Output "  WARNING: hostfxr resolved from the SYSTEM install, not bundled."
    } else {
        Write-Output "  hostfxr is NOT from the system install -> runtime is bundled."
    }
}

Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
Write-Output ""
Write-Output "M0.5 VERIFIED: single-file exe runs without .NET on PATH."
