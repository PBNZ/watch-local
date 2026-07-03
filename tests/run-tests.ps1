#requires -Version 5.1
<#
.SYNOPSIS
    Run the watch-local test suite.

.DESCRIPTION
    Layers:
      -Unit          Python pytest + Pester unit tests.       (~10 s)
      -Integration   Adds docker-backed worker checks.         (~30 s)
      -Smoke         Adds real /watch run vs a public URL.     (~60 s)
    Default = -Unit.

    All three layers can be combined. Each prints a per-layer summary at end.
#>

[CmdletBinding()]
param(
    [switch]$Unit,
    [switch]$Integration,
    [switch]$Smoke,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ($Unit -or $Integration -or $Smoke)) { $Unit = $true }

$root        = Split-Path -Parent $PSScriptRoot
$testsRoot   = $PSScriptRoot
$pluginRoot  = Join-Path $root 'plugins\watch-local'
$composeFile = Join-Path $pluginRoot 'docker\docker-compose.yml'
$workerDir   = Join-Path $pluginRoot 'scripts\worker'

$summary = [ordered]@{
    unit_pytest  = $null
    unit_pester  = $null
    integration  = $null
    smoke        = $null
}

function _Header([string]$label) {
    Write-Host ''
    Write-Host "============ $label ============" -ForegroundColor Cyan
}

# ---- UNIT: pytest ---------------------------------------------------------
if ($Unit) {
    _Header 'Unit -- pytest (Python)'
    Push-Location (Join-Path $testsRoot 'python')
    try {
        & python -m pytest -v
        $summary.unit_pytest = ($LASTEXITCODE -eq 0)
    } finally {
        Pop-Location
    }

    _Header 'Unit -- Pester (PowerShell)'
    try {
        Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop
    } catch {
        Write-Warning 'Pester 5+ not installed. Install with: Install-Module Pester -Force -SkipPublisherCheck'
        $summary.unit_pester = $false
    }
    if ($null -eq $summary.unit_pester) {
        $cfg = New-PesterConfiguration
        $cfg.Run.Path = Join-Path $testsRoot 'pester'
        $cfg.Output.Verbosity = 'Detailed'
        $cfg.Run.Exit = $false
        $cfg.Run.PassThru = $true
        $res = Invoke-Pester -Configuration $cfg
        $summary.unit_pester = ($res.FailedCount -eq 0)
    }
}

# ---- INTEGRATION ----------------------------------------------------------
if ($Integration) {
    _Header 'Integration -- docker workers'
    $integrationScript = Join-Path $testsRoot 'integration\Run-Integration.ps1'
    if (Test-Path -LiteralPath $integrationScript) {
        & $integrationScript -ComposeFile $composeFile -WorkerDir $workerDir
        $summary.integration = ($LASTEXITCODE -eq 0)
    } else {
        Write-Warning "missing $integrationScript -- skipped."
        $summary.integration = $false
    }
}

# ---- SMOKE ---------------------------------------------------------------
if ($Smoke) {
    _Header 'Smoke -- real /watch'
    $smokeScript = Join-Path $testsRoot 'integration\Run-Smoke.ps1'
    if (Test-Path -LiteralPath $smokeScript) {
        & $smokeScript -PluginRoot $pluginRoot
        $summary.smoke = ($LASTEXITCODE -eq 0)
    } else {
        Write-Warning "missing $smokeScript -- skipped."
        $summary.smoke = $false
    }
}

# ---- SUMMARY -------------------------------------------------------------
Write-Host ''
Write-Host '=============== SUMMARY ===============' -ForegroundColor Cyan
foreach ($k in $summary.Keys) {
    $v = $summary[$k]
    if ($null -eq $v) {
        Write-Host (' {0,-14} skipped' -f $k) -ForegroundColor DarkGray
    } elseif ($v) {
        Write-Host (' {0,-14} PASS' -f $k) -ForegroundColor Green
    } else {
        Write-Host (' {0,-14} FAIL' -f $k) -ForegroundColor Red
    }
}

if ($Json) {
    $summary | ConvertTo-Json | Write-Output
}

$anyFail = $false
foreach ($v in $summary.Values) { if ($v -eq $false) { $anyFail = $true } }
exit ($(if ($anyFail) { 1 } else { 0 }))
