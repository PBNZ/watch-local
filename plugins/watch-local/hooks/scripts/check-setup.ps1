#requires -Version 5.1
<#
.SYNOPSIS
    SessionStart hook -- one-line status, silent if ready.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'

$pluginRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$setup = Join-Path $pluginRoot 'scripts\setup.ps1'

if (-not (Test-Path -LiteralPath $setup)) {
    Write-Output "/watch-local: setup.ps1 missing -- plugin install incomplete?"
    exit 0
}

& powershell.exe -ExecutionPolicy Bypass -File $setup -Check 2>$null | Out-Null
$code = $LASTEXITCODE
if ($code -eq 0) { exit 0 }

switch ($code) {
    2 { Write-Output "/watch-local: docker CLI not found. Install Docker Desktop and re-run /watch-setup." }
    3 { Write-Output "/watch-local: Docker Desktop daemon not running. Start Docker Desktop." }
    4 { Write-Output "/watch-local: container images not built yet. Run /watch-setup." }
    5 { Write-Output "/watch-local: setup never completed. Run /watch-setup." }
    default { Write-Output "/watch-local: setup check returned $code. Run /watch-setup." }
}
exit 0
