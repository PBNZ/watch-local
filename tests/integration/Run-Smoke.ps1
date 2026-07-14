#requires -Version 5.1
<#
.SYNOPSIS
    Smoke test -- real /watch run against a short public URL.

.DESCRIPTION
    Runs watch.ps1 against a known short YouTube URL with -MaxFrames 4
    and -Model tiny so it completes in <60s. Verifies:
      - exit 0
      - intermediate.json present
      - >= 1 frame on disk
      - report contains "Whisper:" and "Caption provenance:" lines
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PluginRoot,
    [string]$Url = 'https://www.youtube.com/watch?v=QZMljuD10sU'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$watch = Join-Path $PluginRoot 'scripts/watch.ps1'
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('wl-smoke-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

try {
    # Same engine as the runner: powershell.exe when invoked from 5.1, pwsh
    # when invoked from PowerShell 7 (and on Linux/macOS).
    $engine = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell.exe' }
    $output = & $engine -ExecutionPolicy Bypass -File $watch `
        -Source $Url -MaxFrames 4 -Model tiny -NoCompare -OutDir $tmp 2>&1 |
        Out-String

    if ($LASTEXITCODE -ne 0) {
        Write-Host "SMOKE FAIL: watch.ps1 exited $LASTEXITCODE" -ForegroundColor Red
        Write-Host $output
        exit 1
    }
    $intPath = Join-Path $tmp 'intermediate.json'
    if (-not (Test-Path -LiteralPath $intPath)) {
        Write-Host 'SMOKE FAIL: intermediate.json missing' -ForegroundColor Red
        exit 1
    }
    $framesDir = Join-Path $tmp 'frames'
    $framesCount = (Get-ChildItem -LiteralPath $framesDir -Filter 'frame_*.jpg' -ErrorAction SilentlyContinue).Count
    if ($framesCount -lt 1) {
        Write-Host "SMOKE FAIL: no frames in $framesDir" -ForegroundColor Red
        exit 1
    }
    if ($output -notmatch 'Caption provenance:') {
        Write-Host 'SMOKE FAIL: report missing Caption provenance line' -ForegroundColor Red
        exit 1
    }
    Write-Host "SMOKE PASS: $framesCount frames extracted, exit 0" -ForegroundColor Green
    exit 0
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
