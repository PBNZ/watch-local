#requires -Version 5.1
<#
.SYNOPSIS
    Run the watch-local test suite on Linux, in a container, from a
    Windows (or any) build machine with Docker.

.DESCRIPTION
    DEV TOOLING ONLY -- the plugin itself requires no Docker; this gives
    the pwsh-on-Linux leg of the test matrix a real target:

      -Unit (default)  pytest + Pester under pwsh on Linux.
      -Integration     provisions the REAL linux_x64 portable runtime
                       (downloads per the pinned manifest) + tiny model,
                       then runs the native worker checks.
      -Smoke           real /watch against a public URL inside the container.

    Runtime + model persist across runs in the named docker volume
    `watch-local-linux-state` (delete it or pass -FreshState for a true
    cold-install test).

.EXAMPLE
    pwsh -File tests/linux/run-linux-tests.ps1                    # unit only
    pwsh -File tests/linux/run-linux-tests.ps1 -Integration       # + real linux runtime
    pwsh -File tests/linux/run-linux-tests.ps1 -Integration -Smoke -FreshState
#>

[CmdletBinding()]
param(
    [switch]$Integration,
    [switch]$Smoke,
    [switch]$FreshState,
    [switch]$Rebuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$image  = 'watch-local/linux-tests:1'
$volume = 'watch-local-linux-state'
$root   = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$repoMount = ($root -replace '\\', '/')

function _Docker([string[]]$ArgList) {
    $orig = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & docker @ArgList 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { [Console]::Error.WriteLine($_.Exception.Message) }
            else { $_ | Out-Host }
        }
        return $LASTEXITCODE
    } finally { $ErrorActionPreference = $orig }
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Error 'docker not found -- this dev harness needs Docker (or run the suite in WSL directly).'
    exit 1
}

# Build the test image when missing or on request.
$orig = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
& docker image inspect $image *>$null
$haveImage = ($LASTEXITCODE -eq 0)
$ErrorActionPreference = $orig
if ($Rebuild -or -not $haveImage) {
    Write-Host "building $image ..." -ForegroundColor Cyan
    if ((_Docker @('build', '-t', $image, (Join-Path $root 'tests/linux'))) -ne 0) {
        Write-Error 'image build failed'; exit 1
    }
}

if ($FreshState) {
    Write-Host "removing state volume $volume (cold-install run)..." -ForegroundColor Cyan
    $orig = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & docker volume rm $volume *>$null
    $ErrorActionPreference = $orig
}

# Some Docker Desktop installs ship broken default container DNS
# ("Resource temporarily unavailable" on every lookup). Probe once and
# fall back to an explicit resolver only when needed.
$dnsArgs = @()
$orig = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
& docker run --rm $image pwsh -NoProfile -Command "[System.Net.Dns]::GetHostAddresses('github.com') | Out-Null" *>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'container DNS broken -- using --dns 8.8.8.8 for test runs' -ForegroundColor Yellow
    $dnsArgs = @('--dns', '8.8.8.8')
}
$ErrorActionPreference = $orig

$common = @('run', '--rm') + $dnsArgs + @(
    '-v', "${repoMount}:/repo",
    '-v', "${volume}:/root/.local/share")

# Integration/smoke need the provisioned linux runtime: run real setup
# first (idempotent -- re-verifies on warm state, downloads on cold).
if ($Integration -or $Smoke) {
    Write-Host 'provisioning linux_x64 runtime + tiny model (real setup.ps1 -Install)...' -ForegroundColor Cyan
    $code = _Docker ($common + @($image, 'pwsh', '-NoProfile', '-File',
        '/repo/plugins/watch-local/scripts/setup.ps1', '-Model', 'tiny'))
    if ($code -ne 0) {
        Write-Error "linux runtime provisioning failed (exit $code)"; exit $code
    }
}

$suiteArgs = @('-Unit')
if ($Integration) { $suiteArgs += '-Integration' }
if ($Smoke)       { $suiteArgs += '-Smoke' }

Write-Host "running suite on Linux: run-tests.ps1 $($suiteArgs -join ' ')" -ForegroundColor Cyan
$code = _Docker ($common + @($image, 'pwsh', '-NoProfile', '-File', '/repo/tests/run-tests.ps1') + $suiteArgs)
exit $code
